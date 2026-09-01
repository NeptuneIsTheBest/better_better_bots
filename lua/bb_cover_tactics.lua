local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local UnitOps = BB.UnitOps
local Utils = BB.Utils

local game_time = Utils.game_time

local CoverTactics = BB.CoverTactics or {}
BB.CoverTactics = CoverTactics

local tmp_target_pos = Vector3()
local tmp_fire_from = Vector3()
local tmp_candidate_from = Vector3()
local fire_lane_slotmask

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

local function _is_player_follow(objective)
    return objective
            and objective.type == "follow"
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

local function _new_state(data, t)
    local parity_key = type(data.pos_rsrv_id) == "number"
            and data.pos_rsrv_id
            or data.key

    return {
        phase = "clear",
        lane = "-",
        target_key = nil,
        blocked_since_t = nil,
        next_lane_check_t = t,
        next_reposition_t = t,
        peek_attempted = nil,
        force_cover = false,
        reposition_sign = type(parity_key) == "number"
                and (parity_key % 2 == 0 and 1 or -1)
                or 1,
        ignore_units = { data.unit },
    }
end

local function _cover_matches(a, b)
    return a ~= nil
            and b ~= nil
            and (a == b
            or type(a) == "table"
            and type(b) == "table"
            and a[1] == b[1])
end

local function _clear_transfer(state)
    state.force_cover = false
    state.expected_cover = nil
    state.fallback_cover = nil
    state.left_fallback = nil
    state.path_deadline_t = nil
end

local function _clear_lane_tracking(state, t)
    state.blocked_since_t = nil
    state.peek_attempted = nil
    state.next_reposition_t = t
    state.lane = "clear"

    if state.phase == "blocked" or state.phase == "standing" then
        state.phase = "clear"
    end
end

local function _get_target_position(attention, t, out)
    if not _is_combat_attention(attention) then
        return nil, false
    end

    local verified = attention.verified == true
    if verified then
        local damage = attention.unit:character_damage()
        if damage and type(damage.shoot_pos_mid) == "function" then
            damage:shoot_pos_mid(out)
            return out, true
        end

        local verified_pos = attention.m_head_pos
                or attention.verified_pos
                or attention.last_verified_pos
        if verified_pos then
            mvector3.set(out, verified_pos)
            return out, true
        end

        return nil, true
    end

    local verified_t = attention.verified_t
    if type(verified_t) ~= "number"
            or t - verified_t > CONSTANTS.COVER_TACTICS_TARGET_MEMORY
    then
        return nil, false
    end

    local remembered_pos = attention.last_verified_pos or attention.verified_pos
    if not remembered_pos then
        return nil, false
    end

    mvector3.set(out, remembered_pos)
    return out, false
end

local function _get_fire_lane_slotmask()
    if not fire_lane_slotmask and managers.slot then
        fire_lane_slotmask = managers.slot:get_mask(
                "bullet_impact_targets_no_criminals"
        )
    end

    return fire_lane_slotmask
end

local function _fire_lane_is_clear(data, state, attention, from_pos, target_pos)
    local slotmask = _get_fire_lane_slotmask()
    if not (slotmask and from_pos and target_pos) then
        return false
    end

    local ray = World:raycast(
            "ray",
            from_pos,
            target_pos,
            "slot_mask",
            slotmask,
            "ignore_unit",
            state.ignore_units
    )
    if not ray then
        return true
    end

    local hit_unit = ray.unit
    if hit_unit == attention.unit then
        return true
    end

    return alive(hit_unit) and UnitOps.are_foes(data.unit, hit_unit) or false
end

local function _movement_is_hard_blocked(data, my_data, movement)
    return _objective_blocks_movement(data.objective)
            or movement:should_stay()
            or movement:carrying_bag()
            or my_data.surprised
            or my_data._turning_to_intimidate
end

local function _can_start_movement(data, my_data, state, movement)
    if _movement_is_hard_blocked(data, my_data, movement)
            or movement:chk_action_forbidden("walk")
            or my_data.turning
            or my_data.has_old_action
            or my_data.acting
            or my_data.advancing
            or my_data.moving_to_cover
            or my_data.walking_to_cover_shoot_pos
            or my_data.charge_path_search_id
    then
        return false
    end

    return true
end

local function _can_force_cover(data, my_data, movement)
    return not _movement_is_hard_blocked(data, my_data, movement)
            and not movement:chk_action_forbidden("walk")
            and not my_data.advancing
            and not my_data.moving_to_cover
            and not my_data.walking_to_cover_shoot_pos
end

local function _follow_anchor(data)
    local objective = data.objective
    local follow_unit = objective and objective.follow_unit
    if objective
            and objective._bb_rescue_guard
            and alive(follow_unit)
    then
        local movement = follow_unit:movement()
        if movement then
            return movement:m_newest_pos(),
                    movement:nav_tracker(),
                    CONSTANTS.RESCUE_GUARD_POSITION_RANGE,
                    true
        end
    elseif _is_player_follow(objective) then
        local movement = follow_unit:movement()
        if movement then
            return movement:m_newest_pos(),
                    movement:nav_tracker(),
                    CONSTANTS.COVER_TACTICS_FOLLOW_MAX_DISTANCE,
                    true
        end
    end

    local movement = data.unit:movement()
    return data.m_pos,
            movement and movement:nav_tracker(),
            CONSTANTS.COVER_TACTICS_FOLLOW_MAX_DISTANCE,
            false
end

local function _candidate_is_valid(
        candidate,
        old_cover,
        anchor_pos,
        threat_pos,
        max_distance,
        follow_cover
)
    if not (candidate and candidate[1] and anchor_pos and threat_pos) then
        return false
    end

    local old_pos = type(old_cover) == "table"
            and old_cover[1]
            and old_cover[1][1]
    local min_distance = CONSTANTS.COVER_TACTICS_REPOSITION_MIN_DISTANCE
    if old_pos
            and mvector3.distance_sq(candidate[1], old_pos)
            < min_distance * min_distance
    then
        return false
    end

    if mvector3.distance_sq(candidate[1], anchor_pos)
            > max_distance * max_distance
    then
        return false
    end

    if follow_cover then
        return CopLogicAttack._verify_follow_cover(
                candidate,
                anchor_pos,
                threat_pos,
                200,
                nil
        ) and true or false
    end

    return CopLogicAttack._verify_cover(candidate, threat_pos) and true or false
end

local function _threat_position(attention, target_pos)
    local tracker = attention and attention.nav_tracker
    if tracker then
        local field_pos = tracker:field_position()
        if field_pos then
            return field_pos
        end
    end

    return target_pos
end

local function _find_reposition_cover(data, state, attention, target_pos)
    local anchor_pos, anchor_tracker, max_distance, follow_cover = _follow_anchor(data)
    local threat_pos = _threat_position(attention, target_pos)
    if not (anchor_pos and anchor_tracker and threat_pos) then
        return nil, nil
    end

    local group_ai = managers.groupai
    local group_state = group_ai and group_ai:state()
    local area = group_state
            and group_state:get_area_from_nav_seg_id(anchor_tracker:nav_segment())
    local search_nav_segs = area and area.nav_segs
    if not search_nav_segs then
        return nil, nil
    end

    local away = mvector3.copy(anchor_pos)
    mvector3.subtract(away, threat_pos)
    mvector3.set_z(away, 0)
    if mvector3.length_sq(away) < 1 then
        mvector3.set(away, data.m_pos)
        mvector3.subtract(away, threat_pos)
        mvector3.set_z(away, 0)
    end
    if mvector3.length_sq(away) < 1 then
        mvector3.set(away, data.unit:movement():m_fwd())
        mvector3.set_z(away, 0)
    end
    if mvector3.length_sq(away) < 1 then
        return nil, nil
    end

    mvector3.normalize(away)
    local lateral = mvector3.copy(away)
    mvector3.cross(lateral, lateral, math.UP)
    mvector3.set_length(lateral, CONSTANTS.COVER_TACTICS_LATERAL_OFFSET)

    local my_data = data.internal_data
    local old_cover = my_data.in_cover
            or state.return_cover
            or my_data.best_cover
    local first_sign = state.reposition_sign or 1
    state.reposition_sign = -first_sign

    local fallback_candidate
    for _, sign in ipairs({ first_sign, -first_sign }) do
        local desired_pos = mvector3.copy(lateral)
        mvector3.multiply(desired_pos, sign)
        mvector3.add(desired_pos, anchor_pos)

        local candidate = managers.navigation:find_cover_in_nav_seg_3(
                search_nav_segs,
                CONSTANTS.COVER_TACTICS_COVER_SEARCH_RADIUS,
                desired_pos,
                threat_pos
        )
        if _candidate_is_valid(
                candidate,
                old_cover,
                anchor_pos,
                threat_pos,
                max_distance,
                follow_cover
        ) then
            fallback_candidate = fallback_candidate or candidate

            mvector3.set(tmp_candidate_from, candidate[1])
            mvector3.set_z(tmp_candidate_from, candidate[1].z + 150)
            if _fire_lane_is_clear(
                    data,
                    state,
                    attention,
                    tmp_candidate_from,
                    target_pos
            ) then
                return candidate, threat_pos
            end
        end
    end

    return fallback_candidate, threat_pos
end

local function _restore_fallback_cover(data, state)
    local my_data = data.internal_data
    local fallback = state.fallback_cover
    if not fallback or state.left_fallback then
        return false
    end

    if not _cover_matches(my_data.best_cover, fallback) then
        CopLogicAttack._set_best_cover(data, my_data, fallback)
    end

    return true
end

local function _finish_transfer(data, state, t, success)
    local my_data = data.internal_data

    _clear_transfer(state)
    state.return_cover = nil
    state.blocked_since_t = nil
    state.peek_attempted = nil
    state.next_reposition_t = success
            and t
            or t + CONSTANTS.COVER_TACTICS_RETRY_DELAY
    state.phase = "clear"
    state.lane = "-"
    my_data.cover_test_step = 3
end

local _begin_return

local function _fail_transfer(data, state, t)
    local failed_phase = state.phase
    local failed_cover = state.expected_cover
    local fallback = state.fallback_cover
    local left_fallback = state.left_fallback

    state.force_cover = false
    state.expected_cover = nil
    state.path_deadline_t = nil
    state.next_reposition_t = t + CONSTANTS.COVER_TACTICS_RETRY_DELAY

    if failed_phase == "repositioning" and fallback then
        if not left_fallback then
            _restore_fallback_cover(data, state)
            state.phase = "blocked"
            state.fallback_cover = nil
            state.left_fallback = nil
            return
        end

        state.return_cover = fallback
        state.fallback_cover = nil
        state.left_fallback = nil
        state.phase = "exposed"
        _begin_return(data, state, t)
        return
    end

    if failed_phase == "repositioning"
            and not fallback
            and _cover_matches(data.internal_data.best_cover, failed_cover)
    then
        CopLogicAttack._set_best_cover(data, data.internal_data, nil)
    end

    state.fallback_cover = nil
    state.left_fallback = nil
    state.phase = state.return_cover and "exposed" or "blocked"
end

local function _update_transfer(data, state, t)
    local my_data = data.internal_data
    local expected_cover = state.expected_cover
    if not expected_cover then
        _fail_transfer(data, state, t)
        return false
    end

    if _cover_matches(my_data.in_cover, expected_cover) then
        _finish_transfer(data, state, t, true)
        return false
    end

    if my_data.moving_to_cover then
        if _cover_matches(my_data.moving_to_cover, expected_cover) then
            state.left_fallback = true
            state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
            return true
        end

        _fail_transfer(data, state, t)
        return false
    end

    if not _cover_matches(my_data.best_cover, expected_cover) then
        _fail_transfer(data, state, t)
        return false
    end

    if state.path_deadline_t and t >= state.path_deadline_t then
        CopLogicAttack._cancel_cover_pathing(data, my_data)
        _fail_transfer(data, state, t)
        return false
    end

    return true
end

_begin_return = function(data, state, t)
    local my_data = data.internal_data
    local movement = data.unit:movement()
    local return_cover = state.return_cover or state.fallback_cover
    if not return_cover
            or t < (state.next_reposition_t or 0)
            or not movement
            or not _can_force_cover(data, my_data, movement)
    then
        return false
    end

    if not _cover_matches(my_data.best_cover, return_cover) then
        CopLogicAttack._set_best_cover(data, my_data, return_cover)
    end

    state.phase = "returning"
    state.force_cover = true
    state.expected_cover = return_cover
    state.fallback_cover = nil
    state.left_fallback = true
    state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
    state.blocked_since_t = nil
    state.lane = "-"
    my_data.want_to_take_cover = true

    return true
end

local function _abort_active_state(data, state, t)
    local my_data = data.internal_data
    if state.force_cover and not my_data.moving_to_cover then
        CopLogicAttack._cancel_cover_pathing(data, my_data)
    end

    if state.phase == "repositioning" and not state.left_fallback then
        if not _restore_fallback_cover(data, state)
                and _cover_matches(my_data.best_cover, state.expected_cover)
        then
            CopLogicAttack._set_best_cover(data, my_data, nil)
        end
    end

    _clear_transfer(state)
    state.return_cover = nil
    state.blocked_since_t = nil
    state.peek_attempted = nil
    state.next_reposition_t = t + CONSTANTS.COVER_TACTICS_RETRY_DELAY
    state.phase = "clear"
    state.lane = "-"
end

local function _try_stand_for_lane(data, state, attention, target_pos)
    local my_data = data.internal_data
    local movement = data.unit:movement()
    local anim_data = data.unit:anim_data()
    local allowed_poses = data.char_tweak and data.char_tweak.allowed_poses
    local objective = data.objective
    if not anim_data.crouch
            or my_data.want_to_take_cover
            or objective and objective.pose == "crouch"
            or allowed_poses and not allowed_poses.stand
            or movement:chk_action_forbidden("stand")
    then
        return false
    end

    mvector3.set(tmp_fire_from, data.m_pos)
    mvector3.set_z(tmp_fire_from, data.m_pos.z + 150)
    if not _fire_lane_is_clear(
            data,
            state,
            attention,
            tmp_fire_from,
            target_pos
    ) then
        return false
    end

    my_data.cover_test_step = 3
    if not CopLogicAttack._chk_request_action_stand(data) then
        return false
    end

    state.phase = "standing"
    state.blocked_since_t = nil
    return true
end

local function _try_lateral_peek(data, state, attention, target_pos)
    local my_data = data.internal_data
    local in_cover = my_data.in_cover
    local movement = data.unit:movement()
    local tracker = movement and movement:nav_tracker()
    if not (in_cover and tracker) then
        return false
    end

    local anim_data = data.unit:anim_data()
    local height = anim_data.crouch and 80 or 150
    local min_distance = CONSTANTS.COVER_TACTICS_PEEK_MIN_DISTANCE
    state.peek_attempted = true

    for step = 1, 2 do
        my_data.cover_test_step = step
        local peek_pos = CopLogicAttack._peek_for_pos_sideways(
                data,
                my_data,
                tracker,
                target_pos,
                height
        )
        my_data.cover_test_step = 3

        if peek_pos
                and mvector3.distance_sq(peek_pos, data.m_pos)
                >= min_distance * min_distance
        then
            mvector3.set(tmp_fire_from, peek_pos)
            mvector3.set_z(tmp_fire_from, peek_pos.z + height)
            if _fire_lane_is_clear(
                    data,
                    state,
                    attention,
                    tmp_fire_from,
                    target_pos
            ) then
                state.return_cover = in_cover
                state.phase = "peeking"
                state.blocked_since_t = nil

                local path = {
                    mvector3.copy(tracker:position()),
                    mvector3.copy(peek_pos),
                }
                CopLogicAttack._chk_request_action_walk_to_cover_shoot_pos(
                        data,
                        my_data,
                        path,
                        "walk"
                )
                if my_data.walking_to_cover_shoot_pos then
                    return true
                end

                state.return_cover = nil
                state.phase = "blocked"
            end
        end
    end

    my_data.cover_test_step = 3
    return false
end

local function _begin_reposition(data, state, attention, target_pos, t)
    local my_data = data.internal_data
    local was_exposed = state.phase == "exposed"
    local candidate, threat_pos = _find_reposition_cover(
            data,
            state,
            attention,
            target_pos
    )
    if not candidate then
        state.peek_attempted = nil
        if was_exposed and state.return_cover then
            state.next_reposition_t = t
            if not _begin_return(data, state, t) then
                state.next_reposition_t = t
                        + CONSTANTS.COVER_TACTICS_RETRY_DELAY
            end
        else
            state.next_reposition_t = t
                    + CONSTANTS.COVER_TACTICS_RETRY_DELAY
            state.phase = "blocked"
        end
        return false
    end

    local fallback = my_data.in_cover
            or state.return_cover
            or my_data.best_cover
    local better_cover = { candidate }
    CopLogicAttack._set_best_cover(data, my_data, better_cover)

    local offset_pos, yaw = CopLogicAttack._get_cover_offset_pos(
            data,
            better_cover,
            threat_pos
    )
    if offset_pos then
        better_cover[5] = offset_pos
        better_cover[6] = yaw
    end

    state.phase = "repositioning"
    state.force_cover = true
    state.expected_cover = better_cover
    state.fallback_cover = fallback
    state.left_fallback = my_data.in_cover == nil and fallback ~= nil or false
    state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
    state.blocked_since_t = nil
    state.peek_attempted = true
    state.lane = "blocked"
    my_data.want_to_take_cover = true

    return true
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

    local t = data.t or game_time()
    my_data.cover_test_step = 3
    my_data._bb_next_cover_tactics_t = nil
    my_data._bb_cover_tactics = _new_state(data, t)

    return true
end

function CoverTactics:on_exit(data)
    local my_data = data and data.internal_data
    local state = my_data and my_data._bb_cover_tactics
    if not state then
        return false
    end

    state.force_cover = false
    state._walk_completion = nil
    state.phase = "clear"
    return true
end

function CoverTactics:should_force_cover(my_data)
    local state = my_data and my_data._bb_cover_tactics
    return state and state.force_cover == true or false
end

function CoverTactics:before_action_complete(data, action)
    local my_data = data and data.internal_data
    local state = my_data and my_data._bb_cover_tactics
    if not _is_current_assault(data, my_data)
            or not state
            or not action
            or action:type() ~= "walk"
    then
        return false
    end

    local was_peek = my_data.walking_to_cover_shoot_pos ~= nil
    state._walk_completion = {
        phase = state.phase,
        expired = action:expired(),
        was_peek = was_peek,
        was_transfer = my_data.moving_to_cover ~= nil
                and (state.phase == "repositioning"
                or state.phase == "returning"),
    }

    if was_peek then
        -- TeamAILogicAssault omits the marker used by the native cover flow.
        my_data.at_cover_shoot_pos = true
    end

    return true
end

function CoverTactics:after_action_complete(data, action)
    local my_data = data and data.internal_data
    local state = my_data and my_data._bb_cover_tactics
    local completion = state and state._walk_completion
    if not _is_current_assault(data, my_data)
            or not completion
            or not action
            or action:type() ~= "walk"
    then
        return false
    end

    state._walk_completion = nil
    local t = data.t or game_time()
    if completion.was_peek and completion.phase == "peeking" then
        if completion.expired then
            state.phase = "exposed"
            state.blocked_since_t = nil
            state.next_lane_check_t = t
            state.lane = "-"
        elseif not _begin_return(data, state, t) then
            state.phase = "exposed"
        end
        return true
    end

    if completion.was_transfer
            and (completion.phase == "repositioning"
            or completion.phase == "returning")
    then
        if completion.expired
                and _cover_matches(my_data.in_cover, state.expected_cover)
        then
            _finish_transfer(data, state, t, true)
        else
            _fail_transfer(data, state, t)
        end
        return true
    end

    return false
end

function CoverTactics:update(data)
    local my_data = data and data.internal_data
    local state = my_data and my_data._bb_cover_tactics
    if not _is_current_assault(data, my_data) or not state then
        return false
    end

    local movement = alive(data.unit) and data.unit:movement()
    if not movement then
        return false
    end

    local t = data.t or game_time()
    my_data.cover_test_step = 3

    if my_data.attitude ~= "engage"
            or _movement_is_hard_blocked(data, my_data, movement)
    then
        _abort_active_state(data, state, t)
        return false
    end

    if state.phase == "repositioning" or state.phase == "returning" then
        return _update_transfer(data, state, t)
    end

    if state.phase == "peeking" then
        if my_data.walking_to_cover_shoot_pos then
            return true
        end

        state.phase = "exposed"
        state.next_lane_check_t = t
    end

    local attention = data.attention_obj
    local target_pos, target_verified = _get_target_position(
            attention,
            t,
            tmp_target_pos
    )
    if not target_pos then
        state.target_key = nil
        state.blocked_since_t = nil
        state.peek_attempted = nil
        state.lane = "-"

        if state.phase == "exposed" and state.return_cover then
            _begin_return(data, state, t)
        elseif state.phase == "blocked" or state.phase == "standing" then
            state.phase = "clear"
        end
        return false
    end

    local target_key = attention.u_key or attention.unit:key()
    if state.target_key ~= target_key then
        state.target_key = target_key
        state.blocked_since_t = nil
        state.peek_attempted = nil
        state.next_reposition_t = t
        state.lane = "-"
        if state.phase == "blocked" or state.phase == "standing" then
            state.phase = "clear"
        end
    end

    if my_data.want_to_take_cover then
        state.blocked_since_t = nil
        state.lane = "cover"
        if state.phase == "exposed" and state.return_cover then
            _begin_return(data, state, t)
        elseif state.phase == "blocked" or state.phase == "standing" then
            state.phase = "clear"
        end
        return false
    end

    if t < state.next_lane_check_t then
        return false
    end
    state.next_lane_check_t = t + CONSTANTS.COVER_TACTICS_LANE_CHECK_INTERVAL

    local current_lane_clear = false
    if target_verified then
        current_lane_clear = _fire_lane_is_clear(
                data,
                state,
                attention,
                movement:m_head_pos(),
                target_pos
        )
    end

    if current_lane_clear then
        _clear_lane_tracking(state, t)
        if state.return_cover then
            state.phase = "exposed"
        end
        return true
    end

    state.lane = target_verified and "blocked" or "lost"
    if _try_stand_for_lane(data, state, attention, target_pos) then
        return true
    end

    state.blocked_since_t = state.blocked_since_t or t
    if state.phase ~= "exposed" then
        state.phase = "blocked"
    end

    if t - state.blocked_since_t < CONSTANTS.COVER_TACTICS_BLOCKED_TIMEOUT
            or t < state.next_reposition_t
            or not _can_start_movement(data, my_data, state, movement)
    then
        return true
    end

    if my_data.in_cover
            and not state.peek_attempted
            and _try_lateral_peek(data, state, attention, target_pos)
    then
        return true
    end

    return _begin_reposition(data, state, attention, target_pos, t)
end

return CoverTactics
