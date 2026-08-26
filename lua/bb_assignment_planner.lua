local BB = _G.BB

local Hungarian = BB.Hungarian

local AssignmentPlanner = {}

local URGENCY_BAND = 1000000
local PRIMARY_BAND = 200000
local PREFERRED_FOCUS_BAND = 175000
local MAX_EDGE_SCORE = 99999
local FORBIDDEN_COST = 1000000000000

local function _clamp(value, low, high)
    return math.min(math.max(value, low), high)
end

local function _copy_owner_sets(source)
    local result = {}
    for target_key, owners in pairs(source or {}) do
        result[target_key] = {}
        for bot_key, owns in pairs(owners) do
            if owns then
                result[target_key][bot_key] = true
            end
        end
    end
    return result
end

local function _sorted_targets(targets)
    local sorted = {}
    for _, target in ipairs(targets or {}) do
        table.insert(sorted, target)
    end

    table.sort(sorted, function(a, b)
        local a_urgency = a.urgency or 1
        local b_urgency = b.urgency or 1
        if a_urgency ~= b_urgency then
            return a_urgency > b_urgency
        end

        local a_score = a.max_score or 0
        local b_score = b.max_score or 0
        if a_score ~= b_score then
            return a_score > b_score
        end

        return tostring(a.key) < tostring(b.key)
    end)

    return sorted
end

local function _slot_factor(target, slot_index, preferred)
    if slot_index <= 1 then
        return 1
    end

    if preferred and slot_index == 2 then
        if target.focus == "urgent" then
            return 0.85
        elseif target.focus == "durable" then
            return 0.65
        end
    end

    return 0.35 * math.pow(0.5, math.max(slot_index - 2, 0))
end

local function _append_job(jobs, target, slot_index, preferred)
    table.insert(jobs, {
        target_key = tostring(target.key),
        slot = slot_index,
        preferred = preferred == true,
        factor = _slot_factor(target, slot_index, preferred),
    })
end

local function _build_jobs(targets, n_workers, initial_load)
    local jobs = {}
    local next_slot = {}

    for _, target in ipairs(targets) do
        local target_key = tostring(target.key)
        local load = initial_load[target_key] or 0
        next_slot[target_key] = load + 1

        if load == 0 then
            _append_job(jobs, target, 1, false)
            next_slot[target_key] = 2
        end
    end

    for _, target in ipairs(targets) do
        local target_key = tostring(target.key)
        local slot_index = next_slot[target_key]
        if target.focus and slot_index <= 2 then
            _append_job(jobs, target, slot_index, true)
            next_slot[target_key] = slot_index + 1
        end
    end

    local cursor = 1
    while #jobs < n_workers and #targets > 0 do
        local target = targets[cursor]
        local target_key = tostring(target.key)
        local slot_index = next_slot[target_key] or 1
        _append_job(jobs, target, slot_index, false)
        next_slot[target_key] = slot_index + 1

        cursor = cursor + 1
        if cursor > #targets then
            cursor = 1
        end
    end

    return jobs
end

local function _edge_utility(edge, job, previous_target)
    local urgency = _clamp(tonumber(edge.urgency) or 1, 1, 3)
    local score = _clamp(tonumber(edge.score) or 0, 0, MAX_EDGE_SCORE)
    local coverage_band = job.slot == 1 and PRIMARY_BAND
            or job.preferred and PREFERRED_FOCUS_BAND
            or 0

    if previous_target and tostring(previous_target) == tostring(job.target_key) then
        score = math.min(score * 1.15, MAX_EDGE_SCORE)
    end

    return urgency * URGENCY_BAND + coverage_band + score * job.factor
end

function AssignmentPlanner.utility_for_load(edge, target_key, current_load, focus, previous_target)
    local slot_index = math.max((current_load or 0) + 1, 1)
    local target = { focus = focus }
    local preferred = slot_index == 2 and focus ~= nil
    local job = {
        target_key = tostring(target_key),
        slot = slot_index,
        preferred = preferred,
        factor = _slot_factor(target, slot_index, preferred),
    }

    return _edge_utility(edge, job, previous_target)
end

function AssignmentPlanner.solve(params)
    params = params or {}

    local bots = params.bots or {}
    local edges = params.edges or {}
    local targets = _sorted_targets(params.targets or {})
    local previous_by_bot = params.previous_by_bot or {}
    local fixed_by_bot = params.fixed_by_bot or {}
    local owners_by_target = _copy_owner_sets(params.fixed_owners_by_target)
    local target_load = {}
    local by_bot = {}

    for target_key, owners in pairs(owners_by_target) do
        local load = 0
        for _ in pairs(owners) do
            load = load + 1
        end
        target_load[target_key] = load
    end

    for bot_key, target_key in pairs(fixed_by_bot) do
        bot_key = tostring(bot_key)
        target_key = tostring(target_key)
        by_bot[bot_key] = target_key
        owners_by_target[target_key] = owners_by_target[target_key] or {}
        if not owners_by_target[target_key][bot_key] then
            owners_by_target[target_key][bot_key] = true
            target_load[target_key] = (target_load[target_key] or 0) + 1
        end
    end

    local jobs = _build_jobs(targets, #bots, target_load)
    for _ = 1, #bots do
        table.insert(jobs, { dummy = true })
    end

    if #bots == 0 then
        return {
            by_bot = by_bot,
            owners_by_target = owners_by_target,
            target_load = target_load,
        }
    end

    local max_utility = 0
    local utilities = {}

    for i, bot in ipairs(bots) do
        utilities[i] = {}
        local bot_key = tostring(bot.key)
        local bot_edges = edges[bot_key] or {}

        for j, job in ipairs(jobs) do
            local utility = 0
            if not job.dummy then
                local edge = bot_edges[job.target_key]
                if edge then
                    utility = _edge_utility(edge, job, previous_by_bot[bot_key])
                else
                    utility = false
                end
            end

            utilities[i][j] = utility
            if utility and utility > max_utility then
                max_utility = utility
            end
        end
    end

    local cost_matrix = {}
    for i = 1, #bots do
        cost_matrix[i] = {}
        for j = 1, #jobs do
            local utility = utilities[i][j]
            cost_matrix[i][j] = utility == false and FORBIDDEN_COST or max_utility - utility
        end
    end

    local assignment = Hungarian.solve(cost_matrix, #bots, #jobs)

    for bot_index, job_index in pairs(assignment) do
        local bot_key = tostring(bots[bot_index].key)
        local job = jobs[job_index]
        if job and not job.dummy then
            local target_key = job.target_key
            by_bot[bot_key] = target_key
            owners_by_target[target_key] = owners_by_target[target_key] or {}
            owners_by_target[target_key][bot_key] = true
            target_load[target_key] = (target_load[target_key] or 0) + 1
        end
    end

    return {
        by_bot = by_bot,
        owners_by_target = owners_by_target,
        target_load = target_load,
    }
end

BB.AssignmentPlanner = AssignmentPlanner
return AssignmentPlanner
