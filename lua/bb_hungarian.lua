local BB = _G.BB

local Hungarian = {}

function Hungarian.solve(cost_matrix, n_workers, n_jobs)
    local n = math.max(n_workers, n_jobs)
    if n == 0 then return {} end

    local matrix = {}
    for i = 1, n do
        matrix[i] = {}
        for j = 1, n do
            if i <= n_workers and j <= n_jobs then
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
        if p[j] > 0 and p[j] <= n_workers and j <= n_jobs then
            assignment[p[j]] = j
        end
    end

    return assignment
end

BB.Hungarian = Hungarian
return Hungarian
