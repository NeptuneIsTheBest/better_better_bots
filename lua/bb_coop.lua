local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local CoopCacheManager = BB.CoopCacheManager
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local EnemyClassifier = BB.EnemyClassifier
local ThreatAssessment = BB.ThreatAssessment
local CombatHelper = BB.CombatHelper
local AssignmentPlanner = BB.AssignmentPlanner

local clamp = Utils.clamp
local game_time = Utils.game_time
local get_unit_health_ratio = UnitOps.health_ratio
local are_units_foes = UnitOps.are_foes

local CoopSystem = {}

CoopSystem.data = BB.coop_data or {
    priority_targets = {},
    teammates_status = {},
    bot_observations = {},
    team_pressure_cache = {},
    optimal_assignments = {},
    assignment_snapshot = {},
    assignment_debug = { dummy_assignments = 0, local_fallbacks = 0 },
    last_assignment_update = 0,
    assignment_dirty = true,
}
BB.coop_data = CoopSystem.data

CoopSystem.data.priority_targets = CoopSystem.data.priority_targets or {}
CoopSystem.data.teammates_status = CoopSystem.data.teammates_status or {}
CoopSystem.data.bot_observations = CoopSystem.data.bot_observations or {}
CoopSystem.data.team_pressure_cache = CoopSystem.data.team_pressure_cache or {}
CoopSystem.data.optimal_assignments = CoopSystem.data.optimal_assignments or {}
CoopSystem.data.assignment_snapshot = CoopSystem.data.assignment_snapshot or {}
CoopSystem.data.assignment_debug = CoopSystem.data.assignment_debug or { dummy_assignments = 0, local_fallbacks = 0 }
if CoopSystem.data.assignment_dirty == nil then
    CoopSystem.data.assignment_dirty = true
end

local function _make_assignment_snapshot(t)
    return {
        generated_at = t or 0,
        by_bot = {},
        by_target = {},
        owners_by_target = {},
        target_load = {},
        candidate_counts = {},
        dummy_assignments = 0,
        local_fallbacks = 0,
    }
end

local function _clear_table(value)
    if type(value) ~= "table" then
        return {}
    end

    for key in pairs(value) do
        value[key] = nil
    end

    return value
end

function CoopSystem.reset_level_state()
    local data = CoopSystem.data

    data.priority_targets = _clear_table(data.priority_targets)
    data.teammates_status = _clear_table(data.teammates_status)
    data.bot_observations = _clear_table(data.bot_observations)
    data.team_pressure_cache = _clear_table(data.team_pressure_cache)
    data.optimal_assignments = _clear_table(data.optimal_assignments)

    data.assignment_snapshot = _clear_table(data.assignment_snapshot)
    for key, value in pairs(_make_assignment_snapshot(0)) do
        data.assignment_snapshot[key] = value
    end

    data.assignment_debug = _clear_table(data.assignment_debug)
    data.assignment_debug.dummy_assignments = 0
    data.assignment_debug.local_fallbacks = 0
    data.last_assignment_update = 0
    data.assignment_dirty = true

    CoopCacheManager.teammate_status:clear()
    CoopCacheManager.threat_value:clear()
    CoopCacheManager.suitability:clear()
    CoopCacheManager.teammate_distance:clear()

    return true
end

local function _drop_bot_state(bot_key)
    CoopSystem.data.teammates_status[bot_key] = nil
    CoopSystem.data.bot_observations[bot_key] = nil
    CoopCacheManager.teammate_status:clear(bot_key)

    local snapshot = CoopSystem.data.assignment_snapshot
    local target_key = snapshot and snapshot.by_bot and snapshot.by_bot[bot_key]
    if target_key then
        snapshot.owners_by_target = snapshot.owners_by_target or {}
        snapshot.target_load = snapshot.target_load or {}
        snapshot.by_bot[bot_key] = nil
        local owners = snapshot.owners_by_target and snapshot.owners_by_target[target_key]
        if owners then
            owners[bot_key] = nil
            local load = math.max((snapshot.target_load[target_key] or 1) - 1, 0)
            snapshot.target_load[target_key] = load
            if load == 0 then
                snapshot.owners_by_target[target_key] = nil
                snapshot.by_target[target_key] = nil
                snapshot.target_load[target_key] = nil
            elseif snapshot.by_target[target_key] == bot_key then
                local replacement
                for owner_key in pairs(owners) do
                    if not replacement or tostring(owner_key) < tostring(replacement) then
                        replacement = owner_key
                    end
                end
                snapshot.by_target[target_key] = replacement
            end
        elseif snapshot.by_target then
            snapshot.by_target[target_key] = nil
        end
    end

    CoopSystem.data.assignment_dirty = true
end

local function _cleanup_stale_teammates(now)
    now = now or game_time()

    for bot_key, status in pairs(CoopSystem.data.teammates_status) do
        local stale = not (status and status.unit and alive(status.unit))
                or (now - (status.last_update or 0)) > CONSTANTS.COOP_BOT_OBSERVATION_TTL

        if stale then
            _drop_bot_state(bot_key)
        end
    end
end

local function _cleanup_stale_observations(now)
    now = now or game_time()
    _cleanup_stale_teammates(now)

    for bot_key, snapshot in pairs(CoopSystem.data.bot_observations) do
        local status = CoopSystem.data.teammates_status[bot_key]
        local stale_snapshot = not status
                or not (snapshot and snapshot.targets)
                or (now - (snapshot.last_update or 0)) > CONSTANTS.COOP_BOT_OBSERVATION_TTL

        if stale_snapshot then
            CoopSystem.data.bot_observations[bot_key] = nil
            CoopSystem.data.assignment_dirty = true
        else
            for target_key, observation in pairs(snapshot.targets) do
                local stale_target = not (observation and observation.unit and alive(observation.unit))
                        or now > (observation.valid_until or observation.last_seen or 0)

                if stale_target then
                    snapshot.targets[target_key] = nil
                    CoopSystem.data.assignment_dirty = true
                end
            end
        end
    end
end

function CoopSystem.is_enabled()
    return BB:get("coop", false)
end

function CoopSystem.update_teammate_status(unit, data)
    if not alive(unit) or not CoopSystem.is_enabled() then
        return
    end

    local u_key = tostring(unit:key())
    local t = game_time()

    local cached = CoopCacheManager.teammate_status:get(u_key)
    if cached and (t - cached.last_update) < CONSTANTS.COOP_REFRESH_INTERVAL then
        CoopSystem.data.teammates_status[u_key] = cached
        return cached
    end

    local health_ratio = get_unit_health_ratio(unit)
    local unit_movement = unit:movement()
    local pos = unit_movement and unit_movement:m_head_pos()
    local anim_data = unit:anim_data()
    local is_reloading = anim_data and anim_data.reload
    local facing_dir = unit_movement and unit_movement:m_head_fwd()
    local combat_status = UnitOps.combat_status(unit)
    local is_downed = combat_status.is_downed
    local is_arrested = combat_status.is_arrested
    local is_tased = combat_status.is_tased
    local can_fight = combat_status.can_fight

    local previous = CoopSystem.data.teammates_status[u_key]
    local assignment_state_changed = not previous
            or previous.can_fight ~= can_fight
            or previous.is_reloading ~= is_reloading

    local status = {
        unit = unit,
        health_ratio = health_ratio,
        position = pos,
        facing_direction = facing_dir,
        in_danger = health_ratio < 0.3,
        needs_cover = health_ratio < 0.15,
        is_reloading = is_reloading,
        is_downed = is_downed,
        is_arrested = is_arrested,
        is_tased = is_tased,
        can_fight = can_fight,
        assignment_state_changed = assignment_state_changed,
        logic_name = data and data.name or nil,
        last_update = t,
    }

    CoopCacheManager.teammate_status:set(u_key, status, 1)

    CoopSystem.data.teammates_status[u_key] = status

    if assignment_state_changed then
        CoopSystem.data.assignment_dirty = true
    end

    if not can_fight then
        CoopSystem.data.bot_observations[u_key] = nil
    end

    return status
end

function CoopSystem.get_reloading_teammates_count(exclude_key)
    if not CoopSystem.is_enabled() then
        return 0
    end

    _cleanup_stale_teammates(game_time())

    local count = 0
    local exclude_key_str = exclude_key and tostring(exclude_key)
    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if u_key ~= exclude_key_str and status.is_reloading then
            count = count + 1
        end
    end

    return count
end

function CoopSystem.count_active_teammates()
    if not CoopSystem.is_enabled() then
        return 0
    end

    _cleanup_stale_teammates(game_time())

    local count = 0
    for _, status in pairs(CoopSystem.data.teammates_status) do
        if status and status.unit and alive(status.unit) then
            count = count + 1
        end
    end

    return count
end

function CoopSystem.is_direction_covered(target_pos, my_unit)
    if not (target_pos and alive(my_unit)) then
        return false
    end

    _cleanup_stale_teammates(game_time())

    local my_pos = my_unit:movement() and my_unit:movement():m_head_pos()
    if not my_pos or mvector3.distance(target_pos, my_pos) < 0.1 then
        return false
    end

    local my_dir = target_pos - my_pos
    mvector3.normalize(my_dir)

    local same_dir_threshold = 0.6
    local face_target_threshold = 0.6

    local my_key = tostring(my_unit:key())

    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if u_key ~= my_key
                and status.can_fight
                and not status.is_reloading
                and status.position
                and status.facing_direction
        then
            local other_to_target = target_pos - status.position
            mvector3.normalize(other_to_target)

            local same_dir = mvector3.dot(my_dir, other_to_target)
            local facing_ok = mvector3.dot(status.facing_direction, other_to_target)

            if same_dir > same_dir_threshold and facing_ok > face_target_threshold then
                return true
            end
        end
    end

    return false
end

local function _count_entries(value)
    local count = 0
    for _ in pairs(value or {}) do
        count = count + 1
    end
    return count
end

local function _primary_owner(owners)
    local primary
    for bot_key in pairs(owners or {}) do
        if not primary or tostring(bot_key) < tostring(primary) then
            primary = bot_key
        end
    end
    return primary
end

local function _role_changed(old_snapshot, restricted, fixed_target)
    if not old_snapshot then
        return restricted or fixed_target ~= nil
    end

    return old_snapshot.restricted ~= restricted
            or tostring(old_snapshot.fixed_target or "") ~= tostring(fixed_target or "")
end

function CoopSystem.submit_candidates(data, candidates, role)
    if not (CoopSystem.is_enabled() and data and alive(data.unit)) then
        return CoopSystem.get_assignment_snapshot()
    end

    local bot_key = tostring(data.key or data.unit:key())
    local status = CoopSystem.update_teammate_status(data.unit, data)
    local old_snapshot = CoopSystem.data.bot_observations[bot_key]

    if not (status and status.can_fight) then
        if old_snapshot then
            CoopSystem.data.bot_observations[bot_key] = nil
            CoopSystem.data.assignment_dirty = true
        end
        return CoopSystem.update_optimal_assignments(true)
    end

    local t = data.t or game_time()
    local restricted = role and role.restricted == true or false
    local fixed_target = role and role.target_key and tostring(role.target_key) or nil
    local observation_snapshot = {
        last_update = t,
        targets = {},
        restricted = restricted,
        fixed_target = fixed_target,
    }
    local urgent_changed = false

    for target_key, candidate in pairs(candidates or {}) do
        target_key = tostring(target_key)
        if candidate.coop_eligible
                and candidate.data
                and alive(candidate.data.unit)
                and (candidate.valid_until or 0) >= t
        then
            local old_target = old_snapshot and old_snapshot.targets and old_snapshot.targets[target_key]
            local score = math.max(candidate.coop_score or 0, 0)
            if status.is_reloading then
                score = score * CONSTANTS.COOP_RELOADING_FACTOR
            end

            observation_snapshot.targets[target_key] = {
                unit = candidate.data.unit,
                u_key = candidate.data.u_key or candidate.data.unit:key(),
                score = score,
                priority = score,
                priority_slot = candidate.priority_slot,
                urgency = candidate.urgency or 1,
                focus = candidate.focus,
                durable = candidate.durable == true,
                last_seen = t,
                valid_until = candidate.valid_until,
                state = candidate.state or "normal",
                verified = candidate.data.verified == true,
                reaction = candidate.reaction,
                pos = candidate.target_pos,
            }

            local was_urgent = old_target and (old_target.urgency or 1) >= 3 or false
            local is_urgent = (candidate.urgency or 1) >= 3
            if was_urgent ~= is_urgent then
                urgent_changed = true
            end
        end
    end

    for target_key, old_target in pairs(old_snapshot and old_snapshot.targets or {}) do
        if (old_target.urgency or 1) >= 3
                and not observation_snapshot.targets[target_key]
        then
            urgent_changed = true
            break
        end
    end

    if fixed_target and not observation_snapshot.targets[fixed_target] then
        fixed_target = nil
        observation_snapshot.fixed_target = nil
    end

    local old_assignment = CoopSystem.get_assigned_target(bot_key)
    local assignment_invalid = old_assignment
            and not observation_snapshot.targets[tostring(old_assignment)]
    local role_state_changed = _role_changed(old_snapshot, restricted, fixed_target)

    CoopSystem.data.bot_observations[bot_key] = observation_snapshot
    CoopSystem.data.assignment_dirty = true

    return CoopSystem.update_optimal_assignments(
            urgent_changed
                    or assignment_invalid
                    or role_state_changed
                    or status.assignment_state_changed
    )
end

function CoopSystem.update_optimal_assignments(force)
    local t = game_time()
    _cleanup_stale_observations(t)

    if not CoopSystem.is_enabled() then
        CoopSystem.data.assignment_snapshot = _make_assignment_snapshot(t)
        CoopSystem.data.optimal_assignments = {}
        CoopSystem.data.assignment_dirty = false
        return CoopSystem.data.assignment_snapshot
    end

    if not force then
        if not CoopSystem.data.assignment_dirty then
            return CoopSystem.get_assignment_snapshot()
        end
        if CoopSystem.data.last_assignment_update
                and (t - CoopSystem.data.last_assignment_update) < CONSTANTS.ASSIGNMENT_UPDATE_INTERVAL
        then
            return CoopSystem.get_assignment_snapshot()
        end
    end

    CoopSystem.data.last_assignment_update = t
    CoopSystem.data.assignment_dirty = false

    local workers = {}
    local edges = {}
    local fixed_by_bot = {}
    local targets_by_key = {}
    local candidate_counts = {}
    local active_count = 0

    for bot_key, status in pairs(CoopSystem.data.teammates_status) do
        local bot_snapshot = CoopSystem.data.bot_observations[bot_key]
        if status
                and status.can_fight
                and status.unit
                and alive(status.unit)
                and bot_snapshot
                and (t - (bot_snapshot.last_update or 0)) <= CONSTANTS.COOP_BOT_OBSERVATION_TTL
        then
            active_count = active_count + 1
            candidate_counts[bot_key] = _count_entries(bot_snapshot.targets)

            if bot_snapshot.restricted then
                if bot_snapshot.fixed_target
                        and bot_snapshot.targets[bot_snapshot.fixed_target]
                then
                    fixed_by_bot[bot_key] = bot_snapshot.fixed_target
                end
            else
                table.insert(workers, { key = bot_key })
                edges[bot_key] = {}
            end

            for target_key, observation in pairs(bot_snapshot.targets or {}) do
                if observation.unit
                        and alive(observation.unit)
                        and t <= (observation.valid_until or 0)
                then
                    local target = targets_by_key[target_key]
                    if not target then
                        target = {
                            key = target_key,
                            unit = observation.unit,
                            urgency = observation.urgency or 1,
                            max_score = observation.score or 0,
                            durable = observation.durable == true,
                        }
                        targets_by_key[target_key] = target
                    else
                        target.urgency = math.max(target.urgency or 1, observation.urgency or 1)
                        target.max_score = math.max(target.max_score or 0, observation.score or 0)
                        target.durable = target.durable or observation.durable == true
                    end

                    if not bot_snapshot.restricted then
                        edges[bot_key][target_key] = {
                            score = observation.score or 0,
                            urgency = observation.urgency or 1,
                        }
                    end
                end
            end
        end
    end

    table.sort(workers, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)

    local targets = {}
    for _, target in pairs(targets_by_key) do
        if target.urgency >= 3 then
            target.focus = "urgent"
        elseif target.durable and active_count >= 3 then
            target.focus = "durable"
        end
        table.insert(targets, target)
    end

    local old_snapshot = CoopSystem.get_assignment_snapshot()
    local result = AssignmentPlanner.solve({
        bots = workers,
        targets = targets,
        edges = edges,
        previous_by_bot = old_snapshot.by_bot,
        fixed_by_bot = fixed_by_bot,
    })

    local snapshot = _make_assignment_snapshot(t)
    snapshot.by_bot = result.by_bot
    snapshot.owners_by_target = result.owners_by_target
    snapshot.target_load = result.target_load
    snapshot.candidate_counts = candidate_counts
    snapshot.dummy_assignments = result.dummy_assignments or 0

    for target_key, owners in pairs(snapshot.owners_by_target) do
        snapshot.by_target[target_key] = _primary_owner(owners)
    end

    CoopSystem.data.assignment_debug.dummy_assignments =
            (CoopSystem.data.assignment_debug.dummy_assignments or 0)
            + snapshot.dummy_assignments
    CoopSystem.data.assignment_snapshot = snapshot
    CoopSystem.data.optimal_assignments = snapshot.by_bot
    return snapshot
end

function CoopSystem.get_assignment_snapshot()
    local snapshot = CoopSystem.data.assignment_snapshot
    if not (snapshot and snapshot.by_bot and snapshot.by_target and snapshot.candidate_counts) then
        snapshot = _make_assignment_snapshot(game_time())
        CoopSystem.data.assignment_snapshot = snapshot
    end

    snapshot.owners_by_target = snapshot.owners_by_target or {}
    snapshot.target_load = snapshot.target_load or {}
    for target_key, owner in pairs(snapshot.by_target) do
        if owner and not snapshot.owners_by_target[target_key] then
            snapshot.owners_by_target[target_key] = { [owner] = true }
            snapshot.target_load[target_key] = 1
        end
    end

    snapshot.age = math.max(0, game_time() - (snapshot.generated_at or 0))
    return snapshot
end

function CoopSystem.get_assigned_target(my_key)
    local snapshot = CoopSystem.get_assignment_snapshot()
    return snapshot.by_bot[tostring(my_key)]
end

function CoopSystem.is_my_assigned_target(target_u_key, my_key)
    target_u_key = tostring(target_u_key)
    return CoopSystem.get_assigned_target(my_key) == target_u_key
end

function CoopSystem.get_target_owner(target_u_key)
    local snapshot = CoopSystem.get_assignment_snapshot()
    return snapshot.by_target[tostring(target_u_key)]
end

function CoopSystem.get_target_owners(target_u_key)
    local snapshot = CoopSystem.get_assignment_snapshot()
    return snapshot.owners_by_target[tostring(target_u_key)] or {}
end

function CoopSystem.get_target_load(target_u_key)
    local snapshot = CoopSystem.get_assignment_snapshot()
    return snapshot.target_load[tostring(target_u_key)] or 0
end

function CoopSystem.get_local_target_utility(bot_key, target_key, candidate)
    bot_key = tostring(bot_key)
    target_key = tostring(target_key)
    local snapshot = CoopSystem.get_assignment_snapshot()
    local owners = snapshot.owners_by_target[target_key] or {}
    local load = snapshot.target_load[target_key] or 0
    if owners[bot_key] then
        load = math.max(load - 1, 0)
    end

    local focus = candidate.focus
    if focus == "durable" then
        local combat_ready = 0
        for _, status in pairs(CoopSystem.data.teammates_status) do
            if status and status.can_fight and status.unit and alive(status.unit) then
                combat_ready = combat_ready + 1
            end
        end
        if combat_ready < 3 then
            focus = nil
        end
    end

    return AssignmentPlanner.utility_for_load({
        score = candidate.coop_score or candidate.score or 0,
        urgency = candidate.urgency or 1,
    }, target_key, load, focus, snapshot.by_bot[bot_key])
end

function CoopSystem.note_local_fallback()
    local debug = CoopSystem.data.assignment_debug
    debug.local_fallbacks = (debug.local_fallbacks or 0) + 1

    local snapshot = CoopSystem.get_assignment_snapshot()
    snapshot.local_fallbacks = (snapshot.local_fallbacks or 0) + 1
end

CoopSystem.STATE_PRIORITY = {
    normal = 0,
    near_teammate = 1,
    dozer_facing = 2,
    tasing_teammate = 3,
    spooc_attacking = 4,
}

function CoopSystem.get_priority_targets()
    if not CoopSystem.is_enabled() then
        return {}
    end

    local t = game_time()
    _cleanup_stale_observations(t)
    local active_targets = {}
    for observer_key, snapshot in pairs(CoopSystem.data.bot_observations) do
        if snapshot and snapshot.targets then
            for target_key, observation in pairs(snapshot.targets) do
                if observation
                        and observation.unit
                        and alive(observation.unit)
                        and t <= (observation.valid_until or 0)
                then
                    local aggregate = active_targets[target_key]
                    if not aggregate then
                        aggregate = {
                            unit = observation.unit,
                            u_key = observation.u_key,
                            priority = observation.score or 0,
                            last_seen = observation.last_seen,
                            state = observation.state or "normal",
                            observed_by = {},
                            observed_by_count = 0,
                            verified_count = 0,
                            pos = observation.pos,
                        }
                        active_targets[target_key] = aggregate
                    end

                    aggregate.priority = math.max(aggregate.priority or 0, observation.score or 0)
                    aggregate.last_seen = math.max(aggregate.last_seen or 0, observation.last_seen or 0)
                    aggregate.unit = observation.unit
                    aggregate.pos = observation.pos or aggregate.pos

                    local old_prio = CoopSystem.STATE_PRIORITY[aggregate.state] or 0
                    local new_prio = CoopSystem.STATE_PRIORITY[observation.state] or 0
                    if new_prio >= old_prio then
                        aggregate.state = observation.state or aggregate.state
                    end

                    if not aggregate.observed_by[observer_key] then
                        aggregate.observed_by[observer_key] = true
                        aggregate.observed_by_count = aggregate.observed_by_count + 1
                    end

                    if observation.verified then
                        aggregate.verified_count = aggregate.verified_count + 1
                    end
                else
                    snapshot.targets[target_key] = nil
                end
            end
        end
    end

    CoopSystem.data.priority_targets = active_targets
    return active_targets
end

function CoopSystem.get_closest_teammate_info(pos)
    if not (pos and CoopSystem.data) then
        return nil, false, nil
    end

    _cleanup_stale_teammates(game_time())

    local cache_key = string.format("%.1f_%.1f_%.1f", pos.x, pos.y, pos.z)
    local cached = CoopCacheManager.teammate_distance:get(cache_key)
    if cached then
        if cached.who and cached.who.unit and not alive(cached.who.unit) then
            CoopCacheManager.teammate_distance:clear(cache_key)
        else
            return cached.min_dist, cached.in_danger_any, cached.who
        end
    end

    local min_dist = math.huge
    local in_danger_any = false
    local who = nil

    for _, st in pairs(CoopSystem.data.teammates_status) do
        if st and st.unit and alive(st.unit) and st.position then
            if st.in_danger then
                in_danger_any = true
            end
            local d = mvector3.distance(pos, st.position)
            if d < min_dist then
                min_dist = d
                who = st
            end
        end
    end

    if min_dist == math.huge then
        return nil, false, nil
    end

    CoopCacheManager.teammate_distance:set(cache_key, {
        min_dist = min_dist,
        in_danger_any = in_danger_any,
        who = who
    }, 0.2)

    return min_dist, in_danger_any, who
end

function CoopSystem.compute_dynamic_priority(my_unit, att_obj, data, target_pos, target_distance)
    if not (alive(my_unit) and att_obj and att_obj.unit and alive(att_obj.unit)) then
        return 0, "normal"
    end

    local enemy = att_obj.unit
    local flags = BB.classify_enemy(enemy, att_obj)
    local pos = target_pos
            or att_obj.m_head_pos
            or (enemy:movement() and enemy:movement():m_head_pos())
    local my_head = my_unit:movement() and my_unit:movement():m_head_pos()
    local dis = target_distance
            or att_obj.verified_dis
            or ((my_head and pos) and mvector3.distance(my_head, pos))
            or 2000

    local prio = 0
    local state = "normal"

    local ally_dist
    local closest_ally
    if pos then
        local ignored_danger
        ally_dist, ignored_danger, closest_ally = CoopSystem.get_closest_teammate_info(pos)
    end
    local ally_in_danger = closest_ally and closest_ally.in_danger or false
    local team_factor = 1.0

    if ally_dist then
        local prox = clamp(1 - (ally_dist / CONSTANTS.COOP_TEAMMATE_DANGER_RANGE), 0, 1)
        team_factor = 1 + prox * 0.8 + (ally_in_danger and 0.4 or 0)
        if prox > 0.5 then
            state = "near_teammate"
        end
    end

    if flags.turret then
        prio = prio + THREAT_WEIGHTS.COOP_TURRET_PRIO
    end
    if flags.dozer then
        prio = prio + THREAT_WEIGHTS.COOP_DOZER_PRIO

        if pos and my_head then
            local e_mov = enemy:movement()
            local e_fwd = e_mov and e_mov:m_head_fwd()
            if e_fwd then
                local to_me = my_head - pos
                mvector3.normalize(to_me)
                if mvector3.dot(e_fwd, to_me) > 0.7 then
                    prio = prio + THREAT_WEIGHTS.COOP_DOZER_FACING_BONUS
                    state = "dozer_facing"
                end
            end
        end
    end
    if flags.taser then
        prio = prio + THREAT_WEIGHTS.COOP_TASER_PRIO
    end
    if flags.cloaker then
        prio = prio + (dis < 1400 and THREAT_WEIGHTS.COOP_CLOAKER_CLOSE_PRIO or THREAT_WEIGHTS.COOP_CLOAKER_PRIO)
    end
    if flags.sniper then
        prio = prio + THREAT_WEIGHTS.COOP_SNIPER_PRIO
        if dis > 2500 then
            prio = prio + THREAT_WEIGHTS.COOP_SNIPER_FAR_BONUS
        end
    end
    if flags.medic then
        prio = prio + THREAT_WEIGHTS.COOP_MEDIC_PRIO
    end

    if flags.tasing then
        prio = prio + THREAT_WEIGHTS.COOP_TASING_PRIO
        state = "tasing_teammate"
    end

    if flags.spooc_attack then
        prio = prio + THREAT_WEIGHTS.COOP_SPOOC_PRIO
        state = "spooc_attacking"
    end

    if flags.shield then
        local has_ap = CombatHelper.has_ap_ammo(my_unit)
        local blocked = pos and CombatHelper.shield_blocks_default(my_unit, pos)

        if blocked and not has_ap and dis > CONSTANTS.MELEE_DISTANCE then
            prio = prio + THREAT_WEIGHTS.COOP_SHIELD_BLOCKED_PRIO
        else
            prio = prio + THREAT_WEIGHTS.COOP_SHIELD_CLEAR_PRIO
        end
    end

    if pos then
        local cluster = 0
        for _, v in pairs(data.detected_attention_objects or {}) do
            if v ~= att_obj
                    and v.identified
                    and v.unit
                    and alive(v.unit)
                    and are_units_foes(my_unit, v.unit)
                    and v.m_head_pos
            then
                local d = mvector3.distance(pos, v.m_head_pos)
                if d <= CONSTANTS.CLUSTER_DISTANCE then
                    cluster = cluster + 1
                end
            end
        end

        if cluster >= 3 then
            prio = prio + THREAT_WEIGHTS.COOP_CLUSTER_BONUS
        end
    end

    if pos and not CoopSystem.is_direction_covered(pos, my_unit) then
        prio = prio + (THREAT_WEIGHTS.DIRECTION_BONUS / 3)
    end

    if att_obj.verified then
        prio = prio + THREAT_WEIGHTS.COOP_VERIFIED_BONUS
    end

    prio = prio * ThreatAssessment.distance_falloff(dis, flags)

    prio = prio * team_factor
    return prio, state
end

function CoopSystem.scan_and_update_priorities(data, candidates, role)
    return CoopSystem.submit_candidates(data, candidates, role)
end

function CoopSystem.calculate_team_pressure(unit, data)
    if not (alive(unit) and CoopSystem.is_enabled()) then
        return 0
    end

    _cleanup_stale_teammates(game_time())

    local t = game_time()
    local u_key = tostring(unit:key())
    local cache = CoopSystem.data.team_pressure_cache[u_key]

    if cache and (t - cache.last_update) < 0.2 then
        return cache.pressure
    end

    local my_pos = unit:movement() and unit:movement():m_head_pos()
    if not my_pos then
        return 0
    end

    local pressure = 0
    local enemy_count = 0
    local special_count = 0
    local close_enemy_count = 0

    for _, att_obj in pairs(data.detected_attention_objects or {}) do
        if att_obj.identified
                and att_obj.verified
                and att_obj.unit
                and alive(att_obj.unit)
                and are_units_foes(unit, att_obj.unit)
        then
            local dis = att_obj.verified_dis
            if dis and dis <= CONSTANTS.PRESSURE_SCAN_RANGE then
                enemy_count = enemy_count + 1
                pressure = pressure + CONSTANTS.PRESSURE_ENEMY_WEIGHT

                if dis < CONSTANTS.PRESSURE_CLOSE_ENEMY_DIST then
                    close_enemy_count = close_enemy_count + 1
                    pressure = pressure + CONSTANTS.PRESSURE_ENEMY_WEIGHT
                end

                local flags = BB.classify_enemy(att_obj.unit, att_obj)
                if flags.special or flags.dozer or flags.taser or flags.cloaker then
                    special_count = special_count + 1
                    pressure = pressure + CONSTANTS.PRESSURE_SPECIAL_WEIGHT
                end

                if flags.tasing or flags.spooc_attack then
                    pressure = pressure + CONSTANTS.TASING_PRESSURE_BONUS
                end
            end
        end
    end

    local teammates_in_danger = 0
    local my_key = tostring(unit:key())
    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if u_key ~= my_key and status.unit and alive(status.unit) then
            if status.is_downed then
                teammates_in_danger = teammates_in_danger + 1
                pressure = pressure + CONSTANTS.PRESSURE_DOWNED_WEIGHT
            elseif status.in_danger then
                teammates_in_danger = teammates_in_danger + 1
                pressure = pressure + CONSTANTS.PRESSURE_TEAMMATE_LOW_HEALTH_WEIGHT
            end
            
            if status.needs_cover and not status.is_downed then
                pressure = pressure + CONSTANTS.PRESSURE_TEAMMATE_LOW_HEALTH_WEIGHT * 0.5
            end

            if status.is_reloading and not status.is_downed then
                pressure = pressure + CONSTANTS.PRESSURE_RELOADING_TEAMMATE_WEIGHT
            end
        end
    end
    
    local my_dmg = unit:character_damage()
    if my_dmg then
         local last_dmg_t = (my_dmg.last_suppression_t and my_dmg:last_suppression_t()) or 0
         if (t - last_dmg_t) < CONSTANTS.RECENT_DAMAGE_DURATION then
             pressure = pressure + CONSTANTS.PRESSURE_RECENT_DAMAGE_WEIGHT
         end
    end

    local my_health = get_unit_health_ratio(unit)
    if my_health < CONSTANTS.MY_HEALTH_CRITICAL then
        pressure = pressure + CONSTANTS.MY_HEALTH_CRITICAL_PRESSURE
    elseif my_health < CONSTANTS.MY_HEALTH_LOW then
        pressure = pressure + CONSTANTS.MY_HEALTH_LOW_PRESSURE
    end

    pressure = clamp(pressure, 0, 1)
    CoopSystem.data.team_pressure_cache[u_key] = { pressure = pressure, last_update = t }
    return pressure
end

function CoopSystem.get_pressure_adjusted_reload_threshold(unit, data, base_threshold)
    if not CoopSystem.is_enabled() then
        return base_threshold
    end

    local pressure = CoopSystem.calculate_team_pressure(unit, data)

    local threshold = base_threshold

    if pressure >= CONSTANTS.PRESSURE_HIGH_THRESHOLD then
        local factor = (pressure - CONSTANTS.PRESSURE_HIGH_THRESHOLD) / (1 - CONSTANTS.PRESSURE_HIGH_THRESHOLD)
        threshold = math.lerp(base_threshold, CONSTANTS.PRESSURE_RELOAD_MIN, factor)
    elseif pressure <= CONSTANTS.PRESSURE_LOW_THRESHOLD then
        local factor = (CONSTANTS.PRESSURE_LOW_THRESHOLD - pressure) / CONSTANTS.PRESSURE_LOW_THRESHOLD
        threshold = math.lerp(base_threshold, CONSTANTS.PRESSURE_RELOAD_MAX, factor)
    end

    return clamp(threshold, 0, 1)
end

BB.CoopSystem = CoopSystem
