local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local CoopCacheManager = BB.CoopCacheManager
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local ThreatAssessment = BB.ThreatAssessment
local CombatHelper = BB.CombatHelper
local AssignmentPlanner = BB.AssignmentPlanner

local clamp = Utils.clamp
local game_time = Utils.game_time
local get_unit_health_ratio = UnitOps.health_ratio
local are_units_foes = UnitOps.are_foes

local CoopSystem = {}

CoopSystem.data = BB.coop_data or {
    bot_observations = {},
    team_pressure_cache = {},
    assignment_snapshot = {},
    last_assignment_update = 0,
    assignment_dirty = true,
}
BB.coop_data = CoopSystem.data

CoopSystem.data.bot_observations = CoopSystem.data.bot_observations or {}
CoopSystem.data.team_pressure_cache = CoopSystem.data.team_pressure_cache or {}
CoopSystem.data.assignment_snapshot = CoopSystem.data.assignment_snapshot or {}
if CoopSystem.data.assignment_dirty == nil then
    CoopSystem.data.assignment_dirty = true
end

local function _make_assignment_snapshot()
    return {
        by_bot = {},
        owners_by_target = {},
        target_load = {},
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

local function _normalize_assignment_snapshot(snapshot)
    if type(snapshot) ~= "table" then
        snapshot = _make_assignment_snapshot()
    end

    snapshot.by_bot = type(snapshot.by_bot) == "table" and snapshot.by_bot or {}
    snapshot.owners_by_target = type(snapshot.owners_by_target) == "table"
            and snapshot.owners_by_target
            or {}
    snapshot.target_load = type(snapshot.target_load) == "table" and snapshot.target_load or {}

    snapshot.generated_at = nil
    snapshot.age = nil
    snapshot.by_target = nil
    snapshot.candidate_counts = nil
    snapshot.dummy_assignments = nil
    snapshot.local_fallbacks = nil

    return snapshot
end

CoopSystem.data.priority_targets = nil
CoopSystem.data.teammates_status = nil
CoopSystem.data.optimal_assignments = nil
CoopSystem.data.assignment_debug = nil
CoopSystem.data.assignment_snapshot = _normalize_assignment_snapshot(
        CoopSystem.data.assignment_snapshot
)

local function _get_assignment_snapshot()
    local snapshot = CoopSystem.data.assignment_snapshot
    if type(snapshot) ~= "table"
            or type(snapshot.by_bot) ~= "table"
            or type(snapshot.owners_by_target) ~= "table"
            or type(snapshot.target_load) ~= "table"
    then
        snapshot = _normalize_assignment_snapshot(snapshot)
        CoopSystem.data.assignment_snapshot = snapshot
    end

    return snapshot
end

local function _is_enabled()
    return BB:get("coop", false)
end

local function _get_ai_criminals()
    local group_ai = managers.groupai
    local group_state = group_ai and group_ai:state()

    return group_state
            and group_state.all_AI_criminals
            and group_state:all_AI_criminals()
            or {}
end

local function _get_teammate_status(bot_key, record)
    local unit = record and record.unit
    if not (alive(unit) and record.status ~= "removed") then
        return nil
    end

    bot_key = tostring(bot_key)

    local cached = CoopCacheManager.teammate_status:get(bot_key)
    if cached
            and cached.record == record
            and cached.unit == unit
            and cached.record_status == record.status
    then
        return cached
    end

    local combat_status = UnitOps.combat_status(unit)
    if not combat_status.is_alive or combat_status.is_dead then
        return nil
    end

    local health_ratio = get_unit_health_ratio(unit)
    local unit_movement = unit:movement()
    local anim_data = unit:anim_data()
    local status = {
        record = record,
        record_status = record.status,
        unit = unit,
        position = unit_movement and unit_movement:m_head_pos(),
        facing_direction = unit_movement and unit_movement:m_head_fwd(),
        in_danger = health_ratio < 0.3,
        needs_cover = health_ratio < 0.15,
        is_reloading = anim_data and anim_data.reload or false,
        is_downed = combat_status.is_downed,
        can_fight = record.status == nil and combat_status.can_fight,
    }

    CoopCacheManager.teammate_status:set(
            bot_key,
            status,
            CONSTANTS.COOP_STATUS_CACHE_TTL
    )

    return status
end

local function _get_teammate_status_for_unit(unit)
    if not alive(unit) then
        return nil
    end

    local u_key = unit:key()
    return _get_teammate_status(u_key, _get_ai_criminals()[u_key])
end

function CoopSystem.reset_level_state()
    local data = CoopSystem.data

    data.bot_observations = _clear_table(data.bot_observations)
    data.team_pressure_cache = _clear_table(data.team_pressure_cache)

    data.assignment_snapshot = _clear_table(data.assignment_snapshot)
    for key, value in pairs(_make_assignment_snapshot()) do
        data.assignment_snapshot[key] = value
    end

    data.last_assignment_update = 0
    data.assignment_dirty = true

    CoopCacheManager.teammate_status:clear()
    CoopCacheManager.threat_value:clear()
    CoopCacheManager.suitability:clear()
    CoopCacheManager.teammate_distance:clear()

    return true
end

local function _drop_bot_state(bot_key)
    bot_key = tostring(bot_key)
    CoopSystem.data.bot_observations[bot_key] = nil
    CoopCacheManager.teammate_status:clear(bot_key)

    local snapshot = _get_assignment_snapshot()
    local target_key = snapshot.by_bot[bot_key]
    if target_key then
        snapshot.by_bot[bot_key] = nil
        local owners = snapshot.owners_by_target[target_key]
        if owners then
            owners[bot_key] = nil
            local load = 0
            for _ in pairs(owners) do
                load = load + 1
            end

            if load == 0 then
                snapshot.owners_by_target[target_key] = nil
                snapshot.target_load[target_key] = nil
            else
                snapshot.target_load[target_key] = load
            end
        end
    end

    CoopSystem.data.assignment_dirty = true
end

local function _cleanup_stale_observations(now)
    now = now or game_time()
    local records_by_key = {}
    for raw_key, record in pairs(_get_ai_criminals()) do
        records_by_key[tostring(raw_key)] = record
    end

    for bot_key, snapshot in pairs(CoopSystem.data.bot_observations) do
        local status = _get_teammate_status(bot_key, records_by_key[tostring(bot_key)])
        local stale_snapshot = not (status and status.can_fight)
                or not (snapshot and snapshot.targets)
                or (now - (snapshot.last_update or 0)) > CONSTANTS.COOP_OBSERVATION_TTL

        if stale_snapshot then
            _drop_bot_state(bot_key)
        else
            for target_key, observation in pairs(snapshot.targets) do
                local stale_target = not (observation and observation.unit and alive(observation.unit))
                        or now > (observation.valid_until or 0)

                if stale_target then
                    snapshot.targets[target_key] = nil
                    CoopSystem.data.assignment_dirty = true
                end
            end
        end
    end
end

function CoopSystem.is_teammate_combat_ready(unit)
    local status = _is_enabled() and _get_teammate_status_for_unit(unit)
    return status and status.can_fight or false
end

function CoopSystem.get_reloading_teammates_count(exclude_key)
    if not _is_enabled() then
        return 0
    end

    local count = 0
    local t = game_time()
    local exclude_key_str = exclude_key and tostring(exclude_key)
    for raw_key, record in pairs(_get_ai_criminals()) do
        local bot_key = tostring(raw_key)
        local status = _get_teammate_status(bot_key, record)
        local brain = status and status.unit and status.unit:brain()
        local logic_data = brain and brain._logic_data
        local reload_intent_t = logic_data and logic_data._bb_reload_intent_t
        if reload_intent_t and reload_intent_t <= t then
            logic_data._bb_reload_intent_t = nil
            reload_intent_t = nil
        end

        if bot_key ~= exclude_key_str
                and status
                and status.can_fight
                and (status.is_reloading or reload_intent_t and reload_intent_t > t)
        then
            count = count + 1
        end
    end

    return count
end

local function _is_direction_covered(target_pos, my_unit)
    if not (target_pos and alive(my_unit)) then
        return false
    end

    local my_pos = my_unit:movement() and my_unit:movement():m_head_pos()
    if not my_pos or mvector3.distance(target_pos, my_pos) < 0.1 then
        return false
    end

    local my_dir = target_pos - my_pos
    mvector3.normalize(my_dir)

    local same_dir_threshold = 0.6
    local face_target_threshold = 0.6

    local my_key = tostring(my_unit:key())

    for raw_key, record in pairs(_get_ai_criminals()) do
        local bot_key = tostring(raw_key)
        local status = _get_teammate_status(bot_key, record)
        if bot_key ~= my_key
                and status
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

local function _role_changed(old_snapshot, restricted, fixed_target)
    if not old_snapshot then
        return restricted or fixed_target ~= nil
    end

    return old_snapshot.restricted ~= restricted
            or tostring(old_snapshot.fixed_target or "") ~= tostring(fixed_target or "")
end

local function _assignment_targets_changed(old_snapshot, new_snapshot)
    if not old_snapshot then
        return true
    end

    local old_targets = old_snapshot.targets or {}
    local new_targets = new_snapshot.targets or {}

    for target_key, new_target in pairs(new_targets) do
        local old_target = old_targets[target_key]
        if not old_target
                or old_target.unit ~= new_target.unit
                or (old_target.urgency or 1) ~= (new_target.urgency or 1)
                or old_target.durable ~= new_target.durable
        then
            return true
        end
    end

    for target_key in pairs(old_targets) do
        if not new_targets[target_key] then
            return true
        end
    end

    return false
end

local _update_assignments

function CoopSystem.submit_candidates(data, candidates, role)
    if not (_is_enabled() and data and alive(data.unit)) then
        return
    end

    local bot_key = tostring(data.key or data.unit:key())
    local status = _get_teammate_status_for_unit(data.unit)
    local old_snapshot = CoopSystem.data.bot_observations[bot_key]

    if not (status and status.can_fight) then
        if old_snapshot then
            _drop_bot_state(bot_key)
        end
        _update_assignments(true)
        return
    end

    local t = data.t or game_time()
    local restricted = role and role.restricted == true or false
    local fixed_target = role and role.target_key and tostring(role.target_key) or nil
    local observation_snapshot = {
        last_update = t,
        targets = {},
        restricted = restricted,
        fixed_target = fixed_target,
        is_reloading = status.is_reloading,
    }
    for target_key, candidate in pairs(candidates or {}) do
        target_key = tostring(target_key)
        if candidate.coop_assignable
                and candidate.data
                and alive(candidate.data.unit)
                and (candidate.valid_until or 0) >= t
        then
            local score = math.max(candidate.coop_score or 0, 0)
            if status.is_reloading then
                score = score * CONSTANTS.COOP_RELOADING_FACTOR
            end

            observation_snapshot.targets[target_key] = {
                unit = candidate.data.unit,
                score = score,
                urgency = candidate.urgency or 1,
                durable = candidate.durable == true,
                valid_until = candidate.valid_until,
            }
        end
    end

    if fixed_target and not observation_snapshot.targets[fixed_target] then
        fixed_target = nil
        observation_snapshot.fixed_target = nil
    end

    local old_assignment = _get_assignment_snapshot().by_bot[bot_key]
    local assignment_invalid = old_assignment
            and not observation_snapshot.targets[tostring(old_assignment)]
    local target_structure_changed = _assignment_targets_changed(
            old_snapshot,
            observation_snapshot
    )
    local role_state_changed = _role_changed(old_snapshot, restricted, fixed_target)
    local reload_state_changed = old_snapshot
            and old_snapshot.is_reloading ~= observation_snapshot.is_reloading
            or false
    local score_refresh_interval = CONSTANTS.ASSIGNMENT_SCORE_REFRESH_INTERVAL or 1
    local score_refresh_due = t - (CoopSystem.data.last_assignment_update or 0)
            >= score_refresh_interval
    local force_replan = target_structure_changed
            or assignment_invalid
            or role_state_changed
            or reload_state_changed

    CoopSystem.data.bot_observations[bot_key] = observation_snapshot
    if force_replan or score_refresh_due then
        CoopSystem.data.assignment_dirty = true
    end

    _update_assignments(force_replan)
end

_update_assignments = function(force)
    local t = game_time()
    _cleanup_stale_observations(t)

    if not _is_enabled() then
        CoopSystem.data.assignment_snapshot = _make_assignment_snapshot()
        CoopSystem.data.assignment_dirty = false
        return
    end

    if not force then
        if not CoopSystem.data.assignment_dirty then
            return
        end
    end

    CoopSystem.data.last_assignment_update = t
    CoopSystem.data.assignment_dirty = false

    local workers = {}
    local edges = {}
    local fixed_by_bot = {}
    local targets_by_key = {}
    local active_count = 0

    for raw_key, record in pairs(_get_ai_criminals()) do
        local bot_key = tostring(raw_key)
        local status = _get_teammate_status(bot_key, record)
        local bot_snapshot = CoopSystem.data.bot_observations[bot_key]
        if status
                and status.can_fight
                and bot_snapshot
                and (t - (bot_snapshot.last_update or 0)) <= CONSTANTS.COOP_OBSERVATION_TTL
        then
            active_count = active_count + 1

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

    local old_snapshot = _get_assignment_snapshot()
    local result = AssignmentPlanner.solve({
        bots = workers,
        targets = targets,
        edges = edges,
        previous_by_bot = old_snapshot.by_bot,
        fixed_by_bot = fixed_by_bot,
    })

    local snapshot = _make_assignment_snapshot()
    snapshot.by_bot = result.by_bot
    snapshot.owners_by_target = result.owners_by_target
    snapshot.target_load = result.target_load

    CoopSystem.data.assignment_snapshot = snapshot
end

function CoopSystem.get_assigned_target(my_key)
    local snapshot = _get_assignment_snapshot()
    return snapshot.by_bot[tostring(my_key)]
end

function CoopSystem.get_local_target_utility(bot_key, target_key, candidate)
    bot_key = tostring(bot_key)
    target_key = tostring(target_key)
    local snapshot = _get_assignment_snapshot()
    local owners = snapshot.owners_by_target[target_key] or {}
    local load = snapshot.target_load[target_key] or 0
    if owners[bot_key] then
        load = math.max(load - 1, 0)
    end

    local focus = candidate.focus
    if focus == "durable" then
        local combat_ready = 0
        for raw_key, record in pairs(_get_ai_criminals()) do
            local status = _get_teammate_status(raw_key, record)
            if status and status.can_fight then
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

function CoopSystem.remove_target(target_u_key)
    local target_key = tostring(target_u_key)
    local changed = false

    for _, bot_snapshot in pairs(CoopSystem.data.bot_observations) do
        if bot_snapshot
                and bot_snapshot.targets
                and bot_snapshot.targets[target_key]
        then
            bot_snapshot.targets[target_key] = nil
            changed = true
        end
    end

    local snapshot = _get_assignment_snapshot()
    for bot_key, assigned_target in pairs(snapshot.by_bot) do
        if tostring(assigned_target) == target_key then
            snapshot.by_bot[bot_key] = nil
            changed = true
        end
    end

    if snapshot.owners_by_target[target_key] or snapshot.target_load[target_key] then
        changed = true
    end
    snapshot.owners_by_target[target_key] = nil
    snapshot.target_load[target_key] = nil

    if changed then
        CoopSystem.data.assignment_dirty = true
        _update_assignments(true)
    end

    return changed
end

local function _get_closest_teammate_info(pos)
    if not (pos and CoopSystem.data) then
        return nil, false, nil
    end

    local ai_criminals = _get_ai_criminals()
    local cache_key = string.format("%.1f_%.1f_%.1f", pos.x, pos.y, pos.z)
    local cached = CoopCacheManager.teammate_distance:get(cache_key)
    if cached then
        local member_count = 0
        local cache_valid = true
        for raw_key, record in pairs(ai_criminals) do
            local status = _get_teammate_status(raw_key, record)
            if status then
                member_count = member_count + 1
                if not cached.members or cached.members[raw_key] ~= status then
                    cache_valid = false
                    break
                end
            end
        end

        if cache_valid and member_count == (cached.member_count or 0) then
            return cached.min_dist, cached.in_danger_any, cached.who
        end

        CoopCacheManager.teammate_distance:clear(cache_key)
    end

    local min_dist = math.huge
    local in_danger_any = false
    local who = nil
    local members = {}
    local member_count = 0

    for raw_key, record in pairs(ai_criminals) do
        local st = _get_teammate_status(raw_key, record)
        if st then
            members[raw_key] = st
            member_count = member_count + 1

            if st.position then
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
    end

    if min_dist == math.huge then
        return nil, false, nil
    end

    CoopCacheManager.teammate_distance:set(cache_key, {
        min_dist = min_dist,
        in_danger_any = in_danger_any,
        who = who,
        members = members,
        member_count = member_count,
    }, 0.2)

    return min_dist, in_danger_any, who
end

function CoopSystem.compute_dynamic_priority(my_unit, att_obj, data, target_pos, target_distance)
    if not (alive(my_unit) and att_obj and att_obj.unit and alive(att_obj.unit)) then
        return 0, "normal"
    end

    local enemy = att_obj.unit
    local flags = BB.classify_enemy(enemy, att_obj)
    local enemy_movement = enemy.movement and enemy:movement()
    local pos = target_pos
            or att_obj.m_head_pos
            or (enemy_movement
            and enemy_movement.m_head_pos
            and enemy_movement:m_head_pos())
    local my_movement = my_unit:movement()
    local my_head = my_movement and my_movement:m_head_pos()
    local dis = target_distance
            or att_obj.verified_dis
            or ((my_head and pos) and mvector3.distance(my_head, pos))
            or 2000

    local role_multiplier = ThreatAssessment.get_role_multiplier(
            enemy,
            att_obj,
            flags
    )
    local role_priority = math.max(role_multiplier - 1, 0)
            * THREAT_WEIGHTS.COOP_ROLE_SCALE
    if flags.shield then
        local has_ap = CombatHelper.has_ap_ammo(my_unit)
        local blocked = pos and CombatHelper.shield_blocks_default(my_unit, pos)
        if blocked and not has_ap and dis > CONSTANTS.MELEE_DISTANCE then
            role_priority = role_priority * THREAT_WEIGHTS.COOP_SHIELD_BLOCKED_MUL
        end
    end

    local prio = role_priority
    local state = "normal"

    local ally_dist
    local closest_ally
    if pos then
        local ignored_danger
        ally_dist, ignored_danger, closest_ally = _get_closest_teammate_info(pos)
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

    if flags.dozer then
        if pos and my_head then
            local e_fwd = enemy_movement
                    and enemy_movement.m_head_fwd
                    and enemy_movement:m_head_fwd()
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
    if flags.cloaker and dis < THREAT_WEIGHTS.COOP_CLOAKER_CLOSE_RANGE then
        prio = prio + THREAT_WEIGHTS.COOP_CLOAKER_CLOSE_BONUS
    end
    if flags.sniper and dis > THREAT_WEIGHTS.COOP_SNIPER_FAR_RANGE then
        prio = prio + THREAT_WEIGHTS.COOP_SNIPER_FAR_BONUS
    end

    if flags.tasing then
        prio = prio + THREAT_WEIGHTS.COOP_TASING_PRIO
        state = "tasing_teammate"
    end

    if flags.spooc_attack then
        prio = prio + THREAT_WEIGHTS.COOP_SPOOC_PRIO
        state = "spooc_attacking"
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

    if pos and not _is_direction_covered(pos, my_unit) then
        prio = prio + (THREAT_WEIGHTS.DIRECTION_BONUS / 3)
    end

    if att_obj.verified then
        prio = prio + THREAT_WEIGHTS.COOP_VERIFIED_BONUS
    end

    prio = prio * ThreatAssessment.distance_falloff(dis, flags)

    prio = prio * team_factor
    return prio, state
end

function CoopSystem.calculate_team_pressure(unit, data)
    if not (alive(unit) and _is_enabled()) then
        return 0
    end

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

    for _, att_obj in pairs(data.detected_attention_objects or {}) do
        if att_obj.identified
                and att_obj.verified
                and att_obj.unit
                and alive(att_obj.unit)
                and are_units_foes(unit, att_obj.unit)
        then
            local dis = att_obj.verified_dis
            if dis and dis <= CONSTANTS.PRESSURE_SCAN_RANGE then
                pressure = pressure + CONSTANTS.PRESSURE_ENEMY_WEIGHT

                if dis < CONSTANTS.PRESSURE_CLOSE_ENEMY_DIST then
                    pressure = pressure + CONSTANTS.PRESSURE_ENEMY_WEIGHT
                end

                local flags = BB.classify_enemy(att_obj.unit, att_obj)
                if flags.special or flags.dozer or flags.taser or flags.cloaker then
                    pressure = pressure + CONSTANTS.PRESSURE_SPECIAL_WEIGHT
                end

                if flags.tasing or flags.spooc_attack then
                    pressure = pressure + CONSTANTS.TASING_PRESSURE_BONUS
                end
            end
        end
    end

    local my_key = tostring(unit:key())
    for raw_key, record in pairs(_get_ai_criminals()) do
        local bot_key = tostring(raw_key)
        local status = _get_teammate_status(bot_key, record)
        if bot_key ~= my_key and status then
            if status.is_downed then
                pressure = pressure + CONSTANTS.PRESSURE_DOWNED_WEIGHT
            elseif status.in_danger then
                pressure = pressure + CONSTANTS.PRESSURE_TEAMMATE_LOW_HEALTH_WEIGHT
            end

            if status.needs_cover and not status.is_downed then
                pressure = pressure + CONSTANTS.PRESSURE_TEAMMATE_LOW_HEALTH_WEIGHT * 0.5
            end

            if status.can_fight and status.is_reloading and not status.is_downed then
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
    if not _is_enabled() then
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
