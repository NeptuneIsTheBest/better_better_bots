local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils

local bb_log = Utils.log
local game_time = Utils.game_time

local HoldPosition = BB.HoldPosition or {}
BB.HoldPosition = HoldPosition

HoldPosition._anchors = HoldPosition._anchors or {}
HoldPosition._next_update_t = HoldPosition._next_update_t or 0

local function is_server()
    return Network:is_server()
end

local function get_unit_key(unit)
    return alive(unit) and tostring(unit:key()) or nil
end

local function get_group_state()
    local group_ai = managers and managers.groupai
    return group_ai and group_ai:state() or nil
end

local function get_unit_brain(unit)
    return alive(unit) and unit:brain() or nil
end

local function get_unit_movement(unit)
    return alive(unit) and unit:movement() or nil
end

local function get_current_objective(unit)
    local brain = get_unit_brain(unit)
    return brain and brain:objective() or nil
end

local function get_anchor_nav_seg(movement, position)
    local tracker = movement and movement.nav_tracker and movement:nav_tracker()
    local nav_seg = tracker and tracker:nav_segment()

    if not nav_seg and managers and managers.navigation then
        nav_seg = managers.navigation:get_nav_seg_from_pos(position)
    end

    return nav_seg
end

local function is_return_objective(objective, state_key)
    return objective
            and objective._bb_hold_return == true
            and (not state_key or objective._bb_hold_key == state_key)
end

local function is_hold_objective(objective)
    return is_return_objective(objective)
            or objective and objective._bb_hold_stationary == true
end

local function clear_table(value)
    for key in pairs(value or {}) do
        value[key] = nil
    end
end

function HoldPosition:is_enabled()
    return is_server() and BB:get("keepstaying", false) or false
end

function HoldPosition:get_state(unit)
    local key = get_unit_key(unit)
    return key and self._anchors[key] or nil
end

function HoldPosition:_interaction_target_needs_help(unit)
    if not alive(unit) then
        return false
    end

    local base = unit:base()
    if base and base.is_local_player then
        local damage = unit:character_damage()
        return damage
                and ((damage.need_revive and damage:need_revive())
                or (damage.arrested and damage:arrested()))
                or false
    end

    local movement = unit:movement()
    return movement
            and ((movement.need_revive and movement:need_revive())
            or (movement.current_state_name and movement:current_state_name() == "arrested"))
            or false
end

function HoldPosition:begin_long_distance_interaction(unit, other_unit, secondary)
    local state = self:get_state(unit)
    local movement = get_unit_movement(unit)

    if not state
            and self:is_enabled()
            and movement
            and movement.should_stay
            and movement:should_stay()
    then
        self:capture(unit)
        state = self:get_state(unit)
    end

    if not state then
        return false
    end

    state.long_distance_interaction_active = true
    state.preserve_release_for_rescue = not secondary
            and self:_interaction_target_needs_help(other_unit)
            or false

    return true
end

function HoldPosition:end_long_distance_interaction(unit)
    local state = self:get_state(unit)
    if state then
        state.long_distance_interaction_active = nil
        state.preserve_release_for_rescue = nil
    end
end

function HoldPosition:should_preserve_temporary_release(unit)
    local state = self:get_state(unit)
    if not self:is_enabled() or not state then
        return false
    end

    -- Engine-driven releases such as vehicle boarding and warps must win,
    -- even while the bot is executing a forced objective.
    return state.long_distance_interaction_active == true
            and state.preserve_release_for_rescue == true
end

function HoldPosition:_remember_stop_objective(state, objective)
    if objective
            and objective.type == "follow"
            and alive(objective.follow_unit)
    then
        state.follow_unit = objective.follow_unit
    end
end

function HoldPosition:capture(unit, defer_objective_update)
    if not self:is_enabled() then
        return false
    end

    local key = get_unit_key(unit)
    local movement = get_unit_movement(unit)
    local position = movement and movement.m_pos and movement:m_pos()

    if not (key and position) then
        return false
    end

    local existing = self._anchors[key]
    if existing and existing.unit == unit then
        self:_remember_stop_objective(existing, get_current_objective(unit))
        if defer_objective_update then
            existing.defer_until_t = game_time() + CONSTANTS.HOLD_POSITION_UPDATE_INTERVAL
        end
        return true
    end

    local state = {
        key = key,
        unit = unit,
        position = mvector3.copy(position),
        nav_seg = get_anchor_nav_seg(movement, position),
        returning = false,
        next_retry_t = 0,
        return_failures = 0,
        defer_until_t = defer_objective_update
                and game_time() + CONSTANTS.HOLD_POSITION_UPDATE_INTERVAL
                or nil,
    }

    self:_remember_stop_objective(state, get_current_objective(unit))
    self._anchors[key] = state

    return true
end

function HoldPosition:_cancel_hold_objective(unit, group_state)
    local brain = get_unit_brain(unit)
    local objective = brain and brain:objective()

    if not is_hold_objective(objective) then
        return false
    end

    objective.fail_clbk = nil
    objective.complete_clbk = nil
    objective.followup_objective = nil

    brain:set_objective(nil)

    group_state = group_state or get_group_state()
    if group_state then
        group_state:on_criminal_jobless(unit)
    end

    return true
end

function HoldPosition:clear(unit, cancel_return)
    local key = get_unit_key(unit)
    if not key then
        return false
    end

    self._anchors[key] = nil

    if cancel_return then
        self:_cancel_hold_objective(unit)
    end

    return true
end

function HoldPosition:clear_all(group_state, cancel_returns)
    local units = {}

    for key, state in pairs(self._anchors) do
        if state and alive(state.unit) then
            units[key] = state.unit
        end
    end

    group_state = group_state or get_group_state()
    if group_state then
        for key, unit_data in pairs(group_state:all_AI_criminals()) do
            if unit_data and alive(unit_data.unit) then
                units[tostring(key)] = unit_data.unit
            end
        end
    end

    clear_table(self._anchors)
    self._next_update_t = 0

    if cancel_returns then
        for _, unit in pairs(units) do
            self:_cancel_hold_objective(unit, group_state)
        end
    end

    return true
end

function HoldPosition:reset_level_state()
    clear_table(self._anchors)
    self._setting_active = nil
    self._next_update_t = 0

    return true
end

function HoldPosition:apply_setting(group_state)
    local enabled = self:is_enabled()

    if self._setting_active == enabled then
        return true
    end

    self._setting_active = enabled
    self._next_update_t = 0

    if not enabled then
        self:clear_all(group_state, true)
    end

    return true
end

function HoldPosition:_resolve_anchor_nav_seg(state)
    local navigation = managers and managers.navigation
    if not navigation then
        return nil
    end

    local nav_seg = state.nav_seg
    local nav_segments = navigation._nav_segments
    local nav_seg_data = nav_segments and nav_seg and nav_segments[nav_seg]

    if nav_seg_data and not nav_seg_data.disabled then
        return nav_seg
    end

    nav_seg = navigation:get_nav_seg_from_pos(state.position)
    nav_seg_data = nav_segments and nav_seg and nav_segments[nav_seg]

    if nav_seg and (not nav_segments or nav_seg_data and not nav_seg_data.disabled) then
        state.nav_seg = nav_seg
        return nav_seg
    end

    return nil
end

function HoldPosition:_make_stationary_objective(state)
    if alive(state.follow_unit) then
        return {
            called = false,
            destroy_clbk_key = false,
            scan = true,
            type = "follow",
            follow_unit = state.follow_unit,
            in_place = true,
            _bb_hold_stationary = true,
        }
    end

    return {
        is_default = true,
        scan = true,
        type = "free",
        in_place = true,
        _bb_hold_stationary = true,
    }
end

function HoldPosition:_log_return_failure(state, reason)
    local t = game_time()
    if state.last_failure_log_t and t < state.last_failure_log_t + 5 then
        return
    end

    state.last_failure_log_t = t
    bb_log(
            string.format("Hold-position return delayed for bot %s: %s", state.key, tostring(reason)),
            "WARN"
    )
end

function HoldPosition:_delay_return(state, reason)
    state.returning = false
    state.return_failures = (state.return_failures or 0) + 1
    state.next_retry_t = game_time() + CONSTANTS.HOLD_POSITION_RETRY_INTERVAL
    self:_log_return_failure(state, reason)
end

function HoldPosition:_on_return_complete(state_key, unit)
    local state = self._anchors[tostring(state_key)]
    if not state or state.unit ~= unit then
        return
    end

    state.returning = false
    state.return_failures = 0
    state.next_retry_t = 0
end

function HoldPosition:_on_return_failed(state_key, unit)
    local state = self._anchors[tostring(state_key)]
    if not state or state.unit ~= unit then
        return
    end

    local current_objective = get_current_objective(unit)
    if current_objective and not is_return_objective(current_objective, state.key) then
        state.returning = false
        state.next_retry_t = 0
        return
    end

    self:_delay_return(state, "pathing failed")
end

function HoldPosition:_make_return_objective(state)
    local nav_seg = self:_resolve_anchor_nav_seg(state)
    if not nav_seg then
        self:_delay_return(state, "anchor has no active navigation segment")
        return nil
    end

    state.returning = true
    state.next_retry_t = 0

    return {
        forced = true,
        haste = "run",
        scan = true,
        type = "free",
        nav_seg = nav_seg,
        pos = mvector3.copy(state.position),
        followup_objective = self:_make_stationary_objective(state),
        complete_clbk = callback(self, self, "_on_return_complete", state.key),
        fail_clbk = callback(self, self, "_on_return_failed", state.key),
        _bb_hold_return = true,
        _bb_hold_key = state.key,
    }
end

function HoldPosition:prepare_objective_completion(unit, objective)
    if not self:is_enabled() or not objective then
        return false
    end

    if is_return_objective(objective) then
        local return_state = self._anchors[tostring(objective._bb_hold_key)]
        if return_state and return_state.unit == unit then
            objective.followup_objective = self:_make_stationary_objective(return_state)
            return true
        end

        return false
    end

    if objective.type ~= "revive" then
        return false
    end

    local movement = get_unit_movement(unit)
    if not (movement and movement.should_stay and movement:should_stay()) then
        return false
    end

    local state = self:get_state(unit)
    if not state and not self:capture(unit) then
        return false
    end

    state = state or self:get_state(unit)
    local return_objective = state and self:_make_return_objective(state)
    if not return_objective then
        return false
    end

    objective.followup_objective = return_objective

    return true
end

function HoldPosition:_can_start_return(unit, objective)
    if objective and objective.type == "revive" then
        return false
    end

    if objective and objective.forced and not is_return_objective(objective) then
        return false
    end

    local brain = get_unit_brain(unit)
    local logic_data = brain and brain._logic_data
    local logic_name = logic_data and logic_data.name

    if not logic_data
            or logic_name == "disabled"
            or logic_name == "inactive"
            or logic_name == "surrender"
    then
        return false
    end

    local damage = unit:character_damage()
    if damage and ((damage.dead and damage:dead()) or (damage.need_revive and damage:need_revive())) then
        return false
    end

    local my_data = logic_data.internal_data
    if objective
            and objective.action_duration
            and my_data
            and my_data.performing_act_objective
    then
        return false
    end

    return true
end

function HoldPosition:_ensure_stationary_objective(unit, state, objective)
    local replace_objective = not objective
            or objective.type == "follow"
            and (not objective.in_place or not alive(objective.follow_unit))
            and not objective.forced

    if not replace_objective then
        return objective
    end

    local brain = get_unit_brain(unit)
    if not brain then
        return objective
    end

    local stationary_objective = self:_make_stationary_objective(state)
    brain:set_objective(stationary_objective)

    return stationary_objective
end

function HoldPosition:_update_unit(unit, t)
    local movement = get_unit_movement(unit)
    if not (movement and movement.should_stay and movement:should_stay()) then
        self:clear(unit, false)
        return
    end

    local state = self:get_state(unit)
    if not state then
        if not self:capture(unit) then
            return
        end
        state = self:get_state(unit)
    end

    if state.defer_until_t then
        if t < state.defer_until_t then
            return
        end

        state.defer_until_t = nil
    end

    local objective = get_current_objective(unit)
    self:_remember_stop_objective(state, objective)

    if state.returning then
        if is_return_objective(objective, state.key) then
            return
        end

        state.returning = false
    end

    if t < (state.next_retry_t or 0) then
        return
    end

    local position = movement.m_pos and movement:m_pos()
    if not position then
        return
    end

    local return_distance = CONSTANTS.HOLD_POSITION_RETURN_DISTANCE
    if mvector3.distance_sq(position, state.position) <= return_distance * return_distance then
        if self:_can_start_return(unit, objective) then
            self:_ensure_stationary_objective(unit, state, objective)
        end
        return
    end

    if not self:_can_start_return(unit, objective) then
        return
    end

    local return_objective = self:_make_return_objective(state)
    if not return_objective then
        return
    end

    local brain = get_unit_brain(unit)
    brain:set_objective(return_objective)
end

function HoldPosition:update_all(group_state, force)
    if not self:is_enabled() then
        return false
    end

    group_state = group_state or get_group_state()
    if not group_state then
        return false
    end

    local t = game_time()
    if not force and t < self._next_update_t then
        return true
    end

    self._next_update_t = t + CONSTANTS.HOLD_POSITION_UPDATE_INTERVAL

    local seen = {}
    for key, unit_data in pairs(group_state:all_AI_criminals()) do
        local unit = unit_data and unit_data.unit
        if alive(unit) then
            local state_key = tostring(key)
            seen[state_key] = true
            self:_update_unit(unit, t)
        end
    end

    for key in pairs(self._anchors) do
        if not seen[key] then
            self._anchors[key] = nil
        end
    end

    return true
end

function HoldPosition:is_stationary(unit)
    if not self:is_enabled() then
        return false
    end

    local movement = get_unit_movement(unit)
    if not (movement and movement.should_stay and movement:should_stay()) then
        return false
    end

    local state = self:get_state(unit)
    if not state and not self:capture(unit) then
        return false
    end

    local objective = get_current_objective(unit)
    return not is_return_objective(objective)
            and not (objective and (objective.type == "revive" or objective.forced))
end

function HoldPosition:prepare_reload_pose(data)
    local unit = data and data.unit
    if not self:is_stationary(unit) then
        return false
    end

    local anim_data = unit:anim_data()
    if anim_data and anim_data.crouch then
        return true
    end

    local allowed_poses = data.char_tweak and data.char_tweak.allowed_poses
    if allowed_poses and not allowed_poses.crouch then
        return false
    end

    return CopLogicAttack._chk_request_action_crouch(data) and true or false
end

function HoldPosition:update_combat_pose(data)
    local unit = data and data.unit
    local my_data = data and data.internal_data

    if not my_data
            or data.name ~= "assault"
            or not self:is_stationary(unit)
            or my_data.turning
            or my_data.moving_to_cover
            or my_data.walking_to_cover_shoot_pos
            or my_data._turning_to_intimidate
    then
        return false
    end

    local anim_data = unit:anim_data()
    if anim_data and anim_data.reload then
        self:prepare_reload_pose(data)
    end

    local attention = data.attention_obj
    local react_aim = AIAttentionObject.REACT_AIM
    if not (attention and attention.reaction >= react_aim) then
        return false
    end

    my_data.want_to_take_cover = CopLogicAttack._chk_wants_to_take_cover(data, my_data)

    return CopLogicAttack._upd_pose(data, my_data) and true or false
end

return HoldPosition
