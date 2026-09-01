local BB = _G.BB

local Utils = BB.Utils

local game_time = Utils.game_time

local CoverTactics = BB.CoverTactics or {}
BB.CoverTactics = CoverTactics

local DEFAULT_UPDATE_INTERVAL = 2

local function _is_live_player(unit)
    if not alive(unit) then
        return false
    end

    local group_ai = managers.groupai
    local group_state = group_ai and group_ai:state()
    local players = group_state and group_state:all_player_criminals()
    local record = players and players[unit:key()]

    return record and record.status ~= "dead" or false
end

local function _is_ordinary_player_follow(objective)
    return objective
            and objective.type == "follow"
            and objective.attitude == nil
            and not objective.forced
            and _is_live_player(objective.follow_unit)
end

local function _objective_blocks_movement(objective)
    return objective
            and (objective.forced
            or objective.type == "revive"
            or objective.type == "act"
            or objective.type == "throw_bag")
end

local function _is_combat_attention(attention)
    return attention
            and type(attention.reaction) == "number"
            and attention.reaction >= AIAttentionObject.REACT_COMBAT
            and alive(attention.unit)
end

local function _is_current_assault(data, my_data)
    return data
            and data.name == "assault"
            and my_data
            and data.internal_data == my_data
end

function CoverTactics:on_enter(data)
    local my_data = data and data.internal_data
    if not _is_current_assault(data, my_data) then
        return false
    end

    if _is_ordinary_player_follow(data.objective) then
        my_data.attitude = "engage"
    end

    if my_data.attitude ~= "engage" then
        return false
    end

    my_data.cover_test_step = 1
    my_data._bb_next_cover_tactics_t = data.t or game_time()

    return true
end

function CoverTactics:before_action_complete(data, action)
    local my_data = data and data.internal_data
    if not _is_current_assault(data, my_data)
            or my_data._bb_next_cover_tactics_t == nil
            or not action
            or action:type() ~= "walk"
            or my_data.surprised
            or my_data.moving_to_cover
            or not my_data.walking_to_cover_shoot_pos
    then
        return false
    end

    -- TeamAILogicAssault clears this walk marker without setting the state
    -- consumed by CopLogicAttack's native peek/return flow.
    my_data.at_cover_shoot_pos = true

    return true
end

function CoverTactics:update(data)
    local my_data = data and data.internal_data
    if not _is_current_assault(data, my_data)
            or my_data._bb_next_cover_tactics_t == nil
            or my_data.attitude ~= "engage"
            or not _is_combat_attention(data.attention_obj)
            or _objective_blocks_movement(data.objective)
            or my_data.surprised
            or my_data._turning_to_intimidate
    then
        return false
    end

    local movement = alive(data.unit) and data.unit:movement()
    if not movement
            or movement:should_stay()
            or movement:carrying_bag()
            or movement:chk_action_forbidden("walk")
    then
        return false
    end

    local t = data.t or game_time()
    if t < my_data._bb_next_cover_tactics_t then
        return false
    end

    local update_combat_movement = CopLogicAttack
            and CopLogicAttack._upd_combat_movement
    if type(update_combat_movement) ~= "function" then
        return false
    end

    local logic = data.logic
    local interval = logic and logic._COVER_CHK_INTERVAL
    if type(interval) ~= "number" or interval <= 0 then
        interval = DEFAULT_UPDATE_INTERVAL
    end

    my_data._bb_next_cover_tactics_t = t + interval
    update_combat_movement(data)

    return true
end

return CoverTactics
