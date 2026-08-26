local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local EnemyClassifier = BB.EnemyClassifier
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local CoopCacheManager = BB.CoopCacheManager
local HoldPosition = BB.HoldPosition
local MarkingSystem = BB.MarkingSystem
local RescueCoordinator = BB.RescueCoordinator

local clamp = Utils.clamp
local game_time = Utils.game_time
local are_units_foes = UnitOps.are_foes
local play_net_redirect = UnitOps.play_redirect
local is_surrendering = UnitOps.is_surrendering
local get_unit_health_ratio = UnitOps.health_ratio

local SLOTS = BB.SLOTS
local CombatHelper = BB.CombatHelper

local CombatBehavior = {}

local function _update_target_lock(data, new_u_key, old_u_key, t)
    data._last_target_u_key = tostring(new_u_key)
    data._last_target_t = t
    if old_u_key ~= data._last_target_u_key then
        data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
    end
end

local function _attention_is_selectable(attention_data, t)
    if attention_data.pause_expire_t then
        if t > attention_data.pause_expire_t then
            attention_data.pause_expire_t = nil
        end
        return false
    end

    if attention_data.stare_expire_t and t > attention_data.stare_expire_t then
        local pause = attention_data.settings and attention_data.settings.pause
        if pause then
            attention_data.stare_expire_t = nil
            attention_data.pause_expire_t = t + math.lerp(pause[1], pause[2], math.random())
        end
        return false
    end

    return true
end

local function _resolve_reaction(data, attention_data, reaction_func)
    reaction_func = reaction_func or TeamAILogicBase._chk_reaction_to_attention_object

    return reaction_func(data, attention_data, not CopLogicAttack._can_move(data))
end

local function _get_coop_visibility(attention_data, t)
    local grace = CONSTANTS.COOP_RECENT_VERIFY_GRACE

    if attention_data.verified then
        return true,
                1,
                t + grace,
                attention_data.m_head_pos or attention_data.verified_pos,
                "verified"
    end

    if attention_data.nearly_visible then
        return true,
                CONSTANTS.COOP_NEARLY_VISIBLE_FACTOR,
                t + grace,
                attention_data.m_head_pos
                        or attention_data.last_verified_pos
                        or attention_data.verified_pos,
                "nearly_visible"
    end

    local verified_t = attention_data.verified_t
    if type(verified_t) == "number" and t - verified_t <= grace then
        return true,
                CONSTANTS.COOP_RECENT_VISIBLE_FACTOR,
                verified_t + grace,
                attention_data.last_verified_pos or attention_data.verified_pos,
                "recently_verified"
    end

    return false, 0, 0, nil, "stale"
end

local function _get_weapon_range(data, unit)
    local internal_data = data and data.internal_data
    if internal_data and internal_data.weapon_range then
        return internal_data.weapon_range
    end

    local inventory = alive(unit) and unit:inventory()
    local weapon_unit = inventory and inventory:equipped_unit()
    local weapon_base = alive(weapon_unit) and weapon_unit:base()
    local weapon_tweak = weapon_base
            and weapon_base.weapon_tweak_data
            and weapon_base:weapon_tweak_data()
    local usage = weapon_tweak and weapon_tweak.usage
    local weapon_data = data
            and data.char_tweak
            and data.char_tweak.weapon
            and usage
            and data.char_tweak.weapon[usage]

    return weapon_data and weapon_data.range or nil
end

local function _weapon_range_factor(data, unit, distance)
    local range = _get_weapon_range(data, unit)
    if not range then
        return 1
    end

    local optimal = range.optimal or range.close or range.far
    local far = range.far or optimal
    if not (optimal and far and far > 0) or distance <= optimal then
        return 1
    end

    if far > optimal and distance <= far then
        local progress = (distance - optimal) / (far - optimal)
        return math.lerp(1, 0.7, progress)
    end

    return clamp((far / math.max(distance, 1)) * 0.7, 0.25, 0.7)
end

local function _native_priority_slot(data, attention_data, flags, distance, reaction, t, unit)
    local alert_dt = attention_data.alert_t and t - attention_data.alert_t or 10000
    local damage_dt = attention_data.dmg_t and t - attention_data.dmg_t or 10000
    local mark_dt = attention_data.mark_t and t - attention_data.mark_t or 10000
    local current_key = data.attention_obj and tostring(data.attention_obj.u_key)
    local target_key = tostring(attention_data.u_key or attention_data.unit:key())

    if current_key == target_key then
        alert_dt = alert_dt * 0.8
        damage_dt = damage_dt * 0.8
        mark_dt = mark_dt * 0.8
        distance = distance * 0.8
    end

    local contour = attention_data.unit:contour()
    local been_marked = mark_dt < 8 or contour and MarkingSystem.has_mark_contour(contour)
    local near = distance < 800
    local has_alerted = alert_dt < 5
    local has_damaged = damage_dt < 2
    local shielded = flags.shield
            and not CombatHelper.has_ap_ammo(unit)
            and CombatHelper.shield_blocks_default(unit, attention_data.m_head_pos)
            or false
    local priority_slot

    if attention_data.verified then
        priority_slot = (attention_data.is_very_dangerous or been_marked)
                and distance < 1600 and 1
                or near and (has_alerted and has_damaged
                        or been_marked
                        or flags.shield and not shielded) and 2
                or near and has_alerted and 3
                or has_alerted and 4
                or 5

        if shielded then
            priority_slot = math.min(5, priority_slot + 1)
        end
    else
        priority_slot = has_alerted and 6 or 7
    end

    if reaction < AIAttentionObject.REACT_COMBAT then
        priority_slot = 10 + priority_slot
                + math.max(0, AIAttentionObject.REACT_COMBAT - reaction)
    end

    return priority_slot
end

local function _filter_potential_targets(
        unit,
        data,
        attention_objects,
        reaction_func,
        t,
        coop_requested
)
    local ThreatAssessment = BB.ThreatAssessment
    local IntimidationSystem = BB.IntimidationSystem

    local old_target_u_key = data._last_target_u_key and tostring(data._last_target_u_key)
    local last_target_t = data._last_target_t or 0
    local my_head = unit:movement():m_head_pos()

    local force_unlock = false
    local potential_targets_map = {}

    for u_key, attention_data in pairs(attention_objects) do
        local u_key_str = tostring(u_key)
        if attention_data.identified
                and alive(attention_data.unit)
                and _attention_is_selectable(attention_data, t)
        then
            local reaction = _resolve_reaction(data, attention_data, reaction_func)
            local coop_eligible, visibility_factor, valid_until, target_pos, visibility_state =
                    _get_coop_visibility(attention_data, t)
            target_pos = target_pos
                    or attention_data.m_head_pos
                    or attention_data.verified_pos
            local dist = target_pos and mvector3.distance(my_head, target_pos)
                    or attention_data.verified_dis
                    or attention_data.dis

            coop_eligible = coop_requested
                    and coop_eligible
                    and are_units_foes(unit, attention_data.unit)
                    or false

            if reaction
                    and reaction >= AIAttentionObject.REACT_COMBAT
                    and dist
                    and dist > 0
            then
                local dom_t0 = BB.cops_to_intimidate[u_key_str]
                local dom_active = dom_t0 and (t - dom_t0 < BB.grace_period)

                if dom_active then
                    if not IntimidationSystem.is_valid_target(attention_data.unit, data, dist, false) then
                        dom_active = false
                    end
                end

                local is_in_surrender_state = is_surrendering(attention_data.unit)

                if not dom_active and not is_in_surrender_state then
                    local threat = ThreatAssessment.calculate_threat_value(
                            unit,
                            attention_data,
                            data,
                            dist,
                            target_pos
                    )

                    local flags = BB.classify_enemy(attention_data.unit, attention_data)
                    local urgency = 1
                    if flags.tasing then
                        threat = threat * CONSTANTS.TASING_THREAT_MUL
                        force_unlock = true
                        urgency = 3
                    end
                    if flags.spooc_attack then
                        threat = threat * CONSTANTS.SPOOC_THREAT_MUL
                        if attention_data.verified_dis and attention_data.verified_dis < CONSTANTS.SPOOC_CLOSE_RANGE then
                            threat = threat * CONSTANTS.SPOOC_CLOSE_MUL
                        end
                        force_unlock = true
                        urgency = 3
                    end

                    if not coop_requested
                            and old_target_u_key
                            and old_target_u_key == u_key_str
                            and (t - last_target_t) <= CONSTANTS.TARGET_SWITCH_DELAY
                            and not flags.turret
                    then
                        threat = threat * CONSTANTS.TARGET_STICKINESS_MUL
                    end

                    local priority_slot = _native_priority_slot(
                            data,
                            attention_data,
                            flags,
                            dist,
                            reaction,
                            t,
                            unit
                    )
                    local dynamic_priority = 0
                    local state = "normal"
                    local suitability = 0
                    local coop_score = 0

                    if coop_eligible then
                        dynamic_priority, state = BB.CoopSystem.compute_dynamic_priority(
                                unit,
                                attention_data,
                                data,
                                target_pos,
                                dist
                        )
                        suitability = ThreatAssessment.calculate_suitability(
                                unit,
                                attention_data,
                                target_pos,
                                dist
                        )

                        if urgency < 3
                                and (state == "dozer_facing"
                                or attention_data.is_very_dangerous and dist < 1600)
                        then
                            urgency = 2
                        end

                        local native_score = math.max(8 - priority_slot, 0) * 8000
                        local reaction_score = math.max(
                                reaction - AIAttentionObject.REACT_COMBAT,
                                0
                        ) * 4000
                        local continuous_score = threat * 120
                                + math.max(suitability, 0) * 25
                                + math.max(dynamic_priority, 0) * 250
                        coop_score = (native_score + reaction_score + continuous_score)
                                * visibility_factor
                                * _weapon_range_factor(data, unit, dist)
                    end

                    local durable = flags.turret
                            or flags.dozer and get_unit_health_ratio(attention_data.unit) > 0.3
                    local focus = urgency >= 3 and "urgent"
                            or durable and "durable"
                            or nil

                    potential_targets_map[u_key_str] = {
                        data = attention_data,
                        score = threat,
                        coop_score = coop_score,
                        coop_eligible = coop_eligible,
                        priority_slot = priority_slot,
                        reaction = reaction,
                        urgency = urgency,
                        focus = focus,
                        durable = durable,
                        state = state,
                        target_pos = target_pos,
                        valid_until = valid_until,
                        visibility_state = visibility_state,
                    }
                end
            end
        end
    end

    return potential_targets_map, force_unlock
end

local function _select_solo_target(data, potential_targets_map, old_target_u_key, t)
    local best_local_target
    local max_score = 0

    for _, target in pairs(potential_targets_map) do
        if target.score > max_score then
            max_score = target.score
            best_local_target = target
        end
    end

    if best_local_target then
        _update_target_lock(data, best_local_target.data.u_key, old_target_u_key, t)
        return best_local_target.data, 500 / math.max(max_score, 1), best_local_target.reaction
    end

    return nil, nil, nil
end

local function _select_coop_target(data, potential_targets_map, old_target_u_key, my_key_str, t)
    local assignment_snapshot = BB.CoopSystem.get_assignment_snapshot()
    local assigned_target_key = assignment_snapshot.by_bot[my_key_str]
    local assigned_local_target = assigned_target_key and potential_targets_map[assigned_target_key]

    if assigned_local_target
            and assigned_local_target.coop_eligible
            and alive(assigned_local_target.data.unit)
    then
        _update_target_lock(data, assigned_local_target.data.u_key, old_target_u_key, t)
        return assigned_local_target.data,
                assigned_local_target.priority_slot,
                assigned_local_target.reaction
    end

    if assigned_target_key then
        BB.CoopSystem.note_local_fallback()
    end

    local best_target
    local best_utility = -math.huge
    local best_key
    for target_key, candidate in pairs(potential_targets_map) do
        if candidate.coop_eligible and alive(candidate.data.unit) then
            local utility = BB.CoopSystem.get_local_target_utility(
                    my_key_str,
                    target_key,
                    candidate
            )
            if utility > best_utility
                    or utility == best_utility
                    and (not best_key or tostring(target_key) < tostring(best_key))
            then
                best_target = candidate
                best_utility = utility
                best_key = target_key
            end
        end
    end

    if not best_target then
        return nil, nil, nil
    end

    BB.CoopSystem.note_local_fallback()
    _update_target_lock(data, best_target.data.u_key, old_target_u_key, t)
    return best_target.data, best_target.priority_slot, best_target.reaction
end

function CombatBehavior.find_priority_attention(data, attention_objects, reaction_func)
    local unit = data.unit
    local t = data.t or game_time()
    local is_team_ai_unit = BB.UnitOps.is_team_ai(unit)
    local coop_requested = BB:get("coop", false) and is_team_ai_unit
    local teammate_status = coop_requested
            and BB.CoopSystem.update_teammate_status(unit, data)
            or nil
    local coop_active = teammate_status and teammate_status.can_fight or false

    local old_target_u_key = data._last_target_u_key and tostring(data._last_target_u_key)
    local my_key_str = tostring(data.key)

    local potential_targets_map, force_unlock = _filter_potential_targets(
            unit,
            data,
            attention_objects,
            reaction_func,
            t,
            coop_requested
    )

    local role_target, restrict_to_role = RescueCoordinator.select_role_target(
            data,
            potential_targets_map
    )

    if coop_requested then
        BB.CoopSystem.scan_and_update_priorities(data, potential_targets_map, {
            restricted = restrict_to_role,
            target_key = role_target
                    and tostring(role_target.data.u_key or role_target.data.unit:key())
                    or nil,
        })
    end

    if role_target then
        _update_target_lock(data, role_target.data.u_key, old_target_u_key, t)
        return role_target.data,
                role_target.priority_slot,
                role_target.reaction
    elseif restrict_to_role then
        return nil, nil, nil
    end

    local lock_active = data._target_lock_until and (t < data._target_lock_until)
    if lock_active and coop_active then
        local assigned_target_key = BB.CoopSystem.get_assigned_target(my_key_str)
        if old_target_u_key and assigned_target_key ~= old_target_u_key then
            lock_active = false
        end
    end

    local locked_target = old_target_u_key and potential_targets_map[old_target_u_key]
    if lock_active
            and not force_unlock
            and locked_target
            and (not coop_active or locked_target.coop_eligible)
    then
        local locked = locked_target
        data._last_target_u_key = tostring(locked.data.u_key)
        data._last_target_t = t
        return locked.data,
                coop_active and locked.priority_slot
                        or 400 / math.max(locked.score or 1, 1),
                locked.reaction
    end

    if not coop_active then
        return _select_solo_target(data, potential_targets_map, old_target_u_key, t)
    end

    return _select_coop_target(data, potential_targets_map, old_target_u_key, my_key_str, t)
end

local function _is_enemy_actively_firing(enemy_unit, my_unit)
    if not alive(enemy_unit) then
        return false, false
    end

    local enemy_brain = enemy_unit:brain()
    if not enemy_brain then
        return false, false
    end

    local logic_data = enemy_brain._logic_data
    if not logic_data then
        return false, false
    end

    local internal_data = logic_data.internal_data
    local is_firing = internal_data and (internal_data.firing or internal_data.shooting)

    local is_targeting_me = false
    if is_firing and logic_data.attention_obj then
        local att_obj = logic_data.attention_obj
        if att_obj.unit and alive(att_obj.unit) then
            if att_obj.unit == my_unit then
                is_targeting_me = true
            elseif alive(my_unit) and my_unit:movement() then
                local my_pos = my_unit:movement():m_head_pos()
                local att_pos = att_obj.m_head_pos or (att_obj.unit:movement() and att_obj.unit:movement():m_head_pos())
                if my_pos and att_pos and mvector3.distance(my_pos, att_pos) < 500 then
                    is_targeting_me = true
                end
            end
        end
    end

    return is_firing, is_targeting_me
end

local function _scan_nearby_threats(data, unit)
    local result = {
        nearby = 0,
        active = 0,
        closest_dis = math.huge,
        closest_active_dis = math.huge,
        active_enemy = nil,
    }

    local unit_movement = unit:movement()
    local attention = unit_movement:attention()
    if attention and attention.unit then
        result.active_enemy = attention.unit
    end

    for _, u_char in pairs(data.detected_attention_objects) do
        if u_char.identified and u_char.verified and alive(u_char.unit) and are_units_foes(unit, u_char.unit) then
            result.nearby = result.nearby + 1
            local dis = u_char.verified_dis or math.huge
            if dis < result.closest_dis then
                result.closest_dis = dis
            end

            local is_firing, is_targeting_me = _is_enemy_actively_firing(u_char.unit, unit)
            if is_firing then
                result.active = result.active + 1
                if is_targeting_me and dis < result.closest_active_dis then
                    result.closest_active_dis = dis
                end
            end
        end
    end

    return result
end

local function _should_suppress_reload(clip_ammo, threats, pressure, active_enemy, unit, anim)
    if clip_ammo <= 0 then
        return false
    end

    if threats.active > 0 and threats.closest_active_dis < CONSTANTS.RELOAD_ACTIVE_CLOSE_DIST then
        return true
    end
    if threats.closest_dis < CONSTANTS.RELOAD_THREAT_CLOSE_DIST then
        return true
    end
    if pressure > CONSTANTS.RELOAD_HIGH_PRESSURE then
        return true
    end

    if active_enemy and alive(active_enemy) then
        local is_dangerous = EnemyClassifier.is_dozer(active_enemy)
                or EnemyClassifier.is_taser(active_enemy)
                or EnemyClassifier.is_cloaker(active_enemy)
        local is_firing, is_targeting_me = _is_enemy_actively_firing(active_enemy, unit)

        if is_dangerous and is_firing and threats.closest_dis < CONSTANTS.RELOAD_DANGEROUS_SPECIAL_DIST then
            return true
        end
        if anim and anim.fire and is_targeting_me and threats.closest_dis < CONSTANTS.RELOAD_FIRING_AT_ME_DIST then
            return true
        end
    end

    return false
end

local function _calculate_reload_threshold(threats, unit, data)
    local threshold = CONSTANTS.RELOAD_BASE

    if threats.nearby == 0 then
        threshold = CONSTANTS.RELOAD_NO_THREATS
    elseif threats.active == 0 then
        threshold = CONSTANTS.RELOAD_NO_ACTIVE
    elseif threats.closest_dis > 2000 then
        threshold = CONSTANTS.RELOAD_FAR
    elseif threats.closest_dis > 1200 then
        threshold = CONSTANTS.RELOAD_MID
    elseif threats.closest_dis > 600 then
        threshold = CONSTANTS.RELOAD_CLOSE
    end

    if BB:get("coop", false) then
        threshold = BB.CoopSystem.get_pressure_adjusted_reload_threshold(unit, data, threshold)
    end

    return threshold
end

function CombatBehavior.check_smart_reload(data)
    local unit = data.unit
    if not alive(unit) then return end

    local unit_movement = unit:movement()
    local anim = unit:anim_data()
    if unit_movement:chk_action_forbidden("action") or (anim and anim.reload) then
        return
    end

    local current_wep = unit:inventory():equipped_unit()
    local wep_base = current_wep and current_wep:base()
    if not wep_base then return end

    local clip_max, clip_ammo, reserve_total, _ = wep_base:ammo_info()
    if not (clip_max and clip_max > 0) then return end
    if clip_ammo >= clip_max then return end
    if (reserve_total or 0) <= 0 then return end

    if clip_ammo > 0 and BB:get("coop", false) then
        local teammates_reloading = BB.CoopSystem.get_reloading_teammates_count(unit:key())
        if teammates_reloading >= CONSTANTS.MAX_RELOADING_TEAMMATES then
            return
        end
    end

    local pressure = BB:get("coop", false) and BB.CoopSystem.calculate_team_pressure(unit, data) or 0
    local threats = _scan_nearby_threats(data, unit)

    if _should_suppress_reload(clip_ammo, threats, pressure, threats.active_enemy, unit, anim) then
        return
    end

    local reload_threshold = _calculate_reload_threshold(threats, unit, data)

    local is_empty = clip_ammo == 0
    local is_low_capacity = clip_max <= CONSTANTS.RELOAD_LOW_CAP_THRESHOLD

    if is_low_capacity and reload_threshold > CONSTANTS.RELOAD_LOW_CAP_TACTICAL_MAX then
        reload_threshold = reload_threshold * CONSTANTS.RELOAD_LOW_CAP_MUL
    end

    local threshold_ammo = clip_max * reload_threshold
    local threshold_val = is_low_capacity and math.floor(threshold_ammo) or math.ceil(threshold_ammo)
    local want_tactical_reload = clip_ammo <= threshold_val

    if not is_empty and not want_tactical_reload then
        return
    end

    local brain = unit:brain()
    if not is_empty and threats.active > 0 then
        local objective = data.objective
        local in_cover = objective and objective.in_place
        if not in_cover and threats.closest_active_dis < CONSTANTS.RELOAD_NOT_IN_COVER_DIST then
            return
        end
    end

    HoldPosition:prepare_reload_pose(data)

    brain:action_request({ type = "reload", body_part = 3 })
end

function CombatBehavior.execute_melee_attack(data, criminal)
    if not alive(criminal) then
        return
    end

    local current_wep = criminal:inventory():equipped_unit()
    local crim_mov = criminal:movement()

    local my_pos = crim_mov:m_head_pos()
    local look_vec = crim_mov:m_rot():y()

    local current_ammo_ratio = 1
    if current_wep and current_wep:base() then
        local ammo_max, ammo = current_wep:base():ammo_info()
        if ammo_max and ammo_max > 0 then
            current_ammo_ratio = ammo / ammo_max
        end
    end

    if current_ammo_ratio > 0.5 then
        return
    end

    local best_melee_target
    local best_melee_priority = 0

    for _, u_char in pairs(data.detected_attention_objects) do
        if u_char.identified
                and alive(u_char.unit)
                and are_units_foes(criminal, u_char.unit)
        then
            if u_char.verified
                    and u_char.verified_dis
                    and u_char.verified_dis <= CONSTANTS.MELEE_DISTANCE
            then
                local unit_pos = u_char.m_head_pos
                if unit_pos then
                    local vec = unit_pos - my_pos
                    if mvector3.angle(vec, look_vec) <= CONSTANTS.MELEE_ANGLE then
                        local melee_priority = 0

                        if EnemyClassifier.is_shield(u_char.unit, u_char) then
                            melee_priority = 10
                        elseif not EnemyClassifier.is_special(u_char.unit, u_char) then
                            local unit = u_char.unit
                            local unit_inventory = unit:inventory()
                            local unit_anim = unit:anim_data()
                            if unit_inventory
                                    and unit_inventory:get_weapon()
                                    and unit_anim
                                    and not unit_anim.hurt
                            then
                                melee_priority = 5
                            end
                        end

                        if melee_priority > best_melee_priority then
                            best_melee_priority = melee_priority
                            best_melee_target = u_char
                        end
                    end
                end
            end
        end
    end

    if not best_melee_target then
        return
    end

    local unit = best_melee_target.unit
    local damage = unit:character_damage()
    if not (damage and damage._HEALTH_INIT) then
        return
    end

    local health_damage = math.ceil(damage._HEALTH_INIT / 2)
    local vec = best_melee_target.m_head_pos - my_pos
    local unit_body = unit:body("body")
    if not unit_body then
        return
    end

    local col_ray = {
        ray = vec,
        body = unit_body,
        position = best_melee_target.m_head_pos,
    }

    local target_is_shield = EnemyClassifier.is_shield(unit, best_melee_target)
    local damage_info = {
        attacker_unit = criminal,
        weapon_unit = current_wep,
        variant = target_is_shield and "melee" or "bullet",
        damage = target_is_shield and 0 or health_damage,
        col_ray = col_ray,
        origin = my_pos,
    }

    if target_is_shield then
        damage_info.damage_effect = 1
        damage_info.shield_knock = true
        damage:damage_melee(damage_info)
    else
        damage_info.knock_down = true
        damage:damage_bullet(damage_info)
    end

    play_net_redirect(criminal, "melee")
end

function CombatBehavior.throw_concussion_grenade(data, criminal)
    return BB.ConcussionSystem.throw(data, criminal)
end

CombatBehavior.evaluate_coop_visibility = _get_coop_visibility
CombatBehavior.is_attention_selectable = _attention_is_selectable
CombatBehavior.resolve_attention_reaction = _resolve_reaction

BB.CombatBehavior = CombatBehavior
