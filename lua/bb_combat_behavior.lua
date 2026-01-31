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

local SLOTS = BB.SLOTS
local MASK = {
    enemy_shield_check = Utils.get_safe_mask("enemy_shield_check", 8),
}

local function shield_blocks(attacker, target_head_pos)
    return BB.CombatHelper.shield_blocks(attacker, target_head_pos, MASK.enemy_shield_check)
end

local CombatBehavior = {}

function CombatBehavior.get_priority_attention(data, attention_objects, reaction_func)
    local unit = data.unit
    if not (alive(unit) and unit:movement()) then
        return
    end

    local ThreatAssessment = BB.ThreatAssessment
    local IntimidationSystem = BB.IntimidationSystem
    local THREAT_WEIGHTS = BB.THREAT_WEIGHTS

    local t = data.t or game_time()
    local is_team_ai_unit = BB.UnitOps.is_team_ai(unit)

    if BB:get("coop", false) and is_team_ai_unit then
        BB.CoopSystem.update_teammate_status(unit)
        safe_call(BB.CoopSystem.scan_and_update_priorities, data)
    end

    local old_target_u_key = data._last_target_u_key
    local last_target_t = data._last_target_t or 0

    local potential_targets_map = {}
    for u_key, attention_data in pairs(attention_objects or {}) do
        if attention_data.identified
                and alive(attention_data.unit)
                and attention_data.reaction >= AIAttentionObject.REACT_COMBAT
        then
            local dist = attention_data.verified_dis
            if dist and dist > 0 then
                local dom_active = BB.cops_to_intimidate[u_key]
                        and (t - BB.cops_to_intimidate[u_key] < BB.grace_period)

                if dom_active and IntimidationSystem.is_valid_target then
                    if not IntimidationSystem.is_valid_target(attention_data.unit, data, dist, false) then
                        dom_active = false
                    end
                end

                if not dom_active then
                    local threat = ThreatAssessment.calculate_threat_value(unit, attention_data, data)

                    local flags = BB.classify_enemy(attention_data.unit, attention_data)
                    if flags.tasing then
                        threat = threat * 3.0
                        BB.CoopSystem.mark_dangerous_special(attention_data.unit, unit)
                    end
                    if flags.spooc_attack then
                        threat = threat * 3.5
                        if attention_data.verified_dis and attention_data.verified_dis < 1500 then
                            threat = threat * 1.5
                        end
                        BB.CoopSystem.mark_dangerous_special(attention_data.unit, unit)
                    end

                    if old_target_u_key
                            and old_target_u_key == u_key
                            and (t - last_target_t) <= CONSTANTS.TARGET_SWITCH_DELAY
                            and not flags.turret
                    then
                        threat = threat * 1.3
                    end

                    potential_targets_map[u_key] = {
                        data = attention_data,
                        score = threat,
                        reaction = attention_data.reaction,
                    }
                end
            end
        end
    end

    local lock_active = data._target_lock_until and (t < data._target_lock_until)

    if lock_active and old_target_u_key and potential_targets_map[old_target_u_key] then
        local locked = potential_targets_map[old_target_u_key]
        data._last_target_u_key = locked.data.u_key
        data._last_target_t = t
        return locked.data, 400 / math.max(locked.score or 1, 1), locked.reaction
    end

    if not BB:get("coop", false) then
        local best_local_target
        local max_score = 0

        for _, target in pairs(potential_targets_map) do
            if target.score > max_score then
                max_score = target.score
                best_local_target = target
            end
        end

        if best_local_target then
            data._last_target_u_key = best_local_target.data.u_key
            data._last_target_t = t

            if old_target_u_key ~= data._last_target_u_key then
                data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
            end

            return best_local_target.data, 500 / math.max(max_score, 1), best_local_target.reaction
        end

        return nil, nil, nil
    end

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
            local is_turret = EnemyClassifier.is_turret(target_unit)
            local is_dozer = EnemyClassifier.is_dozer(target_unit)

            if is_dozer and not is_turret then
                local current_attackers = BB.CoopSystem.count_dozer_attackers(u_key)
                local attacker_limit = BB.CoopSystem.get_dozer_attacker_limit(
                        global_target.unit,
                        local_target_info.data.verified_dis
                )

                if current_attackers >= attacker_limit then
                    local already_targeting = BB.coop_data.dozer_attackers[data.key] == u_key
                    if not already_targeting then
                        dynamic_prio = dynamic_prio * 0.3
                    end
                end
            end

            local claimed_penalty = 1
            if not is_dozer
                    and not is_turret
                    and global_target.targeted_by
                    and global_target.targeted_by ~= data.key
            then
                claimed_penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
            end

            local suitability = ThreatAssessment.calculate_suitability(unit, local_target_info.data)

            if BB.CoopSystem.is_assignment_enabled() then
                local is_special = EnemyClassifier.is_special(local_target_info.data.unit)

                if BB.CoopSystem.is_my_assigned_target(u_key, data.key) then
                    suitability = suitability + CONSTANTS.ASSIGNED_TARGET_BONUS
                else
                    local target_owner = BB.CoopSystem.get_target_owner(u_key)
                    local unit = local_target_info.data.unit
                    local is_high_threat = EnemyClassifier.is_dozer(unit)
                            or EnemyClassifier.is_turret(unit)
                            or EnemyClassifier.is_taser(unit)
                            or EnemyClassifier.is_cloaker(unit)

                    if not is_high_threat then
                        if not target_owner then
                            suitability = suitability + CONSTANTS.UNASSIGNED_TARGET_BONUS
                        elseif target_owner ~= data.key then
                            suitability = suitability * CONSTANTS.OTHER_ASSIGNMENT_PENALTY
                        end
                    end
                end

                if is_special then
                     suitability = suitability + THREAT_WEIGHTS.DIRECTION_BONUS
                end
            elseif not BB.CoopSystem.is_direction_covered(local_target_info.data.m_head_pos, unit) then
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
        best_coop_target.targeted_by = data.key
        best_coop_target.claimed_at = t

        local target_unit = best_coop_target.unit
        local is_turret = EnemyClassifier.is_turret(target_unit)
        local is_dozer = EnemyClassifier.is_dozer(target_unit)

        if is_dozer and not is_turret then
            BB.coop_data.dozer_attackers[data.key] = best_coop_target.u_key
        else
            BB.coop_data.dozer_attackers[data.key] = nil
        end

        local local_data = potential_targets_map[best_coop_target.u_key]
        data._last_target_u_key = best_coop_target.u_key
        data._last_target_t = t

        if old_target_u_key ~= data._last_target_u_key then
            data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
        end

        return local_data.data, 300 / math.max(best_coop_score, 1), local_data.reaction
    end

    local best_local_target
    local max_score = 0

    for u_key, target in pairs(potential_targets_map) do
        local g = global_priority_targets[u_key]
        local target_unit = target.data.unit
        local is_turret = EnemyClassifier.is_turret(target_unit)
        local is_dozer = EnemyClassifier.is_dozer(target_unit)

        local penalty = 1
        if g and g.targeted_by and g.targeted_by ~= data.key then
            if is_dozer and not is_turret then
                local current_attackers = BB.CoopSystem.count_dozer_attackers(u_key)
                local attacker_limit = BB.CoopSystem.get_dozer_attacker_limit(
                        target.data.unit,
                        target.data.verified_dis
                )
                if current_attackers >= attacker_limit then
                    penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
                end
            elseif not is_turret then
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
        local is_turret = EnemyClassifier.is_turret(target_unit)
        local is_dozer = EnemyClassifier.is_dozer(target_unit)

        if is_dozer and not is_turret then
            BB.coop_data.dozer_attackers[data.key] = best_local_target.data.u_key
        else
            BB.coop_data.dozer_attackers[data.key] = nil
        end

        data._last_target_u_key = best_local_target.data.u_key
        data._last_target_t = t

        if old_target_u_key ~= data._last_target_u_key then
            data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
        end

        return best_local_target.data, 500 / math.max(max_score, 1), best_local_target.reaction
    end

    BB.coop_data.dozer_attackers[data.key] = nil
    return nil, nil, nil
end



function CombatBehavior.find_enemy_to_mark(enemies, my_unit)
    if not alive(my_unit) then
        return
    end

    local unit_movement = my_unit:movement()
    local player_manager = managers.player
    local contour_id = player_manager:get_contour_for_marked_enemy()
    local has_ap = player_manager:has_category_upgrade("team", "crew_ai_ap_ammo")

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
                                local shield_blocked = target_head and shield_blocks(my_unit, target_head)
                                local can_hit = has_ap
                                        or dis <= CONSTANTS.MELEE_DISTANCE
                                        or not shield_blocked

                                if (not flags.shield) or can_hit then
                                    local score = dis
                                    if attention_info.verified then
                                        score = score - 150
                                    end
                                    if flags.shield then
                                        score = score - 200
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

    local char_tweak = to_mark:base():char_tweak()
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

        if not contour:has_id(c_id) then
            safe_call(contour.add, contour, c_id, true)
        end
    end

    data._ai_last_mark_t = t
end

function CombatBehavior.check_smart_reload(data)
    local unit = data.unit
    if not alive(unit) then return end

    local unit_movement = unit:movement()
    if unit_movement:chk_action_forbidden("reload") or unit:anim_data().reload then
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
        local teammates_reloading = CoopCacheManager.get_reloading_teammates_count
                and CoopCacheManager.get_reloading_teammates_count(unit:key())
                or BB.CoopSystem.get_reloading_teammates_count(unit:key())

        if teammates_reloading >= CONSTANTS.MAX_RELOADING_TEAMMATES then
            return
        end
    end

    local t = game_time()
    local pressure = 0
    if BB:get("coop", false) then
        pressure = BB.CoopSystem.calculate_team_pressure(unit, data)
    end

    local nearby_threats = 0
    local closest_threat_dis = math.huge
    local active_enemy = nil
    
    if unit_movement:attention() and unit_movement:attention().unit then
        active_enemy = unit_movement:attention().unit
    end

    for _, u_char in pairs(data.detected_attention_objects or {}) do
        if u_char.identified and u_char.verified and alive(u_char.unit) and are_units_foes(unit, u_char.unit) then
            nearby_threats = nearby_threats + 1
            if u_char.verified_dis and u_char.verified_dis < closest_threat_dis then
                closest_threat_dis = u_char.verified_dis
            end
        end
    end

    if clip_ammo > 0 and closest_threat_dis < 700 then
        return 
    end

    if clip_ammo > 0 and pressure > 0.75 then
        return
    end

    if clip_ammo > 0 and active_enemy and alive(active_enemy) then
        local is_dangerous_special = EnemyClassifier.is_dozer(active_enemy)
                or EnemyClassifier.is_taser(active_enemy)
                or EnemyClassifier.is_cloaker(active_enemy)
        if is_dangerous_special and closest_threat_dis < 1500 then
            return
        end
        
        if unit:anim_data().fire then
             return
        end
    end

    local reload_threshold = 0.1

    if nearby_threats == 0 then
        reload_threshold = 0.9
    elseif closest_threat_dis > 1500 then
        reload_threshold = 0.5
    elseif closest_threat_dis > 800 then
        reload_threshold = 0.2
    else
        reload_threshold = 0.05
    end

    if BB:get("coop", false) then
        reload_threshold = BB.CoopSystem.get_pressure_adjusted_reload_threshold(unit, data, reload_threshold)
    end

    local is_empty = clip_ammo == 0
    
    local want_tactical_reload = clip_ammo <= math.ceil(clip_max * reload_threshold)

    if is_empty or want_tactical_reload then
        local action_type = "reload"
        local brain = unit:brain()
        
        if not brain then return end

        if not is_empty then
            local objective = data.objective
            local in_cover = objective and objective.in_place
            
            if not in_cover and closest_threat_dis < 1200 then
                return
            end
        end

        brain:action_request({ type = "reload", body_part = 3 })
    end
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
        ray = -vec,
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
    if not (alive(criminal) and BB:get("conc", false)) then
        return false
    end

    local conc_tweak = tweak_data.blackmarket.projectiles.concussion
    
    local pkg_ready = managers.dyn_resource:is_resource_ready(
            Idstring("unit"),
            Idstring(conc_tweak.unit),
            managers.dyn_resource.DYN_RESOURCES_PACKAGE
    )
    if not pkg_ready then
        return false
    end

    local crim_mov = criminal:movement()
    if not crim_mov then
        return false
    end

    local from_pos = crim_mov:m_head_pos()
    local look_vec = crim_mov:m_rot():y()

    local close_enemies = 0
    local shield_count = 0
    local special_count = 0
    local enemy_cluster = {}

    for _, u_char in pairs(data.detected_attention_objects or {}) do
        if u_char.identified
                and u_char.verified
                and u_char.verified_dis
                and u_char.verified_dis <= CONSTANTS.CONC_DISTANCE
        then
            local unit = u_char.unit
            if alive(unit) and are_units_foes(criminal, unit) then
                local is_turret = EnemyClassifier.is_turret(unit)
                local unit_brain = not is_turret and unit:brain()

                if not (u_char.is_converted or (unit_brain and unit_brain:surrendered())) then
                    local vec = u_char.m_head_pos - from_pos
                    if vec and mvector3.angle(vec, look_vec) <= CONSTANTS.CONC_ANGLE then
                        local is_dozer = EnemyClassifier.is_dozer(unit)

                        if not is_dozer then
                            close_enemies = close_enemies + 1

                            if EnemyClassifier.is_shield(unit, u_char) then
                                shield_count = shield_count + 1
                            end

                            if EnemyClassifier.is_special(unit, u_char) then
                                special_count = special_count + 1
                            end

                            table.insert(enemy_cluster, u_char)
                        end
                    end
                end
            end
        end
    end

    local should_throw = (close_enemies >= 5)
            or (shield_count >= 2)
            or (special_count >= 2 and close_enemies >= 3)

    if not should_throw then
        return false
    end

    local best_cluster_pos
    local best_cluster_count = 0
    local target_unit

    for i, u_char1 in ipairs(enemy_cluster) do
        local cluster_count = 0

        for j, u_char2 in ipairs(enemy_cluster) do
            if i ~= j and u_char2.m_head_pos then
                local dist = mvector3.distance(u_char1.m_head_pos, u_char2.m_head_pos)
                if dist <= CONSTANTS.CLUSTER_DISTANCE then
                    cluster_count = cluster_count + 1
                end
            end
        end

        if cluster_count > best_cluster_count then
            best_cluster_count = cluster_count
            best_cluster_pos = u_char1.m_head_pos
            target_unit = u_char1.unit
        end
    end

    if not (alive(target_unit) and best_cluster_count >= 2 and best_cluster_pos) then
        return false
    end

    local mvec_spread_direction = best_cluster_pos - from_pos

    if ProjectileBase and ProjectileBase.spawn then
        local success, cc_unit = safe_call(ProjectileBase.spawn, conc_tweak.unit, from_pos, Rotation())
        if success and cc_unit then
            local base_ext = cc_unit:base()
            if base_ext then
                mvector3.normalize(mvec_spread_direction)
                play_net_redirect(criminal, "throw_grenade")
                safe_say(criminal, "g43", true, true)
                safe_call(base_ext.throw, base_ext, { dir = mvec_spread_direction, owner = criminal })
                return true
            end
        end
    end

    return false
end

BB.CombatBehavior = CombatBehavior
