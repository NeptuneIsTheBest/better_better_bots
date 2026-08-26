local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local EnemyClassifier = BB.EnemyClassifier
local ThreatAssessment = BB.ThreatAssessment
local UnitOps = BB.UnitOps
local Utils = BB.Utils

local are_units_foes = UnitOps.are_foes
local game_time = Utils.game_time
local request_act = UnitOps.request_act

local MarkingSystem = {}

local MARK_CONTOUR_IDS = {
    "mark_enemy",
    "mark_enemy_damage_bonus",
    "mark_enemy_damage_bonus_distance",
    "mark_unit_dangerous",
    "mark_unit_dangerous_damage_bonus",
    "mark_unit_dangerous_damage_bonus_distance",
}

local state = BB.marking_state or {
    next_scan_t = 0,
    urgent_actions = {},
}
BB.marking_state = state

state.next_scan_t = state.next_scan_t or 0
state.urgent_actions = state.urgent_actions or {}

local function clear_table(value)
    for key in pairs(value) do
        value[key] = nil
    end
end

local function get_char_tweak(attention_data, unit)
    if attention_data.char_tweak then
        return attention_data.char_tweak
    end

    local base = unit:base()
    return base and base.char_tweak and base:char_tweak() or nil
end

local function get_target_pos(attention_data, unit)
    if attention_data.m_head_pos then
        return attention_data.m_head_pos
    elseif attention_data.verified_pos then
        return attention_data.verified_pos
    elseif attention_data.last_verified_pos then
        return attention_data.last_verified_pos
    end

    local movement = unit:movement()
    return movement and movement:m_head_pos() or nil
end

local function get_target_distance(attention_data, observer_unit, target_pos)
    local distance = attention_data.verified_dis or attention_data.dis
    if type(distance) == "number" then
        return distance
    end

    local movement = observer_unit:movement()
    local observer_pos = movement and movement:m_head_pos()
    return observer_pos and target_pos and mvector3.distance(observer_pos, target_pos) or nil
end

local function get_observer_context(unit_data)
    local unit = unit_data and unit_data.unit
    if not alive(unit) then
        return nil
    end

    local brain = unit:brain()
    local data = brain and brain._logic_data
    if not (data and data.name == "assault" and data.detected_attention_objects) then
        return nil
    end

    if not UnitOps.combat_status(unit).can_fight then
        return nil
    end

    return unit, data
end

local function get_context_from_logic_data(data)
    local unit = data and data.unit
    if not (alive(unit) and data.name == "assault" and data.detected_attention_objects) then
        return nil
    end

    if not UnitOps.combat_status(unit).can_fight then
        return nil
    end

    return unit, data
end

local function get_urgent_token(unit)
    local brain = alive(unit) and unit:brain()
    local logic_data = brain and brain._logic_data
    local internal_data = logic_data and logic_data.internal_data
    return internal_data and (internal_data.spooc_attack or internal_data.tasing) or nil
end

function MarkingSystem.has_mark_contour(contour)
    if not contour then
        return false
    end

    for _, contour_id in ipairs(MARK_CONTOUR_IDS) do
        if contour:has_id(contour_id) then
            return true
        end
    end

    return false
end

local function make_candidate(observer_unit, data, attention_data)
    if not (attention_data.identified and (attention_data.verified or attention_data.nearly_visible)) then
        return nil
    end

    local target_unit = attention_data.unit
    if not (alive(target_unit) and are_units_foes(observer_unit, target_unit)) then
        return nil
    end

    local reaction = attention_data.reaction
            or attention_data.settings and attention_data.settings.reaction
            or AIAttentionObject.REACT_IDLE
    if reaction < AIAttentionObject.REACT_COMBAT then
        return nil
    end

    local flags = EnemyClassifier.classify(target_unit, attention_data)
    local char_tweak = get_char_tweak(attention_data, target_unit)
    local callout = flags.turret and "f44" or char_tweak and char_tweak.priority_shout
    if not callout or callout == "" then
        return nil
    end

    local target_pos = get_target_pos(attention_data, target_unit)
    local distance = get_target_distance(attention_data, observer_unit, target_pos)
    if not distance or distance > CONSTANTS.MARK_DISTANCE then
        return nil
    end

    local max_callout_distance = char_tweak and char_tweak.priority_shout_max_dis
    if max_callout_distance and distance >= max_callout_distance then
        return nil
    end

    local contour = target_unit:contour()
    if not contour then
        return nil
    end

    local marked = MarkingSystem.has_mark_contour(contour)
    local score = 0
    if not marked then
        score = ThreatAssessment.calculate_threat_value(
                observer_unit,
                attention_data,
                data,
                distance,
                target_pos
        )
    end

    return {
        callout = callout,
        contour = contour,
        data = data,
        distance = distance,
        marked = marked,
        observer_key = tostring(observer_unit:key()),
        observer_unit = observer_unit,
        score = type(score) == "number" and score or 0,
        target_key = tostring(target_unit:key()),
        target_unit = target_unit,
        urgent_token = flags.spooc_attack or flags.tasing or nil,
        verified = attention_data.verified == true,
    }
end

local function observation_is_better(candidate, current)
    if not current then
        return true
    elseif candidate.score ~= current.score then
        return candidate.score > current.score
    elseif candidate.verified ~= current.verified then
        return candidate.verified
    elseif candidate.distance ~= current.distance then
        return candidate.distance < current.distance
    end

    return candidate.observer_key < current.observer_key
end

local function target_is_better(candidate, current)
    if not current then
        return true
    end

    local candidate_urgent = candidate.urgent_token and 1 or 0
    local current_urgent = current.urgent_token and 1 or 0
    if candidate_urgent ~= current_urgent then
        return candidate_urgent > current_urgent
    elseif candidate.score ~= current.score then
        return candidate.score > current.score
    elseif candidate.verified ~= current.verified then
        return candidate.verified
    elseif candidate.distance ~= current.distance then
        return candidate.distance < current.distance
    end

    return candidate.target_key < current.target_key
end

local function add_observation(aggregates, candidate)
    local aggregate = aggregates[candidate.target_key]
    if not aggregate then
        aggregate = {
            best = candidate,
            observers = {},
        }
        aggregates[candidate.target_key] = aggregate
    elseif observation_is_better(candidate, aggregate.best) then
        aggregate.best = candidate
    end

    table.insert(aggregate.observers, candidate)
    return aggregate
end

local function get_all_ai_criminals()
    local group_state = managers.groupai and managers.groupai:state()
    return group_state and group_state:all_AI_criminals() or nil
end

local function collect_normal_candidates()
    local ai_criminals = get_all_ai_criminals()
    if not ai_criminals then
        return nil
    end

    local aggregates = {}
    for _, unit_data in pairs(ai_criminals) do
        local observer_unit, data = get_observer_context(unit_data)
        if observer_unit then
            for _, attention_data in pairs(data.detected_attention_objects) do
                local candidate = make_candidate(observer_unit, data, attention_data)
                if candidate and not candidate.marked then
                    add_observation(aggregates, candidate)
                end
            end
        end
    end

    local best_aggregate
    for _, aggregate in pairs(aggregates) do
        if target_is_better(aggregate.best, best_aggregate and best_aggregate.best) then
            best_aggregate = aggregate
        end
    end

    return best_aggregate
end

local function collect_target_observers(target_key)
    local ai_criminals = get_all_ai_criminals()
    local aggregate = {
        observers = {},
    }
    if not ai_criminals then
        return aggregate
    end

    for _, unit_data in pairs(ai_criminals) do
        local observer_unit, data = get_observer_context(unit_data)
        if observer_unit then
            for _, attention_data in pairs(data.detected_attention_objects) do
                local target_unit = attention_data.unit
                if alive(target_unit) and tostring(target_unit:key()) == target_key then
                    local candidate = make_candidate(observer_unit, data, attention_data)
                    if candidate and not candidate.marked then
                        if observation_is_better(candidate, aggregate.best) then
                            aggregate.best = candidate
                        end
                        table.insert(aggregate.observers, candidate)
                    end
                end
            end
        end
    end

    return aggregate
end

local function speaker_is_better(candidate, current)
    if not current then
        return true
    elseif candidate.verified ~= current.verified then
        return candidate.verified
    elseif candidate.distance ~= current.distance then
        return candidate.distance < current.distance
    end

    return candidate.observer_key < current.observer_key
end

local function can_speak(candidate, t)
    local data = candidate.data
    local internal_data = data.internal_data
    if internal_data and internal_data.acting then
        return false
    end

    local unit = candidate.observer_unit
    local sound = unit:sound()
    if not (sound and sound.say) or sound:speaking() then
        return false
    end

    local brain = unit:brain()
    if not brain then
        return false
    end

    local sound_tweak = tweak_data.sound and tweak_data.sound.criminal_sound
    local cooldown = sound_tweak and sound_tweak.ai_callout_cooldown
            or CONSTANTS.MARK_BOT_CALLOUT_COOLDOWN
    return not brain._last_mark_shout or t - brain._last_mark_shout >= cooldown
end

local function play_callout(aggregate, t)
    if state.last_callout_t and t - state.last_callout_t < CONSTANTS.MARK_CALLOUT_COOLDOWN then
        return false
    end

    local speaker
    for _, candidate in ipairs(aggregate.observers) do
        if can_speak(candidate, t) and speaker_is_better(candidate, speaker) then
            speaker = candidate
        end
    end

    if not speaker then
        return false
    end

    local unit = speaker.observer_unit
    local sound_event = unit:sound():say(tostring(speaker.callout) .. "x_any", true, true)
    if not sound_event then
        return false
    end

    unit:brain()._last_mark_shout = t
    state.last_callout_t = t

    local anim_data = unit:anim_data()
    local movement = unit:movement()
    local carrying = movement and movement:carrying_bag()
    if not (anim_data and anim_data.reload) and not carrying then
        request_act(unit, "arrest", speaker.data)
    end

    return true
end

local function apply_mark(aggregate, t)
    local candidate = aggregate and aggregate.best
    if not (candidate and alive(candidate.target_unit)) then
        return false
    end

    local contour = candidate.target_unit:contour()
    if not contour or MarkingSystem.has_mark_contour(contour) then
        return false
    end

    local base = candidate.target_unit:base()
    local enemy_type = base and base.get_type and base:get_type()
    local contour_id = managers.player:get_contour_for_marked_enemy(enemy_type)
    if not contour_id or contour_id == "" then
        return false
    end

    local duration_multiplier = managers.player:upgrade_value("player", "mark_enemy_time_multiplier", 1)
    if not contour:add(contour_id, true, duration_multiplier) then
        return false
    end

    state.last_mark_t = t
    play_callout(aggregate, t)
    return true
end

local function remember_urgent_action(candidate)
    state.urgent_actions[candidate.target_key] = {
        token = candidate.urgent_token,
        unit = candidate.target_unit,
    }
end

local function process_urgent_action(data, t)
    local observer_unit = get_context_from_logic_data(data)
    if not observer_unit then
        return false
    end

    local best_candidate
    for _, attention_data in pairs(data.detected_attention_objects) do
        local target_unit = attention_data.unit
        if alive(target_unit) then
            local target_key = tostring(target_unit:key())
            local urgent_token = get_urgent_token(target_unit)
            if not urgent_token then
                state.urgent_actions[target_key] = nil
            else
                local candidate = make_candidate(observer_unit, data, attention_data)
                local previous = state.urgent_actions[target_key]
                if candidate and (not previous or previous.token ~= urgent_token) then
                    candidate.urgent_token = urgent_token
                    if candidate.marked then
                        remember_urgent_action(candidate)
                    elseif target_is_better(candidate, best_candidate) then
                        best_candidate = candidate
                    end
                end
            end
        end
    end

    if not best_candidate then
        return false
    end

    local aggregate = collect_target_observers(best_candidate.target_key)
    if not aggregate.best then
        aggregate.best = best_candidate
        table.insert(aggregate.observers, best_candidate)
    end

    local marked = apply_mark(aggregate, t)
    if marked or MarkingSystem.has_mark_contour(best_candidate.contour) then
        remember_urgent_action(best_candidate)
    end

    return marked
end

local function cleanup_urgent_actions()
    for target_key, action in pairs(state.urgent_actions) do
        if not (action and alive(action.unit)) then
            state.urgent_actions[target_key] = nil
        end
    end
end

function MarkingSystem.on_detection_updated(data)
    local group_state = managers.groupai and managers.groupai:state()
    if not group_state or group_state:whisper_mode() then
        clear_table(state.urgent_actions)
        return false
    end

    local t = game_time()
    local urgent_marked = process_urgent_action(data, t)

    if t < state.next_scan_t then
        return urgent_marked
    end

    state.next_scan_t = t + CONSTANTS.MARK_SCAN_INTERVAL
    cleanup_urgent_actions()

    if state.last_mark_t and t - state.last_mark_t < CONSTANTS.MARK_COOLDOWN then
        return urgent_marked
    end

    local aggregate = collect_normal_candidates()
    return aggregate and apply_mark(aggregate, t) or urgent_marked
end

function MarkingSystem.reset_level_state()
    state.next_scan_t = 0
    state.last_mark_t = nil
    state.last_callout_t = nil
    clear_table(state.urgent_actions)
    return true
end

BB.MarkingSystem = MarkingSystem
