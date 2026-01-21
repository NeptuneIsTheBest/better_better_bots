local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local CoopCacheManager = BB.CoopCacheManager
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local EnemyClassifier = BB.EnemyClassifier

local clamp = Utils.clamp
local game_time = Utils.game_time
local get_unit_health_ratio = UnitOps.health_ratio
local are_units_foes = UnitOps.are_foes
local is_dozer_unit = EnemyClassifier.is_dozer

local CoopSystem = {}

CoopSystem.data = BB.coop_data or {
    priority_targets = {},
    teammates_status = {},
    dozer_attackers = {},
    target_directions = {},
    team_pressure_cache = {},
    reloading_count_cache = { count = 0, last_update = 0 },
    reloading_count_cache = { count = 0, last_update = 0 },
    enemy_clusters = {},
    bot_assignments = {},
    previous_centroids = nil,
    last_cluster_update = 0,
}
BB.coop_data = CoopSystem.data

CoopSystem._last_scan = BB._last_coop_scan or {}
BB._last_coop_scan = CoopSystem._last_scan


function CoopSystem.is_enabled()
    return BB:get("coop", false)
end

function CoopSystem.is_clustering_enabled()
    return BB:get("coop", false) and BB:get("coop_cluster", false)
end


function CoopSystem.update_teammate_status(unit)
    if not alive(unit) or not CoopSystem.is_enabled() then
        return
    end

    local u_key = tostring(unit:key())
    local t = game_time()

    local cached = CoopCacheManager.teammate_status:get(u_key)
    if cached and (t - cached.last_update) < 0.3 then
        return cached
    end

    local health_ratio = get_unit_health_ratio(unit)
    local unit_movement = unit:movement()
    local pos = unit_movement and unit_movement:m_head_pos()
    local anim_data = unit:anim_data()
    local is_reloading = anim_data and anim_data.reload
    local head_rot = unit_movement and unit_movement:m_head_rot()
    local facing_dir = head_rot and head_rot:y()

    local status = {
        unit = unit,
        health_ratio = health_ratio,
        position = pos,
        facing_direction = facing_dir,
        in_danger = health_ratio < 0.3,
        needs_cover = health_ratio < 0.15,
        is_reloading = is_reloading,
        last_update = t,
    }

    CoopCacheManager.teammate_status:set(u_key, status, 1)

    local original_u_key = unit:key()
    CoopSystem.data.teammates_status[original_u_key] = status

    return status
end

function CoopSystem.get_reloading_teammates_count(exclude_key)
    if not CoopSystem.is_enabled() then
        return 0
    end

    local t = game_time()
    local cache = CoopSystem.data.reloading_count_cache

    if cache and (t - cache.last_update) < 0.3 then
        return cache.count
    end

    local count = 0
    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if u_key ~= exclude_key and status.is_reloading then
            count = count + 1
        end
    end

    CoopSystem.data.reloading_count_cache = { count = count, last_update = t }
    return count
end

function CoopSystem.count_active_teammates()
    if not CoopSystem.is_enabled() then
        return 0
    end

    local count = 0
    local keys = CoopCacheManager.teammate_status:keys()

    for _, u_key in ipairs(keys) do
        local status = CoopCacheManager.teammate_status:get(u_key)
        if status and status.unit and alive(status.unit) then
            count = count + 1
        else
            CoopCacheManager.teammate_status:clear(u_key)
            CoopSystem.data.teammates_status[u_key] = nil
        end
    end

    return count
end

function CoopSystem.get_dozer_attacker_limit(dozer_unit, dozer_distance)
    if not alive(dozer_unit) then
        return 1
    end

    local team_size = CoopSystem.count_active_teammates()
    local health_ratio = get_unit_health_ratio(dozer_unit)
    local base_limit = team_size >= 4 and 3 or (team_size >= 3 and 2 or 1)

    if health_ratio < 0.3 then
        base_limit = math.max(1, base_limit - 1)
    elseif health_ratio > 0.7 and team_size >= 3 then
        base_limit = base_limit + 1
    end

    if dozer_distance then
        if dozer_distance < 800 then
            base_limit = base_limit + 1
        elseif dozer_distance > 2000 then
            base_limit = math.max(1, base_limit - 1)
        end
    end

    return math.min(base_limit, math.max(1, math.ceil(team_size / 2)))
end

function CoopSystem.count_dozer_attackers(dozer_u_key)
    if not dozer_u_key then
        return 0
    end

    local count = 0
    local t = game_time()

    for u_key, target_u_key in pairs(CoopSystem.data.dozer_attackers) do
        if target_u_key == dozer_u_key then
            local teammate = CoopSystem.data.teammates_status[u_key]
            if teammate and teammate.unit and alive(teammate.unit)
                    and (t - (teammate.last_update or 0)) < CONSTANTS.DOZER_FOCUS_REFRESH
            then
                count = count + 1
            else
                CoopSystem.data.dozer_attackers[u_key] = nil
            end
        end
    end

    return count
end

function CoopSystem.is_direction_covered(target_pos, my_unit)
    if not (target_pos and alive(my_unit)) then
        return false
    end

    local my_pos = my_unit:movement() and my_unit:movement():m_head_pos()
    if not my_pos or mvector3.distance(target_pos, my_pos) < 0.1 then
        return false
    end

    local my_dir = target_pos - my_pos
    mvector3.normalize(my_dir)

    local same_dir_threshold = 0.6
    local face_target_threshold = 0.6

    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if u_key ~= my_unit:key() and status.position and status.facing_direction then
            local other_to_target = target_pos - status.position
            mvector3.normalize(other_to_target)

            local same_dir = mvector3.dot(my_dir, other_to_target)
            local facing_ok = mvector3.dot(status.facing_direction, other_to_target)

            if same_dir > same_dir_threshold and facing_ok > face_target_threshold then
                return true
            end
        end
    end

    return false
end


function CoopSystem.update_clusters()
    local t = game_time()
    
    if CoopSystem.data.last_cluster_update and (t - CoopSystem.data.last_cluster_update) < CONSTANTS.CLUSTER_UPDATE_INTERVAL then
        return
    end
    CoopSystem.data.last_cluster_update = t

    local active_bots = {}
    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if status.unit and alive(status.unit) then
            table.insert(active_bots, { key = u_key, unit = status.unit, pos = status.position, fwd = status.facing_direction })
        end
    end
    
    local k_count = #active_bots
    if k_count < 1 then return end

    local valid_enemies = {}
    local targets = CoopSystem.get_priority_targets()

    for k, v in pairs(targets) do
        if v.unit and alive(v.unit) then
            local pos = v.unit:movement() and v.unit:movement():m_head_pos()
            if pos then
                table.insert(valid_enemies, { key = k, pos = pos })
            end
        end
    end

    local n_enemies = #valid_enemies
    if n_enemies == 0 then 
        CoopSystem.data.enemy_clusters = {}
        CoopSystem.data.bot_assignments = {}
        return 
    end

    local effective_k = math.min(k_count, n_enemies)

    local centroids = {}
    
    if CoopSystem.data.previous_centroids and #CoopSystem.data.previous_centroids == effective_k then
        for i, c in ipairs(CoopSystem.data.previous_centroids) do
            centroids[i] = mvector3.copy(c)
        end
    else
        for i = 1, effective_k do
            centroids[i] = mvector3.copy(valid_enemies[math.random(1, n_enemies)].pos)
        end
    end

    local assignments = {} 
    
    for iter = 1, CONSTANTS.KMEANS_MAX_ITERATIONS do
        local clusters = {}
        for i = 1, effective_k do clusters[i] = {} end
        local changed = false

        for _, enemy in ipairs(valid_enemies) do
            local best_dist = math.huge
            local best_c = 1
            
            for c_idx, c_pos in ipairs(centroids) do
                local d = mvector3.distance_sq(enemy.pos, c_pos)
                if d < best_dist then
                    best_dist = d
                    best_c = c_idx
                end
            end
            
            table.insert(clusters[best_c], enemy)
            if assignments[enemy.key] ~= best_c then
                assignments[enemy.key] = best_c
                changed = true
            end
        end

        for c_idx, cluster_points in ipairs(clusters) do
            if #cluster_points > 0 then
                local new_pos = Vector3(0, 0, 0)
                for _, p in ipairs(cluster_points) do
                    mvector3.add(new_pos, p.pos)
                end
                mvector3.divide(new_pos, #cluster_points)
                centroids[c_idx] = new_pos
            end
        end
        
        if not changed then break end
    end

    CoopSystem.data.previous_centroids = centroids
    CoopSystem.data.enemy_clusters = assignments

    local bot_assignments = {}
    local used_clusters = {}
    
    local suitability_list = {}
    
    for _, bot in ipairs(active_bots) do
        for c_idx, c_pos in ipairs(centroids) do
            local cache_key = tostring(bot.key) .. "_cluster_" .. c_idx
            local score = nil
            
            if BB.CoopCacheManager.suitability then
                score = BB.CoopCacheManager.suitability:get(cache_key)
            end

            if not score then
                local dist = mvector3.distance(bot.pos, c_pos)
                local angle_penalty = 0
                
                if bot.fwd then
                    local to_cluster = c_pos - bot.pos
                    mvector3.normalize(to_cluster)
                    local dot = mvector3.dot(bot.fwd, to_cluster)
                    angle_penalty = (1 - dot) * CONSTANTS.ALLOCATION_ANGLE_WEIGHT
                end
                
                score = dist * (1 + angle_penalty)
                
                if BB.CoopCacheManager.suitability then
                    BB.CoopCacheManager.suitability:set(cache_key, score, 0.5)
                end
            end
            
            table.insert(suitability_list, { 
                bot_key = bot.key, 
                cluster_idx = c_idx, 
                score = score 
            })
        end
    end

    table.sort(suitability_list, function(a, b) return a.score < b.score end)

    local bots_assigned_count = 0
    local assigned_bots_set = {}

    for _, entry in ipairs(suitability_list) do
        if not assigned_bots_set[entry.bot_key] and not used_clusters[entry.cluster_idx] then
            bot_assignments[entry.bot_key] = entry.cluster_idx
            used_clusters[entry.cluster_idx] = true
            assigned_bots_set[entry.bot_key] = true
            bots_assigned_count = bots_assigned_count + 1
        end
        
        if bots_assigned_count >= effective_k or bots_assigned_count >= k_count then
            break
        end
    end

    CoopSystem.data.bot_assignments = bot_assignments
end

function CoopSystem.is_my_assigned_cluster(target_u_key, my_key)
    local t_cluster = CoopSystem.data.enemy_clusters and CoopSystem.data.enemy_clusters[target_u_key]
    local my_cluster = CoopSystem.data.bot_assignments and CoopSystem.data.bot_assignments[my_key]
    
    if t_cluster and my_cluster then
        return t_cluster == my_cluster
    end
    return false
end

function CoopSystem.get_cluster_owner(target_u_key)
    local t_cluster = CoopSystem.data.enemy_clusters and CoopSystem.data.enemy_clusters[target_u_key]
    if not t_cluster then return nil end
    
    for b_key, c_idx in pairs(CoopSystem.data.bot_assignments or {}) do
        if c_idx == t_cluster then
            return b_key
        end
    end
    return nil
end

function CoopSystem.is_cluster_covered(target_key, except_my_key, check_special)
   local owner = CoopSystem.get_cluster_owner(target_key)
   if owner and owner ~= except_my_key then
       return true
   end
   return false
end

CoopSystem.STATE_PRIORITY = {
    normal = 0,
    near_teammate = 1,
    dozer_facing = 2,
    tasing_teammate = 3,
    spooc_attacking = 4,
}

function CoopSystem.update_priority_target(unit, priority, state_info)
    if not (alive(unit) and CoopSystem.is_enabled()) then
        return
    end

    local u_key_str = tostring(unit:key())
    local u_key = unit:key()
    local t = game_time()

    local existing_target = CoopCacheManager.priority_target:get(u_key_str)

    if existing_target then
        existing_target.priority = math.max(existing_target.priority, priority)
        existing_target.last_seen = t
        if state_info then
            local old_prio = CoopSystem.STATE_PRIORITY[existing_target.state] or 0
            local new_prio = CoopSystem.STATE_PRIORITY[state_info] or 0
            if new_prio >= old_prio then
                existing_target.state = state_info
            end
        end
        CoopCacheManager.priority_target:set(u_key_str, existing_target, CONSTANTS.PRIORITY_TARGET_DURATION)
    else
        local new_target = {
            unit = unit,
            u_key = u_key,
            priority = priority,
            first_seen = t,
            last_seen = t,
            targeted_by = nil,
            claimed_at = 0,
            state = state_info or "normal",
        }
        CoopCacheManager.priority_target:set(u_key_str, new_target, CONSTANTS.PRIORITY_TARGET_DURATION)
    end

    CoopSystem.data.priority_targets[u_key] = CoopCacheManager.priority_target:get(u_key_str)
end

function CoopSystem.get_priority_targets()
    if not CoopSystem.is_enabled() then
        return {}
    end

    local t = game_time()
    local active_targets = {}
    local keys = CoopCacheManager.priority_target:keys()

    for _, u_key_str in ipairs(keys) do
        local target_data = CoopCacheManager.priority_target:get(u_key_str)

        if target_data and target_data.unit and alive(target_data.unit) then
            if target_data.targeted_by then
                local targeting_str = tostring(target_data.targeted_by)
                local targeting = CoopCacheManager.teammate_status:get(targeting_str)
                local claim_timed_out = (t - (target_data.claimed_at or 0)) > CONSTANTS.PRIORITY_TARGET_CLAIM_TIMEOUT
                local claim_stale = true

                if targeting and targeting.unit and alive(targeting.unit) then
                    local lu = targeting.last_update or 0
                    claim_stale = (t - lu) > CONSTANTS.PRIORITY_TARGET_CLAIM_TIMEOUT
                end

                if claim_timed_out or claim_stale then
                    target_data.targeted_by = nil
                    target_data.claimed_at = 0
                    CoopCacheManager.priority_target:set(u_key_str, target_data, CONSTANTS.PRIORITY_TARGET_DURATION)
                end
            end

            local original_key = target_data.u_key
            active_targets[original_key] = target_data
        else
            CoopCacheManager.priority_target:clear(u_key_str)
            if target_data and target_data.u_key then
                CoopSystem.data.priority_targets[target_data.u_key] = nil
            end
        end
    end

    return active_targets
end

function CoopSystem.get_closest_teammate_info(pos)
    if not (pos and CoopSystem.data) then
        return nil, false, nil
    end

    local cache_key = string.format("%.0f_%.0f_%.0f", pos.x, pos.y, pos.z)
    local cached = CoopCacheManager.teammate_distance:get(cache_key)
    if cached then
        return cached.min_dist, cached.in_danger_any, cached.who
    end

    local min_dist = math.huge
    local in_danger_any = false
    local who = nil
    local keys = CoopCacheManager.teammate_status:keys()

    for _, u_key in ipairs(keys) do
        local st = CoopCacheManager.teammate_status:get(u_key)
        if st and st.unit and alive(st.unit) and st.position then
            local d = mvector3.distance(pos, st.position)
            if d < min_dist then
                min_dist = d
                in_danger_any = st.in_danger or in_danger_any
                who = st
            end
        end
    end

    if min_dist == math.huge then
        return nil, false, nil
    end

    CoopCacheManager.teammate_distance:set(cache_key, {
        min_dist = min_dist,
        in_danger_any = in_danger_any,
        who = who
    }, 0.2)

    return min_dist, in_danger_any, who
end

local function shield_blocks(attacker, target_head_pos)
    return BB.CombatHelper.shield_blocks(attacker, target_head_pos, BB.MASK.enemy_shield_check)
end

function CoopSystem.compute_dynamic_priority(my_unit, att_obj, data)
    if not (alive(my_unit) and att_obj and att_obj.unit and alive(att_obj.unit)) then
        return 0, "normal"
    end

    local enemy = att_obj.unit
    local flags = BB.classify_enemy(enemy, att_obj)
    local pos = att_obj.m_head_pos or (enemy:movement() and enemy:movement():m_head_pos())
    local my_head = my_unit:movement() and my_unit:movement():m_head_pos()
    local dis = att_obj.verified_dis
            or ((my_head and pos) and mvector3.distance(my_head, pos))
            or 2000

    local prio = 0
    local state = "normal"

    local ally_dist, ally_in_danger = pos and CoopSystem.get_closest_teammate_info(pos)
    local team_factor = 1.0

    if ally_dist then
        local prox = clamp(1 - (ally_dist / CONSTANTS.COOP_TEAMMATE_DANGER_RANGE), 0, 1)
        team_factor = 1 + prox * 0.8 + (ally_in_danger and 0.4 or 0)
        if prox > 0.5 then
            state = "near_teammate"
        end
    end

    if flags.turret then
        prio = prio + 18
    end
    if flags.dozer then
        prio = prio + 13
        
        if pos and my_head then
            local e_mov = enemy:movement()
            local e_fwd = e_mov and e_mov:m_head_rot() and e_mov:m_head_rot():y()
            if e_fwd then
                local to_me = my_head - pos
                mvector3.normalize(to_me)
                if mvector3.dot(e_fwd, to_me) > 0.7 then
                    prio = prio + 20
                    state = "dozer_facing"
                end
            end
        end
    end
    if flags.taser then
        prio = prio + 14
    end
    if flags.cloaker then
        prio = prio + (dis < 1400 and 18 or 12)
    end
    if flags.sniper then
        prio = prio + 15
        if dis > 2500 then
            prio = prio + 4
        end
    end
    if flags.medic then
        prio = prio + 10
    end

    if flags.tasing then
        prio = prio + 30
        state = "tasing_teammate"
    end

    if flags.spooc_attack then
        prio = prio + 28
        state = "spooc_attacking"
    end

    if flags.shield then
        local has_ap = managers.player and managers.player:has_category_upgrade("team", "crew_ai_ap_ammo")
        local blocked = pos and shield_blocks(my_unit, pos)

        if blocked and not has_ap and dis > CONSTANTS.MELEE_DISTANCE then
            prio = prio + 2
        else
            prio = prio + 9
        end
    end

    if pos then
        local cluster = 0
        for _, v in pairs(data.detected_attention_objects or {}) do
            if v ~= att_obj
                    and v.identified
                    and v.unit
                    and alive(v.unit)
                    and are_units_foes(my_unit, v.unit)
                    and v.m_head_pos
            then
                local d = mvector3.distance(pos, v.m_head_pos)
                if d <= CONSTANTS.CLUSTER_DISTANCE then
                    cluster = cluster + 1
                end
            end
        end

        if cluster >= 3 then
            prio = prio + 5
        end
    end

    if pos and not CoopSystem.is_direction_covered(pos, my_unit) then
        prio = prio + (THREAT_WEIGHTS.DIRECTION_BONUS / 3)
    end

    if att_obj.verified then
        prio = prio + 2
    end

    if not flags.sniper and not flags.turret then
        if dis > 4000 then
            prio = prio * 0.7
        elseif dis > 3000 then
            prio = prio * 0.85
        end
    end

    prio = prio * team_factor
    return prio, state
end

function CoopSystem.scan_and_update_priorities(data)
    if not (CoopSystem.is_enabled() and data and data.unit and alive(data.unit)) then
        return
    end

    local t = data.t or game_time()
    local my_key = data.key
    local last = CoopSystem._last_scan[my_key] or 0

    if t - last < CONSTANTS.COOP_REFRESH_INTERVAL then
        return
    end

    CoopSystem._last_scan[my_key] = t

    if CoopSystem.is_clustering_enabled() then
        CoopSystem.update_clusters()
    end

    for _, att_obj in pairs(data.detected_attention_objects or {}) do
        if att_obj.identified
                and att_obj.reaction
                and att_obj.reaction >= AIAttentionObject.REACT_COMBAT
                and att_obj.unit
                and alive(att_obj.unit)
        then
            local prio, st = CoopSystem.compute_dynamic_priority(data.unit, att_obj, data)
            if prio and prio > 0 then
                CoopSystem.update_priority_target(att_obj.unit, prio, st)
            end

            if st == "tasing_teammate" or st == "spooc_attacking" then
                CoopSystem.mark_dangerous_special(att_obj.unit, data.unit)
            end
        end
    end
end

function CoopSystem.mark_dangerous_special(enemy_unit, bot_unit)
    if not (alive(enemy_unit) and alive(bot_unit)) then
        return
    end

    local contour = enemy_unit:contour()
    if contour and managers.player then
        local mark_id = managers.player:get_contour_for_marked_enemy()
        if mark_id and (not contour._contour_list or not contour:has_id(mark_id)) then
            UnitOps.say(bot_unit, "f32x_any", true, true)
            Utils.safe_call(contour.add, contour, mark_id, true)
        end
    end
end

function CoopSystem.calculate_team_pressure(unit, data)
    if not (alive(unit) and CoopSystem.is_enabled()) then
        return 0
    end

    local t = game_time()
    local u_key = unit:key()
    local cache = CoopSystem.data.team_pressure_cache[u_key]

    if cache and (t - cache.last_update) < 0.2 then
        return cache.pressure
    end

    local my_pos = unit:movement() and unit:movement():m_head_pos()
    if not my_pos then
        return 0
    end

    local pressure = 0
    local enemy_count = 0
    local special_count = 0
    local close_enemy_count = 0

    for _, att_obj in pairs(data.detected_attention_objects or {}) do
        if att_obj.identified
                and att_obj.verified
                and att_obj.unit
                and alive(att_obj.unit)
                and are_units_foes(unit, att_obj.unit)
        then
            local dis = att_obj.verified_dis
            if dis and dis <= CONSTANTS.PRESSURE_SCAN_RANGE then
                enemy_count = enemy_count + 1
                pressure = pressure + CONSTANTS.PRESSURE_ENEMY_WEIGHT

                if dis < 800 then
                    close_enemy_count = close_enemy_count + 1
                    pressure = pressure + CONSTANTS.PRESSURE_ENEMY_WEIGHT
                end

                local flags = BB.classify_enemy(att_obj.unit, att_obj)
                if flags.special or flags.dozer or flags.taser or flags.cloaker then
                    special_count = special_count + 1
                    pressure = pressure + CONSTANTS.PRESSURE_SPECIAL_WEIGHT
                end

                if flags.tasing or flags.spooc_attack then
                    pressure = pressure + 0.25
                end
            end
        end
    end

    local teammates_in_danger = 0
    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if u_key ~= unit:key() and status.unit and alive(status.unit) then
            if status.in_danger then
                teammates_in_danger = teammates_in_danger + 1
                pressure = pressure + CONSTANTS.PRESSURE_TEAMMATE_LOW_HEALTH_WEIGHT
            end
            if status.needs_cover then
                pressure = pressure + CONSTANTS.PRESSURE_TEAMMATE_LOW_HEALTH_WEIGHT * 0.5
            end
        end
    end

    local my_health = get_unit_health_ratio(unit)
    if my_health < 0.25 then
        pressure = pressure + 0.2
    elseif my_health < 0.5 then
        pressure = pressure + 0.1
    end

    pressure = clamp(pressure, 0, 1)
    CoopSystem.data.team_pressure_cache[u_key] = { pressure = pressure, last_update = t }
    return pressure
end

function CoopSystem.get_pressure_adjusted_reload_threshold(unit, data, base_threshold)
    if not CoopSystem.is_enabled() then
        return base_threshold
    end

    local pressure = CoopSystem.calculate_team_pressure(unit, data)
    
    local threshold = base_threshold

    if pressure >= CONSTANTS.PRESSURE_HIGH_THRESHOLD then
        local factor = (pressure - CONSTANTS.PRESSURE_HIGH_THRESHOLD) / (1 - CONSTANTS.PRESSURE_HIGH_THRESHOLD)
        threshold = math.lerp(base_threshold, 0.0, factor)
    elseif pressure <= CONSTANTS.PRESSURE_LOW_THRESHOLD then
        local factor = (CONSTANTS.PRESSURE_LOW_THRESHOLD - pressure) / CONSTANTS.PRESSURE_LOW_THRESHOLD
        threshold = math.lerp(base_threshold, CONSTANTS.PRESSURE_RELOAD_MAX, factor)
    end

    return clamp(threshold, 0, 1)
end

BB.CoopSystem = CoopSystem
