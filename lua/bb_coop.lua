local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local CoopCacheManager = BB.CoopCacheManager
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local EnemyClassifier = BB.EnemyClassifier
local ThreatAssessment = BB.ThreatAssessment

local clamp = Utils.clamp
local game_time = Utils.game_time
local get_unit_health_ratio = UnitOps.health_ratio
local are_units_foes = UnitOps.are_foes
local is_dozer_unit = EnemyClassifier.is_dozer
local is_special_unit = EnemyClassifier.is_special

local function get_bot_weapon_dps(bot_unit)
    if not (bot_unit and alive(bot_unit)) then return 10 end
    local inventory = bot_unit:inventory()
    local equipped_unit = inventory and inventory:equipped_unit()
    local weapon_base = equipped_unit and equipped_unit:base()
    if weapon_base then
        local damage = weapon_base._damage or 1
        local name_id = weapon_base._name_id
        local fire_rate = 0.1

        if name_id and tweak_data.weapon[name_id] then
            local weapon_tweak = tweak_data.weapon[name_id]
            if weapon_tweak.auto and weapon_tweak.auto.fire_rate then
                fire_rate = weapon_tweak.auto.fire_rate
            elseif weapon_tweak.fire_mode_data and weapon_tweak.fire_mode_data.fire_rate then
                fire_rate = weapon_tweak.fire_mode_data.fire_rate
            end
        end

        local dps = damage / math.max(fire_rate, 0.05)
        return dps * 10
    end
    return 10
end

local CoopSystem = {}

CoopSystem.data = BB.coop_data or {
    priority_targets = {},
    teammates_status = {},
    dozer_attackers = {},
    target_directions = {},
    team_pressure_cache = {},
    reloading_count_cache = { count = 0, last_update = 0 },
    optimal_assignments = {},
    last_assignment_update = 0,
}
BB.coop_data = CoopSystem.data

CoopSystem._last_scan = BB._last_coop_scan or {}
BB._last_coop_scan = CoopSystem._last_scan

function CoopSystem.is_enabled()
    return BB:get("coop", false)
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

local function hungarian_algorithm(cost_matrix, n_bots, n_enemies)
    local n = math.max(n_bots, n_enemies)
    if n == 0 then return {} end

    local matrix = {}
    for i = 1, n do
        matrix[i] = {}
        for j = 1, n do
            if i <= n_bots and j <= n_enemies then
                matrix[i][j] = cost_matrix[i][j] or 0
            else
                matrix[i][j] = 0
            end
        end
    end

    local INF = 1e18
    local u = {}
    local v = {}
    local p = {}
    local way = {}

    for i = 0, n do
        u[i] = 0
        v[i] = 0
        p[i] = 0
    end


    for i = 1, n do
        p[0] = i
        local j0 = 0
        local minv = {}
        local used = {}

        for j = 0, n do
            minv[j] = INF
            used[j] = false
            way[j] = 0
        end


        repeat
            used[j0] = true
            local i0 = p[j0]
            local delta = INF
            local j1 = 0

            for j = 1, n do
                if not used[j] then
                    local cur = matrix[i0][j] - u[i0] - v[j]
                    if cur < minv[j] then
                        minv[j] = cur
                        way[j] = j0
                    end
                    if minv[j] < delta then
                        delta = minv[j]
                        j1 = j
                    end
                end
            end


            for j = 0, n do
                if used[j] then
                    u[p[j]] = u[p[j]] + delta
                    v[j] = v[j] - delta
                else
                    minv[j] = minv[j] - delta
                end
            end

            j0 = j1
        until p[j0] == 0


        repeat
            local j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        until j0 == 0
    end


    local assignment = {}
    for j = 1, n do
        if p[j] > 0 and p[j] <= n_bots and j <= n_enemies then
            assignment[p[j]] = j
        end
    end

    return assignment
end

function CoopSystem.update_optimal_assignments()
    local t = game_time()

    if CoopSystem.data.last_assignment_update and (t - CoopSystem.data.last_assignment_update) < CONSTANTS.ASSIGNMENT_UPDATE_INTERVAL then
        return
    end
    CoopSystem.data.last_assignment_update = t

    local active_bots = {}
    local bot_key_to_index = {}
    for u_key, status in pairs(CoopSystem.data.teammates_status) do
        if status.unit and alive(status.unit) then
            table.insert(active_bots, {
                key = u_key,
                unit = status.unit,
                pos = status.position,
                fwd = status.facing_direction,
                weapon_type = ThreatAssessment.get_weapon_archetype(status.unit)
            })
            bot_key_to_index[u_key] = #active_bots
        end
    end

    local n_bots = #active_bots
    if n_bots < 1 then
        CoopSystem.data.optimal_assignments = {}
        return
    end


    local valid_enemies = {}
    local enemy_key_to_index = {}
    local targets = CoopSystem.get_priority_targets()

    for k, v in pairs(targets) do
        if v.unit and alive(v.unit) then
            local pos = v.unit:movement() and v.unit:movement():m_head_pos()
            if pos then
                table.insert(valid_enemies, {
                    key = k,
                    unit = v.unit,
                    pos = pos,
                    priority = v.priority or 1,
                    state = v.state,
                    is_special = is_special_unit(v.unit)
                })
                enemy_key_to_index[k] = #valid_enemies
            end
        end
    end

    local n_enemies = #valid_enemies
    if n_enemies == 0 then
        CoopSystem.data.optimal_assignments = {}
        return
    end

    local cost_matrix = {}
    local MAX_COST = 1e9

    for i, bot in ipairs(active_bots) do
        cost_matrix[i] = {}
        for j, enemy in ipairs(valid_enemies) do
            local priority = enemy.priority or 1

            local dist = 1
            if bot.pos and enemy.pos then
                dist = mvector3.distance(bot.pos, enemy.pos)
            end

            local dist_factor = 1 / (1 + dist / 1000)

            local angle_factor = 1
            if bot.fwd and bot.pos and enemy.pos then
                local to_enemy = enemy.pos - bot.pos
                if mvector3.length(to_enemy) > 0.1 then
                    mvector3.normalize(to_enemy)
                    local dot = mvector3.dot(bot.fwd, to_enemy)
                    angle_factor = 0.5 + 0.5 * math.max(0, dot)
                end
            end

            local coverage_bonus = 0
            if enemy.pos and not CoopSystem.is_direction_covered(enemy.pos, bot.unit) then
                coverage_bonus = THREAT_WEIGHTS.DIRECTION_BONUS
            end

            local dozer_penalty = 1
            if is_dozer_unit(enemy.unit) then
                local current_attackers = CoopSystem.count_dozer_attackers(enemy.key)
                local attacker_limit = CoopSystem.get_dozer_attacker_limit(enemy.unit, dist)
                if current_attackers >= attacker_limit then
                    local already_targeting = CoopSystem.data.dozer_attackers[bot.key] == enemy.key
                    if not already_targeting then
                        dozer_penalty = 0.3
                    end
                end
            end

            local state_bonus = 0
            if enemy.state == "tasing_teammate" then
                state_bonus = THREAT_WEIGHTS.TASING_BONUS
            elseif enemy.state == "spooc_attacking" then
                state_bonus = THREAT_WEIGHTS.SPOOC_ATTACK_BONUS
            elseif enemy.state == "dozer_facing" then
                state_bonus = THREAT_WEIGHTS.COOP_DOZER_FACING_BONUS
            elseif enemy.state == "near_teammate" then
                state_bonus = 10
            end

            local enemy_health_ratio = get_unit_health_ratio(enemy.unit)
            local bot_dps = get_bot_weapon_dps(bot.unit)
            local ttk_score = 0
            if bot_dps > 0 then
                local kill_power = math.min(bot_dps / 100, 5.0)
                local health_factor = math.max(enemy_health_ratio, 0.1)
                ttk_score = kill_power / health_factor
                if enemy_health_ratio < 0.3 then
                    ttk_score = ttk_score * CONSTANTS.LOW_HEALTH_TTK_BONUS
                end
                if is_special_unit(enemy.unit) then
                    if enemy_health_ratio > 0.5 then
                        ttk_score = math.min(ttk_score, 5)
                    end
                end
            end
            ttk_score = math.min(ttk_score, CONSTANTS.TTK_SCORE_CAP)

            local weapon_type_score = 0
            local bot_weapon = bot.weapon_type
            if bot_weapon == "sniper" then
                if enemy.is_special then
                    weapon_type_score = CONSTANTS.SNIPER_SPECIAL_BONUS
                end
            elseif bot_weapon == "shotgun" then
                if dist < CONSTANTS.SHOTGUN_EFFECTIVE_RANGE then
                    weapon_type_score = math.max(0, CONSTANTS.SHOTGUN_MAX_BONUS - dist / CONSTANTS.SHOTGUN_RANGE_DIVISOR)
                end
                if enemy.is_special and dist < CONSTANTS.SHOTGUN_EFFECTIVE_RANGE then
                    weapon_type_score = weapon_type_score + CONSTANTS.SHOTGUN_SPECIAL_BONUS
                end
            end

            local score = ((priority + coverage_bonus + state_bonus + weapon_type_score) + ttk_score) * dist_factor * angle_factor * dozer_penalty

            cost_matrix[i][j] = MAX_COST - score * 1000
        end
    end


    local assignment = hungarian_algorithm(cost_matrix, n_bots, n_enemies)


    local optimal_assignments = {}
    for bot_idx, enemy_idx in pairs(assignment) do
        if bot_idx <= n_bots and enemy_idx <= n_enemies then
            local bot_key = active_bots[bot_idx].key
            local enemy_key = valid_enemies[enemy_idx].key
            optimal_assignments[bot_key] = enemy_key
        end
    end

    CoopSystem.data.optimal_assignments = optimal_assignments
end

function CoopSystem.is_my_assigned_target(target_u_key, my_key)
    local my_assigned = CoopSystem.data.optimal_assignments and CoopSystem.data.optimal_assignments[my_key]
    if my_assigned then
        return my_assigned == target_u_key
    end
    return false
end

function CoopSystem.get_target_owner(target_u_key)
    for bot_key, assigned_target in pairs(CoopSystem.data.optimal_assignments or {}) do
        if assigned_target == target_u_key then
            return bot_key
        end
    end
    return nil
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
        prio = prio + THREAT_WEIGHTS.COOP_TURRET_PRIO
    end
    if flags.dozer then
        prio = prio + THREAT_WEIGHTS.COOP_DOZER_PRIO

        if pos and my_head then
            local e_mov = enemy:movement()
            local e_fwd = e_mov and e_mov:m_head_rot() and e_mov:m_head_rot():y()
            if e_fwd then
                local to_me = my_head - pos
                mvector3.normalize(to_me)
                if mvector3.dot(e_fwd, to_me) > 0.7 then
                    prio = prio + THREAT_WEIGHTS.COOP_DOZER_FACING_BONUS
                    state = "dozer_facing"
                end
            end
        end
    end
    if flags.taser then
        prio = prio + THREAT_WEIGHTS.COOP_TASER_PRIO
    end
    if flags.cloaker then
        prio = prio + (dis < 1400 and THREAT_WEIGHTS.COOP_CLOAKER_CLOSE_PRIO or THREAT_WEIGHTS.COOP_CLOAKER_PRIO)
    end
    if flags.sniper then
        prio = prio + THREAT_WEIGHTS.COOP_SNIPER_PRIO
        if dis > 2500 then
            prio = prio + THREAT_WEIGHTS.COOP_SNIPER_FAR_BONUS
        end
    end
    if flags.medic then
        prio = prio + THREAT_WEIGHTS.COOP_MEDIC_PRIO
    end

    if flags.tasing then
        prio = prio + THREAT_WEIGHTS.COOP_TASING_PRIO
        state = "tasing_teammate"
    end

    if flags.spooc_attack then
        prio = prio + THREAT_WEIGHTS.COOP_SPOOC_PRIO
        state = "spooc_attacking"
    end

    if flags.shield then
        local has_ap = managers.player and managers.player:has_category_upgrade("team", "crew_ai_ap_ammo")
        local blocked = pos and ThreatAssessment.shield_blocks(my_unit, pos)

        if blocked and not has_ap and dis > CONSTANTS.MELEE_DISTANCE then
            prio = prio + THREAT_WEIGHTS.COOP_SHIELD_BLOCKED_PRIO
        else
            prio = prio + THREAT_WEIGHTS.COOP_SHIELD_CLEAR_PRIO
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
            prio = prio + THREAT_WEIGHTS.COOP_CLUSTER_BONUS
        end
    end

    if pos and not CoopSystem.is_direction_covered(pos, my_unit) then
        prio = prio + (THREAT_WEIGHTS.DIRECTION_BONUS / 3)
    end

    if att_obj.verified then
        prio = prio + THREAT_WEIGHTS.COOP_VERIFIED_BONUS
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

    CoopSystem.update_optimal_assignments()

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
        threshold = math.lerp(base_threshold, CONSTANTS.PRESSURE_RELOAD_MIN, factor)
    elseif pressure <= CONSTANTS.PRESSURE_LOW_THRESHOLD then
        local factor = (CONSTANTS.PRESSURE_LOW_THRESHOLD - pressure) / CONSTANTS.PRESSURE_LOW_THRESHOLD
        threshold = math.lerp(base_threshold, CONSTANTS.PRESSURE_RELOAD_MAX, factor)
    end

    return clamp(threshold, 0, 1)
end

BB.CoopSystem = CoopSystem
