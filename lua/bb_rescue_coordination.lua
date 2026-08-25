local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local EnemyClassifier = BB.EnemyClassifier
local UnitOps = BB.UnitOps
local Utils = BB.Utils

local are_units_foes = UnitOps.are_foes
local game_time = Utils.game_time
local is_team_ai = UnitOps.is_team_ai

local RescueCoordinator = BB.RescueCoordinator or {}
RescueCoordinator._sessions = RescueCoordinator._sessions or {}
RescueCoordinator._next_update_t = RescueCoordinator._next_update_t or 0

local function _unit_key(unit)
    return alive(unit) and tostring(unit:key()) or nil
end

local function _unit_position(unit)
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

local function _attention_position(attention_data)
    if not attention_data then
        return nil
    end

    return attention_data.m_pos
            or attention_data.m_head_pos
            or attention_data.verified_pos
            or _unit_position(attention_data.unit)
end

local function _get_objective(unit)
    local brain = alive(unit) and unit:brain()
    return brain and brain:objective() or nil
end

local function _is_dead(unit)
    if not alive(unit) then
        return true
    end

    local damage = unit:character_damage()
    return damage and ((damage.dead and damage:dead()) or damage._dead) or false
end

local function _is_healthy_team_ai(unit)
    if not (alive(unit) and is_team_ai(unit)) or _is_dead(unit) then
        return false
    end

    local damage = unit:character_damage()
    if damage then
        if damage.need_revive and damage:need_revive() then
            return false
        end
        if damage.arrested and damage:arrested() then
            return false
        end
    end

    return true
end

local function _get_group_state()
    return managers.groupai and managers.groupai:state() or nil
end

local function _combat_reaction()
    return AIAttentionObject.REACT_COMBAT
end

function RescueCoordinator.target_needs_help(unit)
    if not alive(unit) or _is_dead(unit) then
        return false
    end

    local damage = unit:character_damage()
    if damage then
        if damage.need_revive and damage:need_revive() then
            return true
        end
        if damage.arrested and damage:arrested() then
            return true
        end
    end

    local movement = unit:movement()
    if movement then
        if movement.need_revive and movement:need_revive() then
            return true
        end
        if movement.current_state_name and movement:current_state_name() == "arrested" then
            return true
        end
    end

    return false
end

function RescueCoordinator.get_remaining_rescue_time(unit)
    if not alive(unit) then
        return nil
    end

    local base = unit:base()
    local damage = unit:character_damage()
    if base and base.is_local_player and damage then
        if type(damage._downed_timer) == "number" then
            return damage._downed_timer
        elseif type(damage._arrested_timer) == "number" then
            return damage._arrested_timer
        end
    end

    local interaction = unit:interaction()
    if interaction and interaction.get_waypoint_time then
        local timer = interaction:get_waypoint_time()
        if type(timer) == "number" then
            return timer
        end
    end

    if damage then
        if type(damage._to_dead_t) == "number" then
            return math.max(damage._to_dead_t - game_time(), 0)
        elseif type(damage._arrested_timer) == "number" then
            return damage._arrested_timer
        end
    end

    return nil
end

function RescueCoordinator.is_rescue_urgent(unit)
    local remaining = RescueCoordinator.get_remaining_rescue_time(unit)
    return remaining and remaining <= CONSTANTS.RESCUE_URGENT_TIME or false
end

local function _is_known_combat_attention(observer, attention_data, t)
    if not (alive(observer)
            and attention_data
            and attention_data.identified
            and alive(attention_data.unit)
            and not _is_dead(attention_data.unit))
    then
        return false
    end

    local reaction = attention_data.reaction
            or attention_data.settings and attention_data.settings.reaction
    if type(reaction) ~= "number" or reaction < _combat_reaction() then
        return false
    end

    if not are_units_foes(observer, attention_data.unit) then
        return false
    end

    local recently_verified = attention_data.verified_t
            and t - attention_data.verified_t <= CONSTANTS.RESCUE_THREAT_VERIFY_GRACE

    return attention_data.verified == true
            or attention_data.nearly_visible == true
            or recently_verified == true
end

local function _is_attention_in_rescue_area(objective, attention_data)
    local rescue_unit = objective and objective.follow_unit
    local rescue_pos = _unit_position(rescue_unit)
    local enemy_pos = _attention_position(attention_data)
    if not (rescue_pos and enemy_pos) then
        return false
    end

    local max_range = CONSTANTS.RESCUE_GUARD_THREAT_RANGE
    return mvector3.distance_sq(rescue_pos, enemy_pos) <= max_range * max_range
end

function RescueCoordinator.collect_known_threats(group_state, rescue_unit)
    local threats = {}
    local rescue_pos = _unit_position(rescue_unit)
    if not (group_state and rescue_pos) then
        return threats
    end

    local t = game_time()
    local max_range = CONSTANTS.RESCUE_GUARD_THREAT_RANGE
    local max_range_sq = max_range * max_range

    for _, ai_data in pairs(group_state:all_AI_criminals()) do
        local observer = ai_data.unit
        local brain = alive(observer) and observer:brain()
        local logic_data = brain and brain._logic_data

        for _, attention_data in pairs(logic_data and logic_data.detected_attention_objects or {}) do
            if _is_known_combat_attention(observer, attention_data, t) then
                local enemy_pos = _attention_position(attention_data)
                if enemy_pos and mvector3.distance_sq(rescue_pos, enemy_pos) <= max_range_sq then
                    local enemy_key = _unit_key(attention_data.unit)
                    if enemy_key and not threats[enemy_key] then
                        threats[enemy_key] = {
                            attention = attention_data,
                            distance = mvector3.distance(rescue_pos, enemy_pos),
                            unit = attention_data.unit,
                        }
                    end
                end
            end
        end
    end

    return threats
end

local function _collect_active_rescues(group_state, sessions)
    local rescues = {}
    if not group_state then
        return rescues
    end

    for _, ai_data in pairs(group_state:all_AI_criminals()) do
        local rescuer = ai_data.unit
        local objective = _get_objective(rescuer)
        local rescue_unit = objective and objective.type == "revive" and objective.follow_unit

        if _is_healthy_team_ai(rescuer)
                and RescueCoordinator.target_needs_help(rescue_unit)
        then
            local target_key = _unit_key(rescue_unit)
            local current = target_key and rescues[target_key]
            local session = target_key and sessions[target_key]
            local logic_data = rescuer:brain() and rescuer:brain()._logic_data
            local internal_data = logic_data and logic_data.internal_data
            local is_acting = internal_data and internal_data.reviving == rescue_unit

            if target_key
                    and (not current
                    or session and session.rescuer == rescuer
                    or is_acting and not current.is_acting)
            then
                rescues[target_key] = {
                    is_acting = is_acting or false,
                    objective = objective,
                    rescuer = rescuer,
                    target = rescue_unit,
                }
            end
        end
    end

    return rescues
end

local function _count_uncovered_help_targets(group_state)
    local needs_help = {}
    local covered = {}

    if group_state then
        for _, criminal_data in pairs(group_state:all_char_criminals()) do
            local unit = criminal_data.unit
            if RescueCoordinator.target_needs_help(unit) then
                local key = _unit_key(unit)
                if key then
                    needs_help[key] = true
                end
            end
        end
    end

    if group_state then
        for _, ai_data in pairs(group_state:all_AI_criminals()) do
            local rescuer = ai_data.unit
            local objective = _get_objective(rescuer)
            if _is_healthy_team_ai(rescuer)
                    and objective
                    and objective.type == "revive"
                    and RescueCoordinator.target_needs_help(objective.follow_unit)
            then
                local key = _unit_key(objective.follow_unit)
                if key then
                    covered[key] = true
                end
            end
        end
    end

    local count = 0
    for key in pairs(needs_help) do
        if not covered[key] then
            count = count + 1
        end
    end

    return count
end

local function _guard_objective_matches(session, objective)
    return objective
            and objective._bb_rescue_guard == true
            and tostring(objective._bb_rescue_target_key) == session.key
end

function RescueCoordinator:_guard_is_current(session)
    if not (session and _is_healthy_team_ai(session.guard)) then
        return false
    end

    local objective = _get_objective(session.guard)
    if not _guard_objective_matches(session, objective) then
        return false
    end

    session.guard_objective = objective
    return true
end

function RescueCoordinator:_is_basic_guard_candidate(session, unit, check_availability)
    if not (_is_healthy_team_ai(unit)
            and unit ~= session.rescuer
            and unit ~= session.target)
    then
        return false
    end

    local movement = unit:movement()
    if movement and movement.should_stay and movement:should_stay() then
        return false
    end

    local unit_pos = _unit_position(unit)
    local target_pos = _unit_position(session.target)
    local max_assign_range = CONSTANTS.RESCUE_GUARD_ASSIGN_RANGE
    if not (unit_pos and target_pos)
            or mvector3.distance_sq(unit_pos, target_pos) > max_assign_range * max_assign_range
    then
        return false
    end

    local brain = unit:brain()
    local objective = brain and brain:objective()
    if objective then
        if objective.type == "revive"
                or objective._bb_rescue_guard
                or objective.forced
        then
            return false
        end
    end

    if check_availability and brain then
        if not brain:is_available_for_assignment(session.guard_template) then
            return false
        end
    end

    return true
end

function RescueCoordinator:_has_spare_guard_candidate(session, group_state)
    local free_count = 0

    for _, ai_data in pairs(group_state:all_AI_criminals()) do
        if self:_is_basic_guard_candidate(session, ai_data.unit, true) then
            free_count = free_count + 1
        end
    end

    return free_count > _count_uncovered_help_targets(group_state)
end

function RescueCoordinator:_verify_guard_candidate(target_key, unit)
    local session = self._sessions[tostring(target_key)]
    local group_state = _get_group_state()
    if not (session
            and group_state
            and RescueCoordinator.target_needs_help(session.target)
            and _is_healthy_team_ai(session.rescuer))
    then
        return false
    end

    return self:_is_basic_guard_candidate(session, unit, false)
            and self:_has_spare_guard_candidate(session, group_state)
end

function RescueCoordinator:_on_guard_failed(target_key, unit)
    local session = self._sessions[tostring(target_key)]
    if session and (not unit or session.guard == unit) then
        session.guard = nil
        session.guard_objective = nil
        session.guard_so_id = nil
    end
end

function RescueCoordinator:_release_orphan_guard(unit, target_key)
    if not alive(unit) then
        return
    end

    local objective = _get_objective(unit)
    if not (objective
            and objective._bb_rescue_guard
            and tostring(objective._bb_rescue_target_key) == tostring(target_key))
    then
        return
    end

    local group_state = _get_group_state()
    if group_state then
        group_state:on_criminal_objective_complete(unit, objective)
    else
        local brain = unit:brain()
        if brain then
            brain:set_objective(nil)
        end
    end
end

function RescueCoordinator:_on_guard_assigned(target_key, unit)
    local key = tostring(target_key)
    local session = self._sessions[key]

    if not session then
        self:_release_orphan_guard(unit, key)
        return
    end

    if session.guard and session.guard ~= unit then
        self:_release_orphan_guard(unit, key)
        return
    end

    session.guard = unit
    session.guard_objective = _get_objective(unit)
    session.guard_so_id = nil
end

function RescueCoordinator:_try_assign_pending_guard(session, group_state)
    local so_id = session and session.guard_so_id
    local so = so_id
            and group_state
            and group_state._special_objectives
            and group_state._special_objectives[so_id]
    if not so then
        return false
    end

    local assigned = group_state:_execute_so(
            so.data,
            so.rooms,
            so.administered
    )
    if not assigned then
        return false
    end

    group_state:remove_special_objective(so_id)

    return true
end

function RescueCoordinator:_register_guard(session, group_state)
    local target = session.target
    local movement = alive(target) and target:movement()
    local tracker = movement and movement.nav_tracker and movement:nav_tracker()
    local nav_seg = tracker and tracker:nav_segment()
    local search_pos = _unit_position(target)
    if not (nav_seg and search_pos) then
        return false
    end

    local objective = {
        attitude = "engage",
        called = true,
        destroy_clbk_key = false,
        follow_unit = target,
        nav_seg = nav_seg,
        scan = true,
        type = "follow",
        fail_clbk = callback(self, self, "_on_guard_failed", session.key),
        _bb_rescue_guard = true,
        _bb_rescue_rescuer_key = _unit_key(session.rescuer),
        _bb_rescue_target_key = session.key,
    }
    local so_id = "BB_rescue_guard_" .. session.key
    local max_assign_range = CONSTANTS.RESCUE_GUARD_ASSIGN_RANGE
    local descriptor = {
        AI_group = "friendlies",
        base_chance = 1,
        chance_inc = 0,
        interval = CONSTANTS.RESCUE_GUARD_RETRY_INTERVAL,
        objective = objective,
        search_dis_sq = max_assign_range * max_assign_range,
        search_pos = mvector3.copy(search_pos),
        usage_amount = 1,
        admin_clbk = callback(self, self, "_on_guard_assigned", session.key),
        verification_clbk = callback(self, self, "_verify_guard_candidate", session.key),
    }

    session.guard_template = objective
    session.guard_so_id = so_id
    group_state:add_special_objective(so_id, descriptor)

    self:_try_assign_pending_guard(session, group_state)

    return true
end

function RescueCoordinator:_finish_session(target_key, release_guard)
    local key = tostring(target_key)
    local session = self._sessions[key]
    if not session then
        return
    end

    self._sessions[key] = nil

    local group_state = _get_group_state()
    if session.guard_so_id and group_state then
        group_state:remove_special_objective(session.guard_so_id)
    end

    if release_guard and self:_guard_is_current(session) then
        local objective = session.guard_objective
        if group_state then
            group_state:on_criminal_objective_complete(session.guard, objective)
        else
            local brain = session.guard:brain()
            if brain then
                brain:set_objective(nil)
            end
        end
    end
end

function RescueCoordinator.update(group_state, force)
    if not (Network:is_server() and group_state) then
        return
    end

    local t = game_time()
    if not force and t < RescueCoordinator._next_update_t then
        return
    end
    RescueCoordinator._next_update_t = t + CONSTANTS.RESCUE_COORD_UPDATE_INTERVAL

    local active_rescues = _collect_active_rescues(group_state, RescueCoordinator._sessions)

    for target_key, session in pairs(RescueCoordinator._sessions) do
        local active = active_rescues[target_key]
        if not active
                or active.rescuer ~= session.rescuer
                or not RescueCoordinator.target_needs_help(session.target)
                or not _is_healthy_team_ai(session.rescuer)
        then
            RescueCoordinator:_finish_session(target_key, true)
        end
    end

    for target_key, rescue in pairs(active_rescues) do
        local session = RescueCoordinator._sessions[target_key]
        local threats = RescueCoordinator.collect_known_threats(group_state, rescue.target)
        local has_threats = next(threats) ~= nil

        if not session and has_threats then
            session = {
                created_t = t,
                key = target_key,
                objective = rescue.objective,
                rescuer = rescue.rescuer,
                target = rescue.target,
            }
            RescueCoordinator._sessions[target_key] = session
        end

        if session then
            session.objective = rescue.objective

            if session.guard and not RescueCoordinator:_guard_is_current(session) then
                session.guard = nil
                session.guard_objective = nil
            end

            if session.guard_so_id
                    and group_state._special_objectives
                    and not group_state._special_objectives[session.guard_so_id]
            then
                session.guard_so_id = nil
            end

            if session.guard_so_id and not session.guard then
                RescueCoordinator:_try_assign_pending_guard(session, group_state)
            end

            if session.guard then
                -- Keep the guard until the rescue objective ends.
            elseif not has_threats then
                RescueCoordinator:_finish_session(target_key, false)
            elseif not session.guard_so_id then
                RescueCoordinator:_register_guard(session, group_state)
            end
        end
    end
end

function RescueCoordinator.on_rescue_interaction(revive_unit, rescuer, complete)
    if not Network:is_server() then
        return
    end

    local target_key = _unit_key(revive_unit)
    if complete and target_key then
        RescueCoordinator:_finish_session(target_key, true)
    end

    local group_state = _get_group_state()
    if group_state then
        RescueCoordinator._next_update_t = 0
        RescueCoordinator.update(group_state, true)
    end
end

function RescueCoordinator.get_guard_for(revive_unit)
    local target_key = _unit_key(revive_unit)
    local session = target_key and RescueCoordinator._sessions[target_key]
    if session and RescueCoordinator:_guard_is_current(session) then
        return session.guard
    end

    return nil
end

function RescueCoordinator.has_guard_support(revive_unit)
    local target_key = _unit_key(revive_unit)
    local session = target_key and RescueCoordinator._sessions[target_key]
    if not session then
        return false
    end

    return RescueCoordinator:_guard_is_current(session)
end

local function _find_nearby_cloaker(data, preferred_key)
    local objective = data and data.objective
    if not (objective and objective.type == "revive" and alive(objective.follow_unit)) then
        return nil
    end

    local t = data.t or game_time()
    local best
    local best_active = false
    local best_distance = math.huge

    for u_key, attention_data in pairs(data.detected_attention_objects or {}) do
        if _is_known_combat_attention(data.unit, attention_data, t)
                and _is_attention_in_rescue_area(objective, attention_data)
                and EnemyClassifier.is_cloaker(attention_data.unit, attention_data)
        then
            local key = tostring(u_key)
            if preferred_key and key == tostring(preferred_key) then
                return attention_data
            end

            local flags = EnemyClassifier.classify(attention_data.unit, attention_data)
            local distance = attention_data.verified_dis
                    or mvector3.distance(
                            _unit_position(data.unit),
                            _attention_position(attention_data)
                    )
            local active = flags.spooc_attack == true

            if not best
                    or active and not best_active
                    or active == best_active and distance < best_distance
            then
                best = attention_data
                best_active = active
                best_distance = distance
            end
        end
    end

    return best
end

function RescueCoordinator.maybe_interrupt_rescue(data)
    local objective = data and data.objective
    if not (data
            and data.name == "idle"
            and data.internal_data
            and not data.internal_data.exiting
            and objective
            and objective.type == "revive"
            and RescueCoordinator.target_needs_help(objective.follow_unit))
    then
        return false
    end

    if RescueCoordinator.has_guard_support(objective.follow_unit)
            or RescueCoordinator.is_rescue_urgent(objective.follow_unit)
    then
        return false
    end

    local cloaker = _find_nearby_cloaker(data)
    if not cloaker then
        return false
    end

    objective._bb_rescue_cloaker_key = tostring(cloaker.u_key or cloaker.unit:key())
    TeamAILogicBase._exit(data.unit, "assault")

    return true
end

local function _resume_rescue(data, objective)
    objective._bb_rescue_cloaker_key = nil

    local rescue_unit = objective.follow_unit
    if not RescueCoordinator.target_needs_help(rescue_unit) then
        data.unit:brain():set_objective(nil)
        return true
    end

    local bot_pos = _unit_position(data.unit)
    local rescue_pos = _unit_position(rescue_unit)
    local close_enough = bot_pos
            and rescue_pos
            and mvector3.distance_sq(bot_pos, rescue_pos)
            <= CONSTANTS.RESCUE_RESUME_DISTANCE * CONSTANTS.RESCUE_RESUME_DISTANCE

    objective.in_place = close_enough and true or nil
    TeamAILogicBase._exit(data.unit, close_enough and "idle" or "travel")

    return true
end

function RescueCoordinator.update_solo_fallback(data)
    local objective = data and data.objective
    local guard_key = objective and objective._bb_rescue_cloaker_key
    if not (data
            and data.name == "assault"
            and objective
            and objective.type == "revive"
            and guard_key)
    then
        return false
    end

    if RescueCoordinator.has_guard_support(objective.follow_unit)
            or RescueCoordinator.is_rescue_urgent(objective.follow_unit)
    then
        return _resume_rescue(data, objective)
    end

    local cloaker = _find_nearby_cloaker(data, guard_key)
            or _find_nearby_cloaker(data)
    if cloaker then
        objective._bb_rescue_cloaker_key = tostring(cloaker.u_key or cloaker.unit:key())
        return false
    end

    return _resume_rescue(data, objective)
end

function RescueCoordinator.select_role_target(data, potential_targets_map)
    local objective = data and data.objective
    if not (objective and potential_targets_map) then
        return nil
    end

    if objective._bb_rescue_cloaker_key then
        local target = potential_targets_map[tostring(objective._bb_rescue_cloaker_key)]
        if target
                and EnemyClassifier.is_cloaker(target.data.unit, target.data)
                and _is_attention_in_rescue_area(objective, target.data)
        then
            return target, true
        end

        return nil, true
    end

    if not objective._bb_rescue_guard then
        return nil, false
    end

    local best
    local best_tier = -1
    local best_score = -math.huge

    for _, target in pairs(potential_targets_map) do
        local target_dis = target.data.verified_dis or target.data.dis or math.huge
        local is_self_defense = target_dis <= CONSTANTS.RESCUE_GUARD_SELF_DEFENSE_RANGE

        if _is_attention_in_rescue_area(objective, target.data) or is_self_defense then
            local flags = EnemyClassifier.classify(target.data.unit, target.data)
            local tier = flags.spooc_attack and 3 or flags.cloaker and 2 or 1
            local score = target.score or 0

            if tier > best_tier or tier == best_tier and score > best_score then
                best = target
                best_tier = tier
                best_score = score
            end
        end
    end

    return best, true
end

function RescueCoordinator.reset_level_state()
    local group_state = _get_group_state()
    for _, session in pairs(RescueCoordinator._sessions) do
        if session.guard_so_id and group_state then
            group_state:remove_special_objective(session.guard_so_id)
        end
    end

    RescueCoordinator._sessions = {}
    RescueCoordinator._next_update_t = 0
end

BB.RescueCoordinator = RescueCoordinator
