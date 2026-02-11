local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local EnemyClassifier = BB.EnemyClassifier
local UnitOps = BB.UnitOps
local Utils = BB.Utils
local CoopCacheManager = BB.CoopCacheManager
local Clustering = BB.Clustering

local safe_call = Utils.safe_call
local are_units_foes = UnitOps.are_foes
local safe_say = UnitOps.say
local play_net_redirect = UnitOps.play_redirect
local is_surrendering = UnitOps.is_surrendering

local ConcussionSystem = {}

local function get_conc_area_key(pos)
    local grid_size = CONSTANTS.CONC_AREA_RADIUS or 1500
    local gx = math.floor(mvector3.x(pos) / grid_size)
    local gy = math.floor(mvector3.y(pos) / grid_size)
    local gz = math.floor(mvector3.z(pos) / grid_size)
    return string.format("conc_%d_%d_%d", gx, gy, gz)
end

function ConcussionSystem.throw(data, criminal)
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
                local is_dozer = EnemyClassifier.is_dozer(unit)

                if not (u_char.is_converted or is_surrendering(unit))
                        and not is_dozer
                        and not is_turret
                then
                    local vec = u_char.m_head_pos - from_pos
                    if vec and mvector3.angle(vec, look_vec) <= CONSTANTS.CONC_ANGLE then
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

    local min_enemies = CONSTANTS.CONC_MIN_ENEMIES
    local min_shields = CONSTANTS.CONC_MIN_SHIELDS
    local special_threshold = CONSTANTS.CONC_SPECIAL_THRESHOLD
    local special_min_enemies = CONSTANTS.CONC_SPECIAL_MIN_ENEMIES

    local should_throw = (close_enemies >= min_enemies)
            or (shield_count >= min_shields)
            or (special_count >= special_threshold and close_enemies >= special_min_enemies)

    if not should_throw then
        return false
    end

    local eps = CONSTANTS.CLUSTER_DISTANCE
    local minPts = CONSTANTS.DBSCAN_MIN_POINTS

    local clusters = Clustering.dbscan(enemy_cluster, eps, minPts)

    local best_cluster_id = nil
    local best_cluster_value = 0
    local best_cluster_size = 0

    for cluster_id, indices in pairs(clusters) do
        if #indices >= minPts then
            local value = Clustering.evaluate_value(enemy_cluster, indices)
            if value > best_cluster_value or
               (value == best_cluster_value and #indices > best_cluster_size) then
                best_cluster_value = value
                best_cluster_size = #indices
                best_cluster_id = cluster_id
            end
        end
    end

    if not best_cluster_id or best_cluster_size < 2 then
        return false
    end

    local best_cluster_pos = Clustering.calculate_centroid(enemy_cluster, clusters[best_cluster_id])

    if best_cluster_pos then
        local area_key = get_conc_area_key(best_cluster_pos)
        if CoopCacheManager.conc_area_cooldown:has(area_key) then
            return false
        end
    end

    local target_unit = nil
    local min_dist_to_centroid = math.huge

    for _, idx in ipairs(clusters[best_cluster_id]) do
        local u_char = enemy_cluster[idx]
        if alive(u_char.unit) and u_char.m_head_pos then
            local dist = mvector3.distance(best_cluster_pos, u_char.m_head_pos)
            if dist < min_dist_to_centroid then
                min_dist_to_centroid = dist
                target_unit = u_char.unit
            end
        end
    end

    if not (alive(target_unit) and best_cluster_pos) then
        return false
    end

    local player_safe_radius = CONSTANTS.CONC_PLAYER_SAFE_RADIUS or 1000
    local player_safe_radius_sq = player_safe_radius * player_safe_radius
    local adjusted_pos = Vector3()
    mvector3.set(adjusted_pos, best_cluster_pos)

    local gstate = managers.groupai and managers.groupai:state()
    local player_criminals = gstate and gstate:all_player_criminals() or {}

    local max_adjustments = 3
    for _ = 1, max_adjustments do
        local needs_adjustment = false
        local push_dir = Vector3()
        local closest_player_dist_sq = math.huge

        for _, u_data in pairs(player_criminals) do
            if alive(u_data.unit) and u_data.unit:movement() then
                local player_pos = u_data.unit:movement():m_head_pos()
                if player_pos then
                    local dist_sq = mvector3.distance_sq(adjusted_pos, player_pos)
                    if dist_sq < player_safe_radius_sq then
                        needs_adjustment = true
                        if dist_sq < closest_player_dist_sq then
                            closest_player_dist_sq = dist_sq
                            mvector3.set(push_dir, adjusted_pos)
                            mvector3.subtract(push_dir, player_pos)
                        end
                    end
                end
            end
        end

        if not needs_adjustment then
            break
        end

        local push_length = mvector3.length(push_dir)
        if push_length < 1 then
            mvector3.set(push_dir, from_pos)
            mvector3.subtract(push_dir, adjusted_pos)
            mvector3.negate(push_dir)
            push_length = mvector3.length(push_dir)
            if push_length < 1 then
                return false
            end
        end

        mvector3.normalize(push_dir)
        local current_dist = math.sqrt(closest_player_dist_sq)
        local offset_needed = player_safe_radius - current_dist + 100
        mvector3.multiply(push_dir, offset_needed)
        mvector3.add(adjusted_pos, push_dir)
    end

    local final_check_failed = false
    for _, u_data in pairs(player_criminals) do
        if alive(u_data.unit) and u_data.unit:movement() then
            local player_pos = u_data.unit:movement():m_head_pos()
            if player_pos then
                local dist_sq = mvector3.distance_sq(adjusted_pos, player_pos)
                if dist_sq < player_safe_radius_sq then
                    final_check_failed = true
                    break
                end
            end
        end
    end

    if final_check_failed then
        return false
    end

    best_cluster_pos = adjusted_pos
    local area_key = get_conc_area_key(best_cluster_pos)
    if CoopCacheManager.conc_area_cooldown:has(area_key) then
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
                CoopCacheManager.conc_area_cooldown:set(area_key, true)
                return true
            end
        end
    end

    return false
end

BB.ConcussionSystem = ConcussionSystem
return ConcussionSystem