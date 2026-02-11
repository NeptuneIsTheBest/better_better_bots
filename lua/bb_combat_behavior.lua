local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local EnemyClassifier = BB.EnemyClassifier
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local CoopCacheManager = BB.CoopCacheManager

local clamp = Utils.clamp
local game_time = Utils.game_time
local safe_call = Utils.safe_call
local are_units_foes = UnitOps.are_foes
local safe_say = UnitOps.say
local request_act = UnitOps.request_act
local play_net_redirect = UnitOps.play_redirect
local get_unit_health_ratio = UnitOps.health_ratio
local is_surrendering = UnitOps.is_surrendering

local SLOTS = BB.SLOTS
local CombatHelper = BB.CombatHelper

local CombatBehavior = {}

local function _update_dozer_tracking(my_key_str, target_u_key, is_dozer, is_turret)
    if is_dozer and not is_turret then
        BB.coop_data.dozer_attackers[my_key_str] = tostring(target_u_key)
    else
        BB.coop_data.dozer_attackers[my_key_str] = nil
    end
end

local function _update_target_lock(data, new_u_key, old_u_key, t)
    data._last_target_u_key = tostring(new_u_key)
    data._last_target_t = t
    if old_u_key ~= data._last_target_u_key then
        data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
    end
end

local function _filter_potential_targets(unit, data, attention_objects, t)
    local ThreatAssessment = BB.ThreatAssessment
    local IntimidationSystem = BB.IntimidationSystem
    local THREAT_WEIGHTS = BB.THREAT_WEIGHTS

    local old_target_u_key = data._last_target_u_key and tostring(data._last_target_u_key)
    local last_target_t = data._last_target_t or 0

    local force_unlock = false
    local potential_targets_map = {}

    for u_key, attention_data in pairs(attention_objects or {}) do
        local u_key_str = tostring(u_key)
        if attention_data.identified
                and alive(attention_data.unit)
                and attention_data.reaction >= AIAttentionObject.REACT_COMBAT
        then
            local dist = attention_data.verified_dis
            if dist and dist > 0 then
                local dom_t0 = BB.cops_to_intimidate[u_key_str]
                local dom_active = dom_t0 and (t - dom_t0 < BB.grace_period)

                if dom_active and IntimidationSystem.is_valid_target then
                    if not IntimidationSystem.is_valid_target(attention_data.unit, data, dist, false) then
                        dom_active = false
                    end
                end

                local is_in_surrender_state = is_surrendering(attention_data.unit)

                if not dom_active and not is_in_surrender_state then
                    local threat = ThreatAssessment.calculate_threat_value(unit, attention_data, data)

                    local flags = BB.classify_enemy(attention_data.unit, attention_data)
                    if flags.tasing then
                        threat = threat * CONSTANTS.TASING_THREAT_MUL
                        BB.CoopSystem.mark_dangerous_special(attention_data.unit, unit)
                        force_unlock = true
                    end
                    if flags.spooc_attack then
                        threat = threat * CONSTANTS.SPOOC_THREAT_MUL
                        if attention_data.verified_dis and attention_data.verified_dis < CONSTANTS.SPOOC_CLOSE_RANGE then
                            threat = threat * CONSTANTS.SPOOC_CLOSE_MUL
                        end
                        BB.CoopSystem.mark_dangerous_special(attention_data.unit, unit)
                        force_unlock = true
                    end

                    if old_target_u_key
                            and old_target_u_key == u_key_str
                            and (t - last_target_t) <= CONSTANTS.TARGET_SWITCH_DELAY
                            and not flags.turret
                    then
                        threat = threat * CONSTANTS.TARGET_STICKINESS_MUL
                    end

                    potential_targets_map[u_key_str] = {
                        data = attention_data,
                        score = threat,
                        reaction = attention_data.reaction,
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

local function _select_coop_target(unit, data, potential_targets_map, old_target_u_key, my_key_str, t)
    local ThreatAssessment = BB.ThreatAssessment
    local THREAT_WEIGHTS = BB.THREAT_WEIGHTS

    local global_priority_targets = BB.CoopSystem.get_priority_targets()
    local best_coop_target
    local best_coop_score = -1

    for u_key, global_target in pairs(global_priority_targets) do
        local local_target_info = potential_targets_map[u_key]
        if local_target_info then
            local dynamic_prio = global_target.priority
            if global_target.state == "tasing_teammate" then
                dynamic_prio = dynamic_prio * 3
            end

            local target_unit = global_target.unit
            local flags = EnemyClassifier.classify(target_unit)
            local is_turret = flags.turret
            local is_dozer = flags.dozer
            local is_cloaker = flags.cloaker
            local is_taser = flags.taser

            if is_dozer and not is_turret then
                dynamic_prio = dynamic_prio * BB.CoopSystem.calculate_dozer_penalty(u_key, my_key_str)
            end

            local claimed_penalty = 1
            if not is_dozer and not is_turret and not is_cloaker and not is_taser
                    and global_target.targeted_by
                    and tostring(global_target.targeted_by) ~= my_key_str
            then
                claimed_penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
            end

            local suitability = ThreatAssessment.calculate_suitability(unit, local_target_info.data)

            local is_special = EnemyClassifier.is_special(local_target_info.data.unit)

            if BB.CoopSystem.is_my_assigned_target(u_key, data.key) then
                suitability = suitability + CONSTANTS.ASSIGNED_TARGET_BONUS
            else
                local target_owner = BB.CoopSystem.get_target_owner(u_key)
                local is_high_threat = is_dozer or is_turret or is_taser or is_cloaker

                if not is_high_threat then
                    if not target_owner then
                        suitability = suitability + CONSTANTS.UNASSIGNED_TARGET_BONUS
                    elseif target_owner ~= my_key_str then
                        suitability = suitability * CONSTANTS.OTHER_ASSIGNMENT_PENALTY
                    end
                end
            end

            if is_special then
                 suitability = suitability + THREAT_WEIGHTS.DIRECTION_BONUS
            end

            local final_score = dynamic_prio * suitability * claimed_penalty
            if final_score > best_coop_score then
                best_coop_target = global_target
                best_coop_score = final_score
            end
        end
    end

    if best_coop_target then
        best_coop_target.targeted_by = my_key_str
        best_coop_target.claimed_at = t

        local target_unit = best_coop_target.unit
        local post_flags = EnemyClassifier.classify(target_unit)
        _update_dozer_tracking(my_key_str, best_coop_target.u_key, post_flags.dozer, post_flags.turret)

        local local_data = potential_targets_map[tostring(best_coop_target.u_key)]
                or potential_targets_map[tostring(best_coop_target.unit and best_coop_target.unit:key() or "")]
        if not local_data then
            return nil, nil, nil
        end
        _update_target_lock(data, best_coop_target.u_key, old_target_u_key, t)

        return local_data.data, 300 / math.max(best_coop_score, 1), local_data.reaction
    end

    local best_local_target
    local max_score = 0

    for u_key, target in pairs(potential_targets_map) do
        local g = global_priority_targets[u_key]
        local target_unit = target.data.unit
        local fb_flags = EnemyClassifier.classify(target_unit)
        local is_turret = fb_flags.turret
        local is_dozer = fb_flags.dozer
        local is_cloaker = fb_flags.cloaker
        local is_taser = fb_flags.taser

        local penalty = 1
        if g and g.targeted_by and tostring(g.targeted_by) ~= my_key_str then
            if is_dozer and not is_turret then
                penalty = penalty * BB.CoopSystem.calculate_dozer_penalty(u_key, my_key_str)
            elseif not is_turret and not is_cloaker and not is_taser then
                penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
            end
        end

        local effective = target.score * penalty
        if effective > max_score then
            max_score = effective
            best_local_target = target
        end
    end

    if best_local_target then
        local target_unit = best_local_target.data.unit
        local post_fb_flags = EnemyClassifier.classify(target_unit)
        _update_dozer_tracking(my_key_str, best_local_target.data.u_key, post_fb_flags.dozer, post_fb_flags.turret)
        _update_target_lock(data, best_local_target.data.u_key, old_target_u_key, t)

        return best_local_target.data, 500 / math.max(max_score, 1), best_local_target.reaction
    end

    BB.coop_data.dozer_attackers[my_key_str] = nil
    return nil, nil, nil
end

function CombatBehavior.find_priority_attention(data, attention_objects, reaction_func)
    local unit = data.unit
    if not (alive(unit) and unit:movement()) then
        return
    end

    local t = data.t or game_time()
    local is_team_ai_unit = BB.UnitOps.is_team_ai(unit)

    if BB:get("coop", false) and is_team_ai_unit then
        BB.CoopSystem.update_teammate_status(unit)
        safe_call(BB.CoopSystem.scan_and_update_priorities, data)
    end

    local old_target_u_key = data._last_target_u_key and tostring(data._last_target_u_key)
    local my_key_str = tostring(data.key)

    local potential_targets_map, force_unlock = _filter_potential_targets(unit, data, attention_objects, t)

    local lock_active = data._target_lock_until and (t < data._target_lock_until)

    if lock_active and not force_unlock and old_target_u_key and potential_targets_map[old_target_u_key] then
        local locked = potential_targets_map[old_target_u_key]
        data._last_target_u_key = tostring(locked.data.u_key)
        data._last_target_t = t
        return locked.data, 400 / math.max(locked.score or 1, 1), locked.reaction
    end

    if not BB:get("coop", false) then
        return _select_solo_target(data, potential_targets_map, old_target_u_key, t)
    end

    return _select_coop_target(unit, data, potential_targets_map, old_target_u_key, my_key_str, t)
end



function CombatBehavior.find_enemy_to_mark(enemies, my_unit)
    if not alive(my_unit) then
        return
    end

    local unit_movement = my_unit:movement()
    local player_manager = managers.player
    local contour_id = player_manager:get_contour_for_marked_enemy()
    local has_ap = CombatHelper.has_ap_ammo()

    local my_head = unit_movement:m_head_pos()
    local best_unit
    local best_score

    for _, attention_info in pairs(enemies or {}) do
        if attention_info.identified and (attention_info.verified or attention_info.nearly_visible) then
            local att_unit = attention_info.unit
            if alive(att_unit) then
                local reaction = attention_info.reaction or AIAttentionObject.REACT_IDLE
                if reaction >= AIAttentionObject.REACT_COMBAT then
                    local flags = BB.classify_enemy(att_unit, attention_info)
                    local is_special = flags.special or flags.turret

                    if is_special then
                        local target_head = attention_info.m_head_pos
                                or (att_unit:movement() and att_unit:movement():m_head_pos())
                        local dis = attention_info.verified_dis
                                or (target_head and mvector3.distance(my_head, target_head))

                        if dis and dis <= CONSTANTS.MARK_DISTANCE then
                            local u_contour = att_unit:contour()
                            local already_marked = u_contour
                                    and (u_contour:has_id(contour_id)
                                    or u_contour:has_id("mark_unit_dangerous")
                                    or u_contour:has_id("mark_enemy"))

                            if contour_id and contour_id ~= "" and u_contour and not already_marked then
                                local shield_blocked = target_head and CombatHelper.shield_blocks_default(my_unit, target_head)
                                local can_hit = has_ap
                                        or dis <= CONSTANTS.MELEE_DISTANCE
                                        or not shield_blocked

                                if (not flags.shield) or can_hit then
                                    local score = dis
                                    if attention_info.verified then
                                        score = score - CONSTANTS.MARK_VERIFIED_BONUS
                                    end
                                    if flags.shield then
                                        score = score - CONSTANTS.MARK_SHIELD_BONUS
                                    end

                                    if (not best_score) or score < best_score then
                                        best_score = score
                                        best_unit = att_unit
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best_unit
end

function CombatBehavior.mark_enemy(data, criminal, to_mark, play_sound, play_action)
    if not (alive(criminal) and alive(to_mark)) then
        return
    end

    local t = game_time()
    data._ai_last_mark_t = data._ai_last_mark_t or 0
    if t - data._ai_last_mark_t < CONSTANTS.MARK_COOLDOWN then
        return
    end

    local base = to_mark:base()
    local char_tweak = base and base.char_tweak and base:char_tweak() or nil
    local is_turret = EnemyClassifier.is_turret(to_mark)
    local is_special_enemy = EnemyClassifier.is_special(to_mark)

    if not is_special_enemy and not is_turret then
        return
    end

    if play_sound then
        local sound_name = is_turret and "f44" or (char_tweak and char_tweak.priority_shout)
        if sound_name then
            safe_say(criminal, tostring(sound_name) .. "x_any", true, true)
        end
    end

    if play_action then
        request_act(criminal, "arrest", data)
    end

    local contour = to_mark:contour()
    if contour then
        local prefer_id = managers.player:get_contour_for_marked_enemy()

        local c_id = is_turret and "mark_unit_dangerous" or prefer_id

        if c_id and not contour:has_id(c_id) then
            safe_call(contour.add, contour, c_id, true)
        end
    end

    data._ai_last_mark_t = t
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

    for _, u_char in pairs(data.detected_attention_objects or {}) do
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
    if unit_movement:chk_action_forbidden("reload") or (anim and anim.reload) then
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
    if not brain then return end

    if not is_empty and threats.active > 0 then
        local objective = data.objective
        local in_cover = objective and objective.in_place
        if not in_cover and threats.closest_active_dis < CONSTANTS.RELOAD_NOT_IN_COVER_DIST then
            return
        end
    end

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

    for _, u_char in pairs(data.detected_attention_objects or {}) do
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
        damage_info.shield_knock = true
        safe_call(damage.damage_melee, damage, damage_info)
    else
        damage_info.knock_down = true
        safe_call(damage.damage_bullet, damage, damage_info)
    end

    play_net_redirect(criminal, "melee")
end

function CombatBehavior.throw_concussion_grenade(data, criminal)
    local ConcussionSystem = BB.ConcussionSystem
    if ConcussionSystem then
        return ConcussionSystem.throw(data, criminal)
    end
    return false
end

BB.CombatBehavior = CombatBehavior
