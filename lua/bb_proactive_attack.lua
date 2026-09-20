local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local UnitOps = BB.UnitOps
local CombatHelper = BB.CombatHelper
local EnemyClassifier = BB.EnemyClassifier
local ThreatAssessment = BB.ThreatAssessment
local AssignmentPlanner = BB.AssignmentPlanner
local RescueCoordinator = BB.RescueCoordinator
local Utils = BB.Utils

local game_time = Utils.game_time

local ProactiveAttack = BB.ProactiveAttack or {}
BB.ProactiveAttack = ProactiveAttack

local state = BB.proactive_attack_state or {
    assignments = {},
    recall_holds = {},
    retry_until = {},
    guard_key = nil,
    next_update_t = 0,
    next_assignment_id = 0,
    next_recall_id = 0,
}
BB.proactive_attack_state = state

state.assignments = state.assignments or {}
state.recall_holds = state.recall_holds or {}
state.retry_until = state.retry_until or {}
state.observations = state.observations or {}
state.nav_cache = state.nav_cache or {}
state.next_update_t = state.next_update_t or 0
state.next_assignment_id = state.next_assignment_id or 0
state.next_recall_id = state.next_recall_id or 0

local function clear_table(value)
    for key in pairs(value) do
        value[key] = nil
    end
end

local function get_group_state()
    local group_ai = managers.groupai
    return group_ai and group_ai:state() or nil
end

local function loud_combat_is_active(group_state)
    if not group_state then
        return false
    end

    return not group_state:whisper_mode()
            and group_state:enemy_weapons_hot()
            or false
end

local function get_unit_key(unit)
    return alive(unit) and tostring(unit:key()) or nil
end

local function get_unit_position(unit)
    if not alive(unit) then
        return nil
    end

    local movement = unit:movement()
    if movement then
        if movement.m_head_pos then
            return movement:m_head_pos()
        elseif movement.m_pos then
            return movement:m_pos()
        end
    end

    return unit:position()
end

local function is_unit_dead(unit)
    if not alive(unit) then
        return true
    end

    local damage = unit:character_damage()
    if not damage then
        return false
    end

    local dead = damage.dead
    if type(dead) == "function" then
        dead = damage:dead()
    end

    return dead == true or damage._dead == true
end

local function minimum_player_distance(position, players)
    if not position then
        return math.huge
    end

    local best_distance = math.huge
    for _, player in ipairs(players) do
        if player.position then
            best_distance = math.min(best_distance, mvector3.distance(position, player.position))
        end
    end

    return best_distance
end

local function get_live_players(group_state)
    local players = {}
    local distressed = false

    for _, record in pairs(group_state:all_player_criminals()) do
        local unit = record and record.unit
        local status = record and record.status
        if alive(unit) then
            local disabled_status = status
                    and status ~= "electrified"
                    and status ~= "dead"

            if RescueCoordinator.target_needs_help(unit) or disabled_status then
                distressed = true
            end

            if status ~= "dead" then
                local position = get_unit_position(unit)
                if position then
                    table.insert(players, {
                        unit = unit,
                        position = position,
                    })
                end
            end
        end
    end

    if not distressed then
        for _, record in pairs(group_state:all_AI_criminals()) do
            if RescueCoordinator.target_needs_help(record and record.unit) then
                distressed = true
                break
            end
        end
    end

    return players, distressed
end

local function target_is_valid(observer, unit)
    return alive(unit)
            and not is_unit_dead(unit)
            and UnitOps.are_foes(observer, unit)
            and not UnitOps.is_surrendering(unit)
end

local function make_target_observation(observer, attention_data, t)
    if not (attention_data and attention_data.identified) then
        return nil
    end

    local target_unit = attention_data.unit
    if not target_is_valid(observer, target_unit) then
        return nil
    end

    local reaction = attention_data.reaction
            or attention_data.settings and attention_data.settings.reaction
    if type(reaction) ~= "number" or reaction < AIAttentionObject.REACT_COMBAT then
        return nil
    end

    local last_seen_t
    if attention_data.verified or attention_data.nearly_visible then
        last_seen_t = t
    elseif type(attention_data.verified_t) == "number"
            and t - attention_data.verified_t <= CONSTANTS.PROACTIVE_TARGET_MEMORY
    then
        last_seen_t = attention_data.verified_t
    end

    if not last_seen_t then
        return nil
    end

    local key = tostring(attention_data.u_key or target_unit:key())
    local previous = state.observations[key]
    local visible = attention_data.verified or attention_data.nearly_visible
    local target_pos = attention_data.verified
            and (attention_data.m_head_pos or attention_data.verified_pos)
            or attention_data.last_verified_pos or attention_data.verified_pos
    if not target_pos then
        return nil
    end

    local nav_position, nav_seg
    if visible then
        local movement = target_unit:movement()
        local tracker = movement and movement:nav_tracker()
        if alive(tracker) and not tracker:lost() then
            nav_position = tracker:field_position()
            nav_seg = tracker:nav_segment()
        end
    elseif previous and previous.unit == target_unit and previous.last_seen_t >= last_seen_t then
        nav_position = previous.nav_position
        nav_seg = previous.nav_seg
        target_pos = previous.position
        last_seen_t = previous.last_seen_t
    end

    return {
        key = key,
        unit = target_unit,
        position = target_pos,
        nav_position = nav_position,
        nav_seg = nav_seg,
        attention_data = attention_data,
        last_seen_t = last_seen_t,
        verified = attention_data.verified == true,
    }
end

local function observation_is_fresher(observation, current)
    return observation.last_seen_t > current.last_seen_t
            or observation.last_seen_t == current.last_seen_t
            and observation.verified
            and not current.verified
end

local function collect_known_targets(group_state, players, max_distance, t)
    local targets_by_key = {}

    for _, unit_data in pairs(group_state:all_AI_criminals()) do
        local observer = unit_data and unit_data.unit
        local status = UnitOps.combat_status(observer)
        local logic_data = status.is_alive and observer:brain()._logic_data

        if status.can_fight
                and logic_data
                and logic_data.detected_attention_objects
        then
            for _, attention_data in pairs(logic_data.detected_attention_objects) do
                local observation = make_target_observation(observer, attention_data, t)
                if observation then
                    local target = targets_by_key[observation.key]
                    if not target or observation_is_fresher(observation, target) then
                        targets_by_key[observation.key] = observation
                    end
                end
            end
        end
    end

    for key, previous in pairs(state.observations) do
        if not targets_by_key[key]
                and t - previous.last_seen_t <= CONSTANTS.PROACTIVE_TARGET_MEMORY
                and target_is_valid(players[1].unit, previous.unit)
        then
            previous.verified = false
            targets_by_key[key] = previous
        end
    end

    local targets = {}
    for target_key, target in pairs(targets_by_key) do
        target.player_distance = minimum_player_distance(target.position, players)
        if target.player_distance <= max_distance then
            target.position = mvector3.copy(target.position)
            target.nav_position = target.nav_position and mvector3.copy(target.nav_position)
            local flags = EnemyClassifier.classify(target.unit, target.attention_data)
            target.focus = nil
            if flags.tasing or flags.spooc_attack then
                target.urgency = 3
                target.focus = "urgent"
            elseif flags.special or flags.dozer then
                target.urgency = 2
                if flags.dozer then
                    target.focus = "durable"
                end
            elseif flags.turret then
                target.urgency = 1
                target.focus = "durable"
            else
                target.urgency = 1
            end

            targets_by_key[target_key] = target
            table.insert(targets, target)
        else
            targets_by_key[target_key] = nil
        end
    end

    state.observations = targets_by_key
    return targets, targets_by_key
end

function ProactiveAttack:is_enabled()
    return Network:is_server() and BB:get("proactive", false) or false
end

function ProactiveAttack:is_attack_objective(objective)
    return objective and objective._bb_proactive_attack == true or false
end

local function is_live_player(group_state, unit)
    if not (group_state and alive(unit)) then
        return false
    end

    local record = group_state:all_player_criminals()[unit:key()]

    return record ~= nil and record.status ~= "dead"
end

local function recall_objective_is_current(recall)
    if not (recall and alive(recall.unit) and alive(recall.caller)) then
        return false
    end

    local brain = recall.unit:brain()
    local objective = brain and brain:objective()

    return objective == recall.objective
            and objective._bb_proactive_recall_id == recall.id
            and objective.type == "follow"
            and objective.follow_unit == recall.caller
            and not objective.forced
            and not objective.action
end

local function get_active_recalled_guard(all_units)
    local guard_key = state.guard_key
    local recall = guard_key and state.recall_holds[guard_key]

    if not recall_objective_is_current(recall)
            or all_units[guard_key] ~= recall.unit
    then
        return nil
    end

    local status = UnitOps.combat_status(recall.unit)
    return status.can_fight and recall or nil
end

function ProactiveAttack:_clear_recall_hold(bot_key)
    if bot_key == nil then
        return false
    end

    bot_key = tostring(bot_key)
    local recall = state.recall_holds[bot_key]
    if not recall then
        return false
    end

    local objective = recall.objective
    if objective and objective._bb_proactive_recall_id == recall.id then
        objective._bb_proactive_recall_id = nil
    end

    state.recall_holds[bot_key] = nil
    return true
end

function ProactiveAttack:_clear_all_recall_holds()
    local keys = {}
    for bot_key in pairs(state.recall_holds) do
        table.insert(keys, bot_key)
    end

    for _, bot_key in ipairs(keys) do
        self:_clear_recall_hold(bot_key)
    end

    return true
end

function ProactiveAttack:on_long_distance_interacted(
        unit,
        other_unit,
        secondary,
        previous_objective
)
    local objective = unit:brain():objective()
    local command_applied = objective
            and objective ~= previous_objective
            and (objective.follow_unit == other_unit
            or objective.type == "throw_bag" and objective.unit == other_unit)
    if not command_applied then
        return false
    end

    local bot_key = tostring(unit:key())
    self:_clear_recall_hold(bot_key)
    state.assignments[bot_key] = nil
    state.next_update_t = 0

    if not self:is_enabled()
            or secondary
            or not is_live_player(get_group_state(), other_unit)
            or objective.type ~= "follow"
    then
        return false
    end

    state.next_recall_id = state.next_recall_id + 1
    local recall_id = state.next_recall_id
    objective._bb_proactive_recall_id = recall_id
    state.recall_holds[bot_key] = {
        id = recall_id,
        unit = unit,
        caller = other_unit,
        objective = objective,
    }

    return true
end

function ProactiveAttack:_update_recall_holds(group_state, t, suspend_release)
    local keys = {}
    for bot_key in pairs(state.recall_holds) do
        table.insert(keys, bot_key)
    end

    for _, bot_key in ipairs(keys) do
        local recall = state.recall_holds[bot_key]
        if not recall_objective_is_current(recall)
                or not is_live_player(group_state, recall and recall.caller)
        then
            self:_clear_recall_hold(bot_key)
        else
            local unit = recall.unit
            local movement = unit:movement()
            local base = unit:base()
            local keeper_active = base.kpr_is_keeper
                    or type(base.kpr_mode) == "number" and base.kpr_mode > 1

            if not movement or movement:should_stay() or keeper_active then
                self:_clear_recall_hold(bot_key)
            elseif suspend_release then
                recall.arrived_since_t = nil
            else
                local status = UnitOps.combat_status(unit)
                local arrived = recall.objective.in_place == true

                if not status.can_fight
                        or movement:carrying_bag()
                        or not arrived
                then
                    recall.arrived_since_t = nil
                elseif not recall.arrived_since_t then
                    recall.arrived_since_t = t
                elseif t - recall.arrived_since_t
                        >= CONSTANTS.PROACTIVE_RECALL_HOLD_DURATION
                then
                    local objective = recall.objective
                    self:_clear_recall_hold(bot_key)
                    objective.called = false
                    objective.is_default = true
                    state.next_update_t = 0
                end
            end
        end
    end

    return true
end

local function objective_allows_attack(objective)
    if not objective then
        return true
    elseif ProactiveAttack:is_attack_objective(objective) then
        return true
    elseif objective.forced
            or objective.called
            or objective.action
            or objective.type == "revive"
            or objective.type == "act"
            or objective.type == "throw_bag"
    then
        return false
    end

    return objective.is_default == true
            and (objective.type == "follow" or objective.type == "free")
end

local function bot_is_eligible(unit, players, status)
    if not status.can_fight then
        return false
    end

    local bot_key = tostring(unit:key())
    if state.recall_holds[bot_key] then
        return false
    end

    local movement = unit:movement()
    local brain = unit:brain()
    local logic_data = brain._logic_data
    if not logic_data then
        return false
    end

    if logic_data.name == "disabled"
            or logic_data.name == "inactive"
            or logic_data.name == "surrender"
    then
        return false
    end

    if movement:should_stay() then
        return false
    end

    local base = unit:base()
    if base.kpr_is_keeper
            or type(base.kpr_mode) == "number" and base.kpr_mode > 1
    then
        return false
    end

    if movement:carrying_bag() then
        return false
    end

    local position = movement:m_head_pos()
    local player_distance = minimum_player_distance(position, players)
    if player_distance > CONSTANTS.PROACTIVE_RECALL_DISTANCE then
        return false
    end

    if not objective_allows_attack(brain:objective()) then
        return false
    end

    return true, {
        key = bot_key,
        unit = unit,
        brain = brain,
        data = logic_data,
        position = position,
        player_distance = player_distance,
    }
end

local function collect_bots(group_state, players)
    local all_units = {}
    local eligible = {}
    local eligible_by_key = {}

    for key, unit_data in pairs(group_state:all_AI_criminals()) do
        local unit = unit_data and unit_data.unit
        local status = UnitOps.combat_status(unit)
        if status.is_alive then
            local bot_key = tostring(key)
            all_units[bot_key] = unit

            local can_attack, bot = bot_is_eligible(unit, players, status)
            if can_attack then
                table.insert(eligible, bot)
                eligible_by_key[bot.key] = bot
            end
        end
    end

    table.sort(eligible, function(a, b)
        return a.key < b.key
    end)

    return all_units, eligible, eligible_by_key
end

local function can_restore_native_objective(unit)
    if not UnitOps.combat_status(unit).can_fight then
        return false
    end

    local logic_data = unit:brain()._logic_data
    if not logic_data then
        return false
    end

    local logic_name = logic_data.name

    return logic_name ~= "disabled"
            and logic_name ~= "inactive"
            and logic_name ~= "surrender"
end

local function target_damage_supports_objective_listeners(unit)
    if not alive(unit) then
        return false
    end

    local damage = unit:character_damage()

    return not damage
            or type(damage.add_listener) == "function"
            and type(damage.remove_listener) == "function"
end

local function prepare_objective_for_removal(objective)
    local follow_unit = objective and objective.follow_unit
    if not follow_unit then
        return
    end

    if not alive(follow_unit) then
        objective.destroy_clbk_key = nil
        objective.death_clbk_key = nil
        return
    end

    if objective.death_clbk_key
            and not target_damage_supports_objective_listeners(follow_unit)
    then
        objective.death_clbk_key = nil
    end
end

function ProactiveAttack:_release_bot(unit, group_state, restore_native)
    local bot_key = get_unit_key(unit)
    if not bot_key then
        return false
    end

    state.assignments[bot_key] = nil

    local brain = unit:brain()
    local objective = brain:objective()
    if not self:is_attack_objective(objective) then
        return false
    end

    objective.fail_clbk = nil
    objective.complete_clbk = nil
    objective.followup_objective = nil
    prepare_objective_for_removal(objective)
    brain:set_objective(nil)

    if restore_native and group_state and can_restore_native_objective(unit) then
        group_state:on_criminal_jobless(unit)
    end

    return true
end

function ProactiveAttack:release_all(group_state, restore_native)
    group_state = group_state or get_group_state()

    local units = {}
    for bot_key, assignment in pairs(state.assignments) do
        if assignment and alive(assignment.unit) then
            units[bot_key] = assignment.unit
        end
    end

    if group_state then
        for key, unit_data in pairs(group_state:all_AI_criminals()) do
            if unit_data and alive(unit_data.unit) then
                units[tostring(key)] = unit_data.unit
            end
        end
    end

    for _, unit in pairs(units) do
        self:_release_bot(unit, group_state, restore_native)
    end

    clear_table(state.assignments)
    state.guard_key = nil

    return true
end

local function cleanup_retry_cooldowns(t)
    for bot_key, target_cooldowns in pairs(state.retry_until) do
        for target_key, retry_t in pairs(target_cooldowns) do
            if t >= retry_t then
                target_cooldowns[target_key] = nil
            end
        end

        if not next(target_cooldowns) then
            state.retry_until[bot_key] = nil
        end
    end

    for key, entry in pairs(state.nav_cache) do
        if t >= entry.expires_t then
            state.nav_cache[key] = nil
        end
    end
end

local function target_retry_is_active(bot_key, target_key, t)
    local bot_cooldowns = state.retry_until[bot_key]
    return bot_cooldowns and t < (bot_cooldowns[target_key] or 0) or false
end

local function select_guard(eligible, eligible_by_key)
    if #eligible < 2 then
        state.guard_key = nil
        return nil
    end

    local current_guard = state.guard_key and eligible_by_key[state.guard_key]
    if current_guard then
        return current_guard
    end

    local best_guard
    for _, bot in ipairs(eligible) do
        if not best_guard
                or bot.player_distance < best_guard.player_distance
                or bot.player_distance == best_guard.player_distance and bot.key < best_guard.key
        then
            best_guard = bot
        end
    end

    state.guard_key = best_guard and best_guard.key or nil
    return best_guard
end

local function build_attack_plan(attackers, targets, targets_by_key, t)
    local edges = {}
    local target_defs_by_key = {}
    local previous_by_bot = {}

    for _, bot in ipairs(attackers) do
        local bot_edges = {}
        edges[bot.key] = bot_edges

        local previous = state.assignments[bot.key]
        if previous then
            previous_by_bot[bot.key] = previous.target_key
        end

        local locked_target = previous and t < (previous.lock_until or 0)
                and targets_by_key[previous.target_key]
        local locked_score
        if locked_target and not target_retry_is_active(bot.key, locked_target.key, t) then
            locked_score = ThreatAssessment.calculate_threat_value(
                    bot.unit, locked_target.attention_data, bot.data,
                    mvector3.distance(bot.position, locked_target.position), locked_target.position
            )
        end
        if not locked_score or locked_score <= 0 then
            locked_target = nil
        end

        for _, target in ipairs(targets) do
            if (not locked_target or target == locked_target or target.urgency >= 3)
                    and not target_retry_is_active(bot.key, target.key, t)
            then
                local distance = mvector3.distance(bot.position, target.position)
                local score = target == locked_target and locked_score or ThreatAssessment.calculate_threat_value(
                        bot.unit,
                        target.attention_data,
                        bot.data,
                        distance,
                        target.position
                )

                if score > 0 then
                    bot_edges[target.key] = {
                        score = score,
                        urgency = target.urgency,
                    }

                    local target_def = target_defs_by_key[target.key]
                    if not target_def then
                        target_def = {
                            key = target.key,
                            unit = target.unit,
                            urgency = target.urgency,
                            max_score = score,
                            focus = target.focus,
                        }
                        target_defs_by_key[target.key] = target_def
                    else
                        target_def.max_score = math.max(target_def.max_score, score)
                    end
                end
            end
        end

    end

    local target_defs = {}
    for _, target_def in pairs(target_defs_by_key) do
        table.insert(target_defs, target_def)
    end

    local result = AssignmentPlanner.solve({
        bots = attackers,
        targets = target_defs,
        edges = edges,
        previous_by_bot = previous_by_bot,
    })

    return result.by_bot
end

local function delay_target_retry(bot_key, target_key, t)
    state.retry_until[bot_key] = state.retry_until[bot_key] or {}
    state.retry_until[bot_key][target_key] = t + CONSTANTS.PROACTIVE_RETRY_COOLDOWN
end

function ProactiveAttack:_on_objective_failed(bot_key, assignment_id, unit, failed_objective)
    bot_key = tostring(bot_key)

    local assignment = state.assignments[bot_key]
    if not assignment or assignment.id ~= assignment_id or assignment.unit ~= unit then
        return
    end

    local brain = alive(unit) and unit:brain()
    local current_objective = brain and brain:objective()
    local failed_current_objective = self:is_attack_objective(current_objective)
            and current_objective._bb_proactive_assignment_id == assignment_id

    if failed_current_objective
            and failed_objective and failed_objective ~= current_objective
    then
        return
    end

    if failed_current_objective then
        prepare_objective_for_removal(current_objective)
    end

    state.assignments[bot_key] = nil
    state.next_update_t = 0

    if failed_current_objective then
        delay_target_retry(bot_key, assignment.target_key, game_time())
        if assignment.nav_cache_key then
            state.nav_cache[assignment.nav_cache_key] = nil
        end
    end
end

local function valid_range(value)
    return type(value) == "number" and value > 0 and value < math.huge
end

local function get_engage_range(bot)
    local inventory = bot.unit:inventory()
    local weapon = inventory and inventory:equipped_unit()
    local weapon_base = alive(weapon) and weapon:base()
    local weapon_tweak = weapon_base and weapon_base.weapon_tweak_data
            and weapon_base:weapon_tweak_data()
    local usage = weapon_tweak and weapon_tweak.usage
    local weapons = bot.data.char_tweak and bot.data.char_tweak.weapon
    local weapon_data = usage and weapons and weapons[usage]
    local range = weapon_data and weapon_data.range
            or bot.data.internal_data and bot.data.internal_data.weapon_range

    if type(range) == "table" then
        range = valid_range(range.optimal) and range.optimal
                or valid_range(range.close) and range.close
                or range.far
    end

    return valid_range(range) and range or CONSTANTS.PROACTIVE_DEFAULT_ENGAGE_RANGE
end

local fire_slotmask, ap_fire_slotmask

local function can_engage(bot, target, range)
    local attention_objects = bot.data.detected_attention_objects
    local attention = attention_objects and attention_objects[target.unit:key()]
    if not (attention and attention.identified and attention.verified)
            or (attention.reaction or 0) < AIAttentionObject.REACT_COMBAT
    then
        return false
    end

    local position = attention.m_head_pos or attention.verified_pos
    if not position or mvector3.distance_sq(bot.position, position) > range * range then
        return false
    end

    fire_slotmask = fire_slotmask
            or managers.slot:get_mask("bullet_impact_targets_no_criminals")
    local mask = fire_slotmask
    if CombatHelper.has_ap_ammo(bot.unit) then
        ap_fire_slotmask = ap_fire_slotmask
                or fire_slotmask - managers.slot:get_mask("enemy_shield_check")
        mask = ap_fire_slotmask
    end

    local ray = World:raycast(
            "ray", bot.position, position,
            "slot_mask", mask,
            "ignore_unit", bot.unit
    )
    return not ray or ray.unit == target.unit
end

local function movement_can_change(bot)
    local my_data = bot.data.internal_data
    return not bot.unit:movement():chk_action_forbidden("walk")
            and not (my_data and (my_data.acting
            or my_data.has_old_action
            or my_data.surprised
            or my_data.moving_to_cover
            or my_data.walking_to_cover_shoot_pos
            or my_data._turning_to_intimidate))
end

local function nav_segment_is_accessible(navigation, nav_seg, access)
    local segment = nav_seg and navigation._nav_segments[nav_seg]
    return segment and not segment.disabled
            and not navigation._quad_field:is_nav_segment_blocked(nav_seg, access)
end

local function resolve_remembered_navigation(target)
    if target.nav_position then
        return
    end

    local navigation = managers.navigation
    local tracker = navigation:create_nav_tracker(target.position)
    if not alive(tracker) then
        return
    end

    local position = tracker:field_position()
    local max_distance = CONSTANTS.PROACTIVE_NAV_PROJECTION_MAX_DISTANCE
    if position and mvector3.distance_sq(position, target.position) <= max_distance * max_distance then
        target.nav_position = mvector3.copy(position)
        target.nav_seg = tracker:nav_segment()
    end
    navigation:destroy_nav_tracker(tracker)
end

local function target_is_reachable(bot, target, t)
    local navigation = managers.navigation
    local tracker = bot.unit:movement():nav_tracker()
    if not (alive(tracker) and not tracker:lost() and target.nav_position) then
        return false
    end

    local from_seg = tracker:nav_segment()
    local to_seg = target.nav_seg
    local access = bot.brain:SO_access()
    if not nav_segment_is_accessible(navigation, from_seg, access)
            or not nav_segment_is_accessible(navigation, to_seg, access)
    then
        return false
    end

    local key = tostring(from_seg) .. ":" .. tostring(to_seg) .. ":" .. tostring(access)
    local cached = state.nav_cache[key]
    if cached and t < cached.expires_t then
        return cached.reachable, key
    end

    local path = navigation:search_coarse({
        from_tracker = tracker,
        to_seg = to_seg,
        to_pos = target.nav_position,
        access_pos = access,
        id = "BB_ProactiveAttack_" .. bot.key,
    })
    local reachable = type(path) == "table" and #path > 0
    state.nav_cache[key] = {
        reachable = reachable,
        expires_t = t + (reachable and CONSTANTS.PROACTIVE_NAV_CACHE_TTL
                or CONSTANTS.PROACTIVE_RETRY_COOLDOWN),
    }

    return reachable, key
end

local function make_attack_objective(bot, target, assignment_id, phase)
    local bot_key = bot.key
    local objective = {
        is_default = true,
        called = false,
        scan = true,
        type = "free",
        attitude = "engage",
        stance = "hos",
        in_place = phase == "engage" or nil,
        _bb_proactive_attack = true,
        _bb_proactive_assignment_id = assignment_id,
        _bb_proactive_target_key = target.key,
        _bb_proactive_phase = phase,
    }
    objective.fail_clbk = function(unit)
        ProactiveAttack:_on_objective_failed(bot_key, assignment_id, unit, objective)
    end

    if phase == "advance" then
        objective.haste = "run"
        objective.nav_seg = target.nav_seg
        objective.pos = mvector3.copy(target.nav_position)
        objective.followup_objective = make_attack_objective(
                bot, target, assignment_id, "engage"
        )
        objective.complete_clbk = function(unit)
            local assignment = state.assignments[bot_key]
            if assignment and assignment.id == assignment_id
                    and alive(unit)
                    and unit:brain():objective() == objective.followup_objective
            then
                assignment.next_repath_t = game_time() + CONSTANTS.PROACTIVE_REPATH_INTERVAL
                assignment.blocked_since_t = nil
            end
        end
    end

    return objective
end

function ProactiveAttack:_assign_target(bot, target, t)
    t = t or game_time()
    local current_assignment = state.assignments[bot.key]
    local current_objective = bot.brain:objective()
    local continuing = current_assignment
            and current_assignment.target_key == target.key
            and current_assignment.target_unit == target.unit
            and self:is_attack_objective(current_objective)
            and current_objective._bb_proactive_assignment_id == current_assignment.id

    if not objective_allows_attack(current_objective) then
        return false
    end

    if not bot.brain:is_available_for_assignment() then
        return false
    end

    local range = get_engage_range(bot)
    local engaging = continuing and current_objective._bb_proactive_phase == "engage"
    local engage_range = engaging and range * CONSTANTS.PROACTIVE_RESUME_RANGE_MUL or range
    local can_shoot = can_engage(bot, target, engage_range)
    local phase = can_shoot and "engage" or "advance"

    if not can_shoot then
        resolve_remembered_navigation(target)
    end

    if not can_shoot and (not target.nav_position
            or not nav_segment_is_accessible(managers.navigation, target.nav_seg, bot.brain:SO_access()))
    then
        delay_target_retry(bot.key, target.key, t)
        self:_release_bot(bot.unit, get_group_state(), true)
        return false
    end

    if continuing then
        current_assignment.last_seen_t = target.last_seen_t
        if can_shoot then
            current_assignment.blocked_since_t = nil
            if engaging then
                return true
            end
        else
            if engaging then
                current_assignment.blocked_since_t = current_assignment.blocked_since_t or t
                local out_of_range = mvector3.distance_sq(bot.position, target.position)
                        > engage_range * engage_range
                if not out_of_range
                        and t - current_assignment.blocked_since_t < CONSTANTS.PROACTIVE_OBSTRUCTION_DELAY
                then
                    return true
                end
                local tolerance = CONSTANTS.PROACTIVE_DESTINATION_TOLERANCE
                if mvector3.distance_sq(bot.unit:movement():m_pos(), target.nav_position)
                        <= tolerance * tolerance
                then
                    return true
                end
            elseif current_objective._bb_proactive_phase == "advance"
                    and current_objective.nav_seg == target.nav_seg
                    and target.nav_position and current_objective.pos
                    and mvector3.distance_sq(current_objective.pos, target.nav_position)
                    < CONSTANTS.PROACTIVE_REPATH_DISTANCE * CONSTANTS.PROACTIVE_REPATH_DISTANCE
            then
                return true
            end

            if t < (current_assignment.next_repath_t or 0) then
                return true
            end
        end
    end

    if not movement_can_change(bot) then
        return false
    end

    local nav_cache_key
    if phase == "advance" then
        local reachable
        reachable, nav_cache_key = target_is_reachable(bot, target, t)
        if not reachable then
            delay_target_retry(bot.key, target.key, t)
            self:_release_bot(bot.unit, get_group_state(), true)
            return false
        end
    end

    if self:is_attack_objective(current_objective) then
        current_objective.fail_clbk = nil
        current_objective.complete_clbk = nil
        current_objective.followup_objective = nil
        prepare_objective_for_removal(current_objective)
    end

    state.next_assignment_id = state.next_assignment_id + 1
    local assignment_id = state.next_assignment_id
    local objective = make_attack_objective(bot, target, assignment_id, phase)
    state.assignments[bot.key] = {
        id = assignment_id,
        unit = bot.unit,
        target_key = target.key,
        target_unit = target.unit,
        last_seen_t = target.last_seen_t,
        lock_until = continuing and current_assignment.lock_until or t + CONSTANTS.PROACTIVE_TARGET_LOCK,
        next_repath_t = continuing and phase == "engage" and current_assignment.next_repath_t
                or t + CONSTANTS.PROACTIVE_REPATH_INTERVAL,
        nav_cache_key = nav_cache_key,
    }

    bot.brain:set_objective(objective)
    if phase == "engage" and bot.brain:objective() == objective then
        bot.brain:action_request({ type = "idle", body_part = 2 })
    end

    return bot.brain:objective() == objective
end

local function assignment_is_current(assignment, unit)
    local brain = alive(unit) and unit:brain()
    local objective = brain and brain:objective()

    return assignment
            and ProactiveAttack:is_attack_objective(objective)
            and objective._bb_proactive_assignment_id == assignment.id
            and tostring(objective._bb_proactive_target_key) == assignment.target_key
end

local function reconcile_assignments(all_units)
    for bot_key, assignment in pairs(state.assignments) do
        local unit = all_units[bot_key] or assignment.unit
        if not assignment_is_current(assignment, unit) then
            state.assignments[bot_key] = nil
        end
    end
end

function ProactiveAttack:get_status_role(unit, combat_status)
    combat_status = combat_status or UnitOps.combat_status(unit)
    if not self:is_enabled()
            or not loud_combat_is_active(get_group_state())
            or not combat_status.can_fight
    then
        return nil
    end

    local movement = unit:movement()
    if not movement or movement:should_stay() then
        return nil
    end

    local bot_key = tostring(unit:key())
    local recall = state.recall_holds[bot_key]
    if recall_objective_is_current(recall) then
        return "proactive_guard"
    end

    local brain = unit:brain()
    local logic_data = brain and brain._logic_data
    local logic_name = logic_data and logic_data.name
    local base = unit:base()
    local keeper_active = base
            and (base.kpr_is_keeper
            or type(base.kpr_mode) == "number" and base.kpr_mode > 1)

    if movement:carrying_bag()
            or keeper_active
            or not brain
            or not logic_data
            or logic_name == "disabled"
            or logic_name == "inactive"
            or logic_name == "surrender"
    then
        return "proactive_guard"
    end

    local assignment = state.assignments[bot_key]
    if assignment_is_current(assignment, unit) then
        return "proactive_attack"
    end

    if state.guard_key == bot_key then
        return "proactive_guard"
    end

    if not objective_allows_attack(brain:objective()) then
        return "proactive_guard"
    end

    return "proactive_attack"
end

function ProactiveAttack:_update(group_state, t)
    local players, team_distressed = get_live_players(group_state)
    local suspend_recall_release = #players == 0 or team_distressed
    self:_update_recall_holds(group_state, t, suspend_recall_release)

    if suspend_recall_release then
        clear_table(state.observations)
        self:release_all(group_state, true)
        return true
    end

    local all_units, eligible, eligible_by_key = collect_bots(group_state, players)
    reconcile_assignments(all_units)

    for bot_key, unit in pairs(all_units) do
        local objective = unit:brain():objective()
        local assignment = state.assignments[bot_key]
        local assignment_matches = assignment_is_current(assignment, unit)

        if self:is_attack_objective(objective)
                and (not eligible_by_key[bot_key] or not assignment_matches)
        then
            self:_release_bot(unit, group_state, true)
        elseif assignment and not eligible_by_key[bot_key] then
            state.assignments[bot_key] = nil
        end
    end

    local recalled_guard = get_active_recalled_guard(all_units)
    if #eligible == 0 then
        clear_table(state.observations)
        if not recalled_guard then
            state.guard_key = nil
        end

        return true
    end

    local guard
    if not recalled_guard then
        guard = select_guard(eligible, eligible_by_key)
    end

    if guard then
        self:_release_bot(guard.unit, group_state, true)
    end

    local attackers = {}
    for _, bot in ipairs(eligible) do
        if not guard or bot.key ~= guard.key then
            table.insert(attackers, bot)
        end
    end

    if #attackers == 0 then
        return true
    end

    local available_bot_count = #eligible + (recalled_guard and 1 or 0)
    local max_target_distance = available_bot_count == 1
            and CONSTANTS.PROACTIVE_SOLO_TARGET_DISTANCE
            or CONSTANTS.PROACTIVE_MAX_TARGET_DISTANCE
    local targets, targets_by_key = collect_known_targets(
            group_state,
            players,
            max_target_distance,
            t
    )
    local desired_by_bot = build_attack_plan(attackers, targets, targets_by_key, t)

    for _, bot in ipairs(attackers) do
        local target_key = desired_by_bot[bot.key]
        local target = target_key and targets_by_key[tostring(target_key)]

        if target then
            local assigned = self:_assign_target(bot, target, t)
            local assignment = state.assignments[bot.key]
            if not assigned and assignment and not targets_by_key[assignment.target_key] then
                self:_release_bot(bot.unit, group_state, true)
            end
        else
            self:_release_bot(bot.unit, group_state, true)
        end
    end

    return true
end

function ProactiveAttack:update(group_state, force)
    if not Network:is_server() then
        return false
    end

    group_state = group_state or get_group_state()
    if not group_state then
        return false
    end

    if not self:is_enabled() then
        clear_table(state.observations)
        clear_table(state.nav_cache)
        clear_table(state.retry_until)
        if next(state.recall_holds) then
            self:_clear_all_recall_holds()
        end
        if next(state.assignments) then
            self:release_all(group_state, true)
        end
        return false
    end

    local t = game_time()
    if not force and t < state.next_update_t then
        return true
    end
    state.next_update_t = t + CONSTANTS.PROACTIVE_UPDATE_INTERVAL

    cleanup_retry_cooldowns(t)

    if not loud_combat_is_active(group_state) then
        clear_table(state.observations)
        clear_table(state.nav_cache)
        self:_update_recall_holds(group_state, t, true)
        self:release_all(group_state, true)
        return true
    end

    return self:_update(group_state, t)
end

function ProactiveAttack:apply_setting(group_state)
    state.next_update_t = 0

    if not self:is_enabled() then
        clear_table(state.retry_until)
        clear_table(state.observations)
        clear_table(state.nav_cache)
        self:_clear_all_recall_holds()
        return self:release_all(group_state, true)
    end

    return self:update(group_state, true)
end

function ProactiveAttack:reset_level_state()
    self:_clear_all_recall_holds()
    clear_table(state.assignments)
    clear_table(state.recall_holds)
    clear_table(state.retry_until)
    clear_table(state.observations)
    clear_table(state.nav_cache)
    state.guard_key = nil
    state.next_update_t = 0
    state.next_assignment_id = 0
    state.next_recall_id = 0

    return true
end
