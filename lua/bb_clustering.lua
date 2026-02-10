local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local EnemyClassifier = BB.EnemyClassifier

local Clustering = {}

function Clustering.dbscan(points, eps, minPts)
    local n = #points
    if n == 0 then return {}, {} end

    local eps_sq = eps * eps

    local function get_neighbors(i)
        local neighbors = {}
        local p1 = points[i].m_head_pos
        if not p1 then return neighbors end

        for j = 1, n do
            local p2 = points[j].m_head_pos
            if p2 then
                if mvector3.distance_sq(p1, p2) <= eps_sq then
                    table.insert(neighbors, j)
                end
            end
        end
        return neighbors
    end

    local labels = {}
    for i = 1, n do labels[i] = 0 end

    local cluster_id = 0
    local clusters = {}

    for i = 1, n do
        if labels[i] == 0 then
            local neighbors = get_neighbors(i)

            if #neighbors < minPts then
                labels[i] = -1
            else
                cluster_id = cluster_id + 1
                clusters[cluster_id] = {}

                labels[i] = cluster_id
                table.insert(clusters[cluster_id], i)

                local seed_set = {}
                local in_seed_set = {}

                for _, idx in ipairs(neighbors) do
                    if idx ~= i then
                        table.insert(seed_set, idx)
                        in_seed_set[idx] = true
                    end
                end

                local k = 1
                while k <= #seed_set do
                    local q = seed_set[k]

                    if labels[q] == -1 then
                        labels[q] = cluster_id
                        table.insert(clusters[cluster_id], q)
                    end

                    if labels[q] == 0 then
                        labels[q] = cluster_id
                        table.insert(clusters[cluster_id], q)

                        local q_neighbors = get_neighbors(q)
                        if #q_neighbors >= minPts then
                            for _, new_idx in ipairs(q_neighbors) do
                                if not in_seed_set[new_idx] and new_idx ~= i then
                                    in_seed_set[new_idx] = true
                                    table.insert(seed_set, new_idx)
                                end
                            end
                        end
                    end

                    k = k + 1
                end
            end
        end
    end

    return clusters, labels
end

function Clustering.calculate_centroid(points, cluster_indices)
    if #cluster_indices == 0 then return nil end

    local sum_x, sum_y, sum_z = 0, 0, 0
    local valid_count = 0

    for _, idx in ipairs(cluster_indices) do
        local pos = points[idx].m_head_pos
        if pos then
            sum_x = sum_x + mvector3.x(pos)
            sum_y = sum_y + mvector3.y(pos)
            sum_z = sum_z + mvector3.z(pos)
            valid_count = valid_count + 1
        end
    end

    if valid_count == 0 then return nil end

    return Vector3(sum_x / valid_count, sum_y / valid_count, sum_z / valid_count)
end

function Clustering.evaluate_value(points, cluster_indices)
    local value = 0
    local shield_bonus = CONSTANTS.CONC_SHIELD_BONUS or 2.0
    local special_bonus = CONSTANTS.CONC_SPECIAL_BONUS or 1.5

    for _, idx in ipairs(cluster_indices) do
        local u_char = points[idx]
        local unit = u_char.unit
        if alive(unit) then
            value = value + 1
            if EnemyClassifier.is_shield(unit, u_char) then
                value = value + shield_bonus
            end
            if EnemyClassifier.is_special(unit, u_char)
                    and not EnemyClassifier.is_dozer(unit)
                    and not EnemyClassifier.is_turret(unit) then
                value = value + special_bonus
            end
        end
    end

    return value
end

BB.Clustering = Clustering
return Clustering
