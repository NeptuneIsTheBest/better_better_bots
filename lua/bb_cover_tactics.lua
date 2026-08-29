local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils

local game_time = Utils.game_time

local CoverTactics = BB.CoverTactics or {}
BB.CoverTactics = CoverTactics

local function _is_live_player(unit)
    if not alive(unit) then
        return false
    end

    local players = managers.groupai:state():all_player_criminals()
    local record = players[unit:key()]

    return record and record.status ~= "dead"
end

local function _is_ordinary_player_follow(objective)
    return objective
            and objective.type == "follow"
            and objective.attitude == nil
            and not objective.forced
            and _is_live_player(objective.follow_unit)
end

function CoverTactics:normalize_objective(objective)
    if _is_ordinary_player_follow(objective) then
        objective.attitude = "engage"
    end
end

local function _new_state()
    return {
        phase = "idle",
        peek_attempts = 0,
        next_probe_t = 0,
        next_reposition_t = 0,
        force_cover = false,
    }
end

local function _target_key(attention)
    return attention and attention.u_key
end

local function _threat_position(attention)
    local tracker = attention and attention.nav_tracker

    return tracker and tracker:field_position()
end

local function _clear_blocker(my_data, state)
    local blocker = state.blocker
    if blocker and my_data.walking_to_cover_shoot_pos == blocker then
        my_data.walking_to_cover_shoot_pos = nil
    end

    state.blocker = nil
end

local function _install_blocker(data, state)
    local my_data = data.internal_data
    if my_data.walking_to_cover_shoot_pos then
        return false
    end

    local blocker = {
        _last_pos = mvector3.copy(data.m_pos),
    }

    state.blocker = blocker
    my_data.walking_to_cover_shoot_pos = blocker
    return true
end

local function _objective_blocks_movement(objective)
    return objective
            and (objective.forced
            or objective.type == "revive"
            or objective.type == "act"
            or objective.type == "throw_bag")
end

local function _hard_blocked(data, my_data)
    local movement = data.unit:movement()
    if _objective_blocks_movement(data.objective)
            or movement:should_stay()
            or movement:carrying_bag()
    then
        return true
    end

    return my_data.surprised
end

local function _can_start_probe(data, my_data)
    local movement = data.unit:movement()
    if _hard_blocked(data, my_data)
            or movement:chk_action_forbidden("walk")
            or my_data.turning
            or my_data.moving_to_cover
            or my_data.walking_to_cover_shoot_pos
            or my_data.processing_cover_path
            or my_data.cover_path
            or my_data.charge_path_search_id
            or my_data._turning_to_intimidate
    then
        return false
    end

    return my_data.in_cover ~= nil
end

local function _attention_is_combat(attention)
    return attention
            and attention.reaction >= AIAttentionObject.REACT_COMBAT
            and alive(attention.unit)
end

local function _cover_matches(a, b)
    return a ~= nil and b ~= nil and (a == b or a[1] == b[1])
end

local function _set_idle(state)
    state.phase = "idle"
    state.force_cover = false
    state.path_deadline_t = nil
    state.expose_until_t = nil
    state.expected_cover = nil
    state.fallback_cover = nil
    state.left_fallback = nil
    state.abort_after_peek = nil
    state.reset_after_move = nil
    state.reacquired = nil
    state.return_cover = nil
end

local function _restore_fallback_cover(data, state)
    local my_data = data.internal_data
    local fallback = state.fallback_cover
    if not fallback or state.left_fallback then
        return
    end

    if not _cover_matches(my_data.best_cover, fallback) then
        CopLogicAttack._set_best_cover(data, my_data, fallback)
    end
end

local function _cancel_active_state(data, state)
    local my_data = data.internal_data
    if state.force_cover and not my_data.moving_to_cover then
        CopLogicAttack._cancel_cover_pathing(data, my_data)
    end

    if state.phase == "repositioning" and not my_data.moving_to_cover then
        _restore_fallback_cover(data, state)
    end

    _clear_blocker(my_data, state)
    _set_idle(state)
    state.peek_attempts = 0
end

function CoverTactics:on_enter(data)
    data.internal_data._bb_cover_tactics = _new_state()
end

function CoverTactics:on_exit(data)
    local my_data = data.internal_data
    local state = my_data._bb_cover_tactics

    _clear_blocker(my_data, state)
    state.force_cover = false
end

function CoverTactics:after_update(data)
    local my_data = data.internal_data
    local state = my_data._bb_cover_tactics
    if state.phase == "exposed" then
        _clear_blocker(my_data, state)
    end
end

function CoverTactics:should_force_cover(my_data)
    local state = my_data._bb_cover_tactics

    return state and state.force_cover
end

local function _register_probe_failure(state, t)
    state.peek_attempts = state.peek_attempts + 1
    state.next_probe_t = t + CONSTANTS.COVER_TACTICS_PEEK_RETRY_DELAY
    _set_idle(state)

    if state.peek_attempts >= CONSTANTS.COVER_TACTICS_MAX_PEEK_ATTEMPTS then
        if t >= state.next_reposition_t then
            state.phase = "reposition_pending"
        else
            state.peek_attempts = 0
            state.next_probe_t = state.next_reposition_t
        end
    end
end

local function _finish_return(state, t)
    local successful = state.reacquired and not state.reset_after_move
    local reset = state.reset_after_move

    if successful or reset then
        _set_idle(state)
        state.peek_attempts = 0
        state.next_probe_t = t + CONSTANTS.COVER_TACTICS_LOS_GRACE
    else
        _register_probe_failure(state, t)
    end
end

local function _finish_reposition(data, state, t, succeeded)
    if not succeeded then
        _restore_fallback_cover(data, state)
    end

    _set_idle(state)
    state.peek_attempts = 0
    state.next_probe_t = t + CONSTANTS.COVER_TACTICS_LOS_GRACE
    state.next_reposition_t = t + CONSTANTS.COVER_TACTICS_REPOSITION_COOLDOWN
end

local function _begin_return(data, state, t)
    local my_data = data.internal_data
    _clear_blocker(my_data, state)

    local return_cover = state.return_cover
    if not _cover_matches(my_data.best_cover, return_cover) then
        CopLogicAttack._set_best_cover(data, my_data, return_cover)
    end

    state.phase = "returning"
    state.force_cover = true
    state.expected_cover = return_cover
    state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
end

local function _begin_probe(data, state, attention, t)
    local my_data = data.internal_data
    local in_cover = my_data.in_cover
    local tracker = data.unit:movement():nav_tracker()

    local attempt = math.min(
            state.peek_attempts + 1,
            CONSTANTS.COVER_TACTICS_MAX_PEEK_ATTEMPTS
    )
    local previous_step = my_data.cover_test_step
    my_data.cover_test_step = attempt

    local height = in_cover[4] and 150 or 80
    local peek_pos = CopLogicAttack._peek_for_pos_sideways(
            data,
            my_data,
            tracker,
            attention.m_head_pos,
            height
    )

    my_data.cover_test_step = previous_step

    if not peek_pos
            or mvector3.distance_sq(peek_pos, data.m_pos) < 2500
    then
        _register_probe_failure(state, t)
        return
    end

    state.return_cover = in_cover
    state.reacquired = attention.verified
    state.phase = "peek_out"

    local path = {
        tracker:position(),
        peek_pos,
    }
    CopLogicAttack._chk_request_action_walk_to_cover_shoot_pos(
            data,
            my_data,
            path,
            "walk"
    )

    if not my_data.walking_to_cover_shoot_pos then
        _register_probe_failure(state, t)
    end
end

local function _follow_anchor(data)
    local objective = data.objective
    if objective
            and objective.type == "follow"
            and alive(objective.follow_unit)
    then
        local movement = objective.follow_unit:movement()
        local max_distance = objective._bb_rescue_guard
                and CONSTANTS.RESCUE_GUARD_POSITION_RANGE
                or CONSTANTS.COVER_TACTICS_FOLLOW_MAX_DISTANCE

        return movement:m_newest_pos(), movement:nav_tracker(), max_distance
    end

    local movement = data.unit:movement()

    return data.m_pos,
            movement:nav_tracker(),
            CONSTANTS.COVER_TACTICS_FOLLOW_MAX_DISTANCE
end

local function _candidate_is_valid(
        candidate,
        old_cover,
        anchor_pos,
        threat_pos,
        max_distance,
        follow_cover
)
    if not candidate then
        return false
    end

    local candidate_pos = candidate[1]
    local old_pos = old_cover and old_cover[1][1]
    local min_distance = CONSTANTS.COVER_TACTICS_REPOSITION_MIN_DISTANCE
    if old_pos
            and mvector3.distance_sq(candidate_pos, old_pos) < min_distance * min_distance
    then
        return false
    end

    if mvector3.distance_sq(candidate_pos, anchor_pos) > max_distance * max_distance then
        return false
    end

    if follow_cover then
        return CopLogicAttack._verify_follow_cover(
                candidate,
                anchor_pos,
                threat_pos,
                200,
                1000
        )
    end

    return CopLogicAttack._verify_cover(candidate, threat_pos)
end

local function _find_reposition_cover(data, state, attention)
    local anchor_pos, anchor_tracker, max_distance = _follow_anchor(data)
    local threat_pos = _threat_position(attention)
    if not threat_pos then
        return
    end

    local nav_seg = anchor_tracker:nav_segment()
    local area = managers.groupai:state():get_area_from_nav_seg_id(nav_seg)
    local search_nav_segs = area.nav_segs

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
        return
    end

    mvector3.normalize(away)
    local lateral = mvector3.copy(away)
    mvector3.cross(lateral, lateral, math.UP)
    mvector3.set_length(lateral, CONSTANTS.COVER_TACTICS_LATERAL_OFFSET)

    local old_cover = data.internal_data.in_cover
            or state.return_cover
            or data.internal_data.best_cover
    local follow_cover = data.objective and data.objective.type == "follow"
    local first_sign = state.reposition_sign
            or (data.key % 2 == 0 and 1 or -1)
    state.reposition_sign = -first_sign

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
            return candidate
        end
    end

    return
end

local function _begin_reposition(
        data,
        state,
        attention,
        t,
        wants_cover,
        combat_attention
)
    local my_data = data.internal_data
    if t < state.next_reposition_t
            or _hard_blocked(data, my_data)
            or wants_cover
            or not combat_attention
            or attention.verified
    then
        _finish_reposition(data, state, t, false)
        return
    end

    local verified_t = attention.verified_t
    if not verified_t
            or t - verified_t > CONSTANTS.COVER_TACTICS_TARGET_MEMORY
    then
        _finish_reposition(data, state, t, false)
        return
    end

    local candidate = _find_reposition_cover(data, state, attention)
    if not candidate then
        _finish_reposition(data, state, t, false)
        return
    end

    state.fallback_cover = my_data.in_cover
    state.left_fallback = nil

    local better_cover = { candidate }
    CopLogicAttack._set_best_cover(data, my_data, better_cover)

    local offset_pos = CopLogicAttack._get_cover_offset_pos(
            data,
            better_cover,
            _threat_position(attention)
    )
    if offset_pos then
        better_cover[5] = offset_pos
    end

    state.phase = "repositioning"
    state.force_cover = true
    state.expected_cover = better_cover
    state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
end

local function _update_cover_transfer(data, state, t)
    local my_data = data.internal_data
    local expected_cover = state.expected_cover
    if _cover_matches(my_data.in_cover, expected_cover) then
        if state.phase == "returning" then
            _finish_return(state, t)
        else
            _finish_reposition(data, state, t, true)
        end
        return
    end

    if my_data.moving_to_cover then
        if state.phase == "repositioning" then
            state.left_fallback = true
        end
        state.path_deadline_t = nil
        return
    end

    if not _cover_matches(my_data.best_cover, expected_cover) then
        if state.phase == "returning" then
            state.force_cover = false
            state.peek_attempts = CONSTANTS.COVER_TACTICS_MAX_PEEK_ATTEMPTS
            state.phase = "reposition_pending"
        else
            _finish_reposition(data, state, t, false)
        end
        return
    end

    state.path_deadline_t = state.path_deadline_t
            or t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
    if t < state.path_deadline_t then
        return
    end

    CopLogicAttack._cancel_cover_pathing(data, my_data)
    if state.phase == "returning" then
        state.force_cover = false
        state.peek_attempts = CONSTANTS.COVER_TACTICS_MAX_PEEK_ATTEMPTS
        state.phase = "reposition_pending"
    else
        _finish_reposition(data, state, t, false)
    end
end

function CoverTactics:update(data)
    local my_data = data.internal_data
    local state = my_data._bb_cover_tactics
    local t = game_time()
    local attention = data.attention_obj
    local combat_attention = _attention_is_combat(attention)
    local wants_cover = combat_attention
            and CopLogicAttack._chk_wants_to_take_cover(data, my_data)
    local current_target_key = _target_key(attention)
    local target_changed = state.target_key ~= nil
            and current_target_key ~= state.target_key

    if target_changed then
        if state.phase == "peek_out" then
            state.abort_after_peek = true
            state.reset_after_move = true
            state.reacquired = nil
        elseif state.phase == "exposed" then
            state.reset_after_move = true
            state.reacquired = nil
        elseif state.phase == "returning" or state.phase == "repositioning" then
            state.reset_after_move = true
        else
            state.peek_attempts = 0
        end
    end

    if current_target_key then
        state.target_key = current_target_key
    end

    if _hard_blocked(data, my_data) then
        _cancel_active_state(data, state)
        return
    end

    if state.phase == "peek_out" then
        if attention and attention.verified then
            state.reacquired = true
        end
        if wants_cover then
            state.abort_after_peek = true
            state.reset_after_move = true
        end
        return
    elseif state.phase == "exposed" then
        if not state.blocker and not _install_blocker(data, state) then
            state.expose_until_t = t
        end

        if attention and attention.verified then
            state.reacquired = true
        end

        if wants_cover
                or target_changed
                or not combat_attention
                or t >= state.expose_until_t
        then
            if wants_cover or not combat_attention then
                state.reset_after_move = true
            end

            _begin_return(data, state, t)
        end

        return
    elseif state.phase == "returning" or state.phase == "repositioning" then
        _update_cover_transfer(data, state, t)
        return
    elseif state.phase == "reposition_pending" then
        _begin_reposition(
                data,
                state,
                attention,
                t,
                wants_cover,
                combat_attention
        )
        return
    end

    if not _can_start_probe(data, my_data)
            or wants_cover
            or not combat_attention
    then
        return
    end

    if attention.verified then
        state.peek_attempts = 0
        return
    end

    local verified_t = attention.verified_t
    if not verified_t then
        return
    end

    local since_verified = t - verified_t
    if t < state.next_probe_t
            or since_verified < CONSTANTS.COVER_TACTICS_LOS_GRACE
            or since_verified > CONSTANTS.COVER_TACTICS_TARGET_MEMORY
    then
        return
    end

    _begin_probe(data, state, attention, t)
end

function CoverTactics:on_action_complete(data, action, previous_phase, was_cover_move)
    local state = data.internal_data._bb_cover_tactics
    if action:type() ~= "walk" or previous_phase ~= state.phase then
        return
    end

    local t = game_time()
    if previous_phase == "peek_out" then
        if action:expired() then
            state.phase = "exposed"
            state.expose_until_t = t + CONSTANTS.COVER_TACTICS_PEEK_DURATION
            if not _install_blocker(data, state) then
                state.expose_until_t = t
            end

            if state.abort_after_peek then
                state.expose_until_t = t
            end
        else
            state.reacquired = nil
            _begin_return(data, state, t)
        end

        return
    elseif previous_phase == "returning" and was_cover_move then
        if action:expired() then
            _finish_return(state, t)
        else
            state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
        end

        return
    elseif previous_phase == "repositioning" and was_cover_move then
        if action:expired() then
            _finish_reposition(data, state, t, true)
        else
            state.left_fallback = true
            state.path_deadline_t = t + CONSTANTS.COVER_TACTICS_PATH_TIMEOUT
        end

        return
    end
end

return CoverTactics
