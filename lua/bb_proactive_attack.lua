local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local UnitOps = BB.UnitOps
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

local function get_target_position(attention_data)
    if attention_data.verified then
        return attention_data.m_head_pos
                or attention_data.verified_pos
                or attention_data.m_pos
    end

    return attention_data.last_verified_pos
            or attention_data.verified_pos
            or attention_data.m_head_pos
            or attention_data.m_pos
end

local function target_has_navigation(unit)
    local movement = alive(unit) and unit:movement()
    local tracker = movement and movement:nav_tracker()
    local nav_seg = tracker and tracker:nav_segment()
    if not nav_seg then
        return false
    end

    local nav_seg_data = managers.navigation._nav_segments[nav_seg]

    return nav_seg_data ~= nil and not nav_seg_data.disabled
end

local function make_target_observation(observer, attention_data, t)
    if not (attention_data and attention_data.identified) then
        return nil
    end

    local target_unit = attention_data.unit
    if not (alive(target_unit)
            and not is_unit_dead(target_unit)
            and UnitOps.are_foes(observer, target_unit)
            and not UnitOps.is_surrendering(target_unit)
            and target_has_navigation(target_unit))
    then
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
    elseif attention_data.verified_t
            and t - attention_data.verified_t <= CONSTANTS.PROACTIVE_TARGET_MEMORY
    then
        last_seen_t = attention_data.verified_t
    end

    if not last_seen_t then
        return nil
    end

    local target_pos = get_target_position(attention_data)
    if not target_pos then
        return nil
    end

    return {
        key = tostring(attention_data.u_key or target_unit:key()),
        unit = target_unit,
        position = target_pos,
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
                    if not target then
                        target = observation
                        targets_by_key[observation.key] = target
                    else
                        local fresher = observation_is_fresher(observation, target)
                        if fresher then
                            target.unit = observation.unit
                            target.position = observation.position
                            target.attention_data = observation.attention_data
                            target.last_seen_t = observation.last_seen_t
                            target.verified = observation.verified
                        end
                    end
                end
            end
        end
    end

    local targets = {}
    for target_key, target in pairs(targets_by_key) do
        target.player_distance = minimum_player_distance(target.position, players)
        if target.player_distance <= max_distance then
            local flags = EnemyClassifier.classify(target.unit, target.attention_data)
            if flags.tasing or flags.spooc_attack then
                target.urgency = 3
                target.focus = "urgent"
            elseif flags.special or flags.dozer or flags.turret then
                target.urgency = 2
                if flags.dozer or flags.turret then
                    target.focus = "durable"
                end
            else
                target.urgency = 1
            end

            targets_by_key[target_key] = target
            table.insert(targets, target)
        else
            targets_by_key[target_key] = nil
        end
    end

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

    -- A recalled current guard still fills the guard slot while returning.
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
end

local function target_retry_is_active(bot_key, target_key, t)
    local bot_cooldowns = state.retry_until[bot_key]
    return bot_cooldowns and t < (bot_cooldowns[target_key] or 0) or false
end

local function select_guard(eligible, eligible_by_key)
    if #eligible < 2 then
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

local function build_attack_plan(attackers, targets, t)
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

        local locked_target_key = previous
                and t < (previous.lock_until or 0)
                and previous.target_key

        for _, target in ipairs(targets) do
            local target_allowed_by_lock = not locked_target_key
                    or target.key == locked_target_key
                    or target.urgency >= 3

            if target_allowed_by_lock
                    and not target_retry_is_active(bot.key, target.key, t)
            then
                local distance = mvector3.distance(bot.position, target.position)
                local continuing = previous and previous.target_key == target.key

                if continuing or distance > CONSTANTS.PROACTIVE_MIN_CHASE_DISTANCE then
                    local score = ThreatAssessment.calculate_threat_value(
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

function ProactiveAttack:_on_objective_failed(bot_key, assignment_id, unit)
    bot_key = tostring(bot_key)

    local assignment = state.assignments[bot_key]
    if not assignment or assignment.id ~= assignment_id then
        return
    end

    local brain = alive(unit) and unit:brain()
    local current_objective = brain and brain:objective()
    local failed_current_objective = self:is_attack_objective(current_objective)
            and current_objective._bb_proactive_assignment_id == assignment_id

    if failed_current_objective then
        prepare_objective_for_removal(current_objective)
    end

    state.assignments[bot_key] = nil
    state.next_update_t = 0

    if failed_current_objective then
        state.retry_until[bot_key] = state.retry_until[bot_key] or {}
        state.retry_until[bot_key][assignment.target_key] = game_time()
                + CONSTANTS.PROACTIVE_RETRY_COOLDOWN
    end
end

function ProactiveAttack:_assign_target(bot, target)
    local current_assignment = state.assignments[bot.key]
    local current_objective = bot.brain:objective()

    if self:is_attack_objective(current_objective) then
        prepare_objective_for_removal(current_objective)
    end

    local t = game_time()
    local target_distance = bot.position
            and target.position
            and mvector3.distance(bot.position, target.position)
            or math.huge
    local needs_repath = current_assignment
            and self:is_attack_objective(current_objective)
            and current_objective.in_place
            and target_distance > CONSTANTS.PROACTIVE_REPATH_DISTANCE
            and t >= (current_assignment.next_repath_t or 0)

    if current_assignment
            and current_assignment.target_key == target.key
            and self:is_attack_objective(current_objective)
            and current_objective._bb_proactive_assignment_id == current_assignment.id
            and current_objective.follow_unit == target.unit
            and not needs_repath
    then
        current_assignment.last_seen_t = target.last_seen_t
        return true
    end

    if self:is_attack_objective(current_objective) then
        current_objective.fail_clbk = nil
        current_objective.complete_clbk = nil
        current_objective.followup_objective = nil
    end

    state.next_assignment_id = state.next_assignment_id + 1
    local assignment_id = state.next_assignment_id
    local manual_destroy_clbk_key
    local objective = {
        is_default = true,
        called = false,
        destroy_clbk_key = false,
        scan = true,
        type = "follow",
        follow_unit = target.unit,
        attitude = "engage",
        stance = "hos",
        haste = "run",
        _bb_proactive_attack = true,
        _bb_proactive_assignment_id = assignment_id,
        _bb_proactive_target_key = target.key,
        fail_clbk = callback(
                self,
                self,
                "_on_objective_failed",
                bot.key,
                assignment_id
        ),
    }

    if not target_damage_supports_objective_listeners(target.unit) then
        manual_destroy_clbk_key = string.format(
                "BB_ProactiveAttack_objective_%s_%d",
                bot.key,
                assignment_id
        )
        objective.destroy_clbk_key = manual_destroy_clbk_key
    end

    state.assignments[bot.key] = {
        id = assignment_id,
        unit = bot.unit,
        target_key = target.key,
        target_unit = target.unit,
        last_seen_t = target.last_seen_t,
        lock_until = t + CONSTANTS.PROACTIVE_TARGET_LOCK,
        next_repath_t = t + CONSTANTS.PROACTIVE_REPATH_INTERVAL,
    }

    bot.brain:set_objective(objective)

    if manual_destroy_clbk_key
            and bot.brain:objective() == objective
            and alive(target.unit)
    then
        target.unit:base():add_destroy_listener(
                manual_destroy_clbk_key,
                callback(bot.brain, bot.brain, "on_objective_unit_destroyed")
        )
    end

    return true
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
            self:_release_bot(unit, group_state, eligible_by_key[bot_key] ~= nil)
        elseif assignment and not eligible_by_key[bot_key] then
            state.assignments[bot_key] = nil
        end
    end

    local recalled_guard = get_active_recalled_guard(all_units)
    if #eligible == 0 then
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
    local desired_by_bot = build_attack_plan(attackers, targets, t)

    for _, bot in ipairs(attackers) do
        local target_key = desired_by_bot[bot.key]
        local target = target_key and targets_by_key[tostring(target_key)]

        if target then
            self:_assign_target(bot, target)
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
    state.guard_key = nil
    state.next_update_t = 0
    state.next_assignment_id = 0
    state.next_recall_id = 0

    return true
end
