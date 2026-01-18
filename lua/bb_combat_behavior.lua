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

function CombatBehavior.find_enemy_to_mark(enemies, my_unit)
    if not (alive(my_unit) and managers.player) then
        return nil
    end

    local unit_movement = my_unit:movement()
    if not unit_movement then
        return nil
    end

    local player_manager = managers.player
    local contour_id = player_manager.get_contour_for_marked_enemy
            and player_manager:get_contour_for_marked_enemy()
            or "mark_enemy"
    local has_ap = player_manager:has_category_upgrade("team", "crew_ai_ap_ammo") or false

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

    local mark_base = to_mark:base()
    if not mark_base then
        return
    end

    local char_tweak = mark_base.char_tweak and mark_base:char_tweak()
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
        local player_manager = managers.player
        local prefer_id = player_manager
                and player_manager.get_contour_for_marked_enemy
                and player_manager:get_contour_for_marked_enemy()
                or "mark_enemy"

        local c_id = is_turret and "mark_unit_dangerous" or prefer_id

        if not contour:has_id(c_id) then
            safe_call(contour.add, contour, c_id, true)
        end
    end

    data._ai_last_mark_t = t
end

function CombatBehavior.check_smart_reload(data)
    local unit = data.unit
    if not alive(unit) then
        return
    end

    local unit_movement = unit:movement()
    local unit_inventory = unit:inventory()

    if not unit_movement then
        return
    end

    if unit_movement:chk_action_forbidden("reload") or (unit:anim_data() and unit:anim_data().reload) then
        return
    end

    if not unit_inventory then
        return
    end

    local current_wep = unit_inventory:equipped_unit()
    local wep_base = current_wep and current_wep:base()
    if not wep_base then
        return
    end

    local clip_max, clip_ammo, reserve_total, reserve_total_max = wep_base:ammo_info()
    if not (clip_max and clip_max > 0) then
        return
    end

    if clip_ammo and clip_ammo >= clip_max then
        return
    end

    if (reserve_total or 0) <= 0 then
        return
    end

    if BB:get("coop", false) then
        local teammates_reloading = 0
        local my_key = unit:key()
        local coop = BB.CoopSystem and BB.CoopSystem.data

        if coop and coop.teammates_status then
            for u_key, status in pairs(coop.teammates_status) do
                if u_key ~= my_key and status.is_reloading then
                    teammates_reloading = teammates_reloading + 1
                end
            end
        end

        if clip_ammo > 0 and teammates_reloading >= CONSTANTS.MAX_RELOADING_TEAMMATES then
            return
        end
    end

    local nearby_threats = 0
    local closest_threat = math.huge

    for _, u_char in pairs(data.detected_attention_objects or {}) do
        if u_char.identified
                and u_char.verified
                and alive(u_char.unit)
                and are_units_foes(unit, u_char.unit)
        then
            nearby_threats = nearby_threats + 1
            if u_char.verified_dis and u_char.verified_dis < closest_threat then
                closest_threat = u_char.verified_dis
            end
        end
    end

    local reload_threshold = 0.6
    if nearby_threats == 0 then
        reload_threshold = 0.8
    elseif closest_threat < 500 then
        reload_threshold = 0.3
    elseif nearby_threats > 3 then
        reload_threshold = 0.4
    end

    if clip_ammo <= math.ceil(clip_max * reload_threshold) then
        local objective = data.objective
        local in_cover = objective and objective.in_place

        if in_cover or closest_threat > 1000 or clip_ammo == 0 then
            local brain = unit:brain()
            if brain then
                brain:action_request({ type = "reload", body_part = 3 })
            end
        end
    end
end

function CombatBehavior.execute_melee_attack(data, criminal)
    if not alive(criminal) then
        return
    end

    local criminal_inventory = criminal:inventory()
    if not criminal_inventory then
        return
    end

    local current_wep = criminal_inventory:equipped_unit()
    local crim_mov = criminal:movement()
    if not crim_mov then
        return
    end

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
    if not (BB:get("conc", false) and alive(criminal)) then
        return false
    end

    if not (tweak_data.blackmarket and tweak_data.blackmarket.projectiles) then
        return false
    end

    local conc_tweak = tweak_data.blackmarket.projectiles.concussion
    if not (conc_tweak and conc_tweak.unit) then
        return false
    end

    if not managers.dyn_resource then
        return false
    end

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
