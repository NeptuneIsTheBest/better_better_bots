_G.BB = _G.BB or {}

local BB = _G.BB

local CONSTANTS = {
	GRACE_PERIOD = 10,
	INTIMIDATE_DISTANCE = 1200,
	INTIMIDATE_ANGLE = 90,
	MARK_DISTANCE = 3000,
	MELEE_DISTANCE = 200,
	MELEE_ANGLE = 60,
	CONC_DISTANCE = 3000,
	CONC_ANGLE = 90,
	CLUSTER_DISTANCE = 500,
	RELOAD_CHECK_INTERVAL = 1,
	MELEE_CHECK_INTERVAL = 0.5,
	CONC_COOLDOWN = 4,
	INTIMIDATE_COOLDOWN = 2,
	MARK_COOLDOWN = 2,
	INTIMIDATE_MAX_ATTEMPTS = 3,
	PRIORITY_TARGET_DURATION = 7,
	COOP_TEAMMATE_DANGER_RANGE = 1500,
	MAX_RELOADING_TEAMMATES = 1,
	PRIORITY_TARGET_CLAIM_TIMEOUT = 3,
	DOZER_FOCUS_REFRESH = 2,
	TARGET_SWITCH_DELAY = 1.5,
}

local THREAT_WEIGHTS = {
	DISTANCE_BASE = 1000,
	CLOAKER = 100,
	TASER = 90,
	TASER_ACTIVE = 200,
	SHIELD = 60,
	DOZER = 80,
	MEDIC = 70,
	SNIPER = 75,
	SPECIAL = 65,
	LOW_HEALTH_BONUS = 50,
	TARGETING_ME_BONUS = 60,
	SAME_TARGET_PENALTY = 0.35,
	DIRECTION_BONUS = 30,
}

local SLOTS = {
	HOSTAGES = 22
}

local MathUtils = {}
MathUtils.mvec3_norm = mvector3.normalize
MathUtils.mvec3_angle = mvector3.angle
MathUtils.mvec3_dot = mvector3.dot
MathUtils.mvec3_distance = mvector3.distance

function MathUtils.clamp(x, a, b)
	return math.min(math.max(x, a), b)
end

local function _get_mask(name, fallback_slots)
	if name and managers and managers.slot and managers.slot.get_mask then
		local ok, m = pcall(managers.slot.get_mask, managers.slot, name)
		if ok and m then
			return m
		end
	end

	if fallback_slots == nil then
		return World:make_slot_mask()
	elseif type(fallback_slots) == "table" then
		return World:make_slot_mask(unpack(fallback_slots))
	elseif type(fallback_slots) == "number" then
		return World:make_slot_mask(fallback_slots)
	else
		return World:make_slot_mask()
	end
end

local MASK = {
	AI_visibility = _get_mask("AI_visibility", {1, 11, 38, 39}),
	enemy_shield_check = _get_mask("enemy_shield_check", 8),
	hostages = _get_mask("hostages", 22),
	players = _get_mask("players", {2, 3, 4, 5}),
	criminals_no_deployables = _get_mask("criminals_no_deployables", {2, 3, 16})
}

local function bb_log(msg, level)
	log(string.format("[Better Bots][%s] %s", level or "INFO", tostring(msg)))
end

local function safe_call(func, ...)
	if type(func) ~= "function" then return end
	local success, result = pcall(func, ...)
	if not success then
		bb_log("Error: " .. tostring(result), "ERROR")
	end
	return result
end

local function as_bool_from_item(item)
	return item and item:value() == "on"
end

local function as_number_from_item(item, fallback)
	return item and tonumber(item:value()) or fallback
end

local function game_time()
	local tm = TimerManager
	return (tm and tm:game() and tm:game():time()) or 0
end

local function head_pos(unit)
	local m = alive(unit) and unit:movement()
	return m and m:m_head_pos() or nil
end

local function safe_say(unit, line, important, skip_forced)
	if not alive(unit) then return end
	local snd = unit.sound and unit:sound()
	if snd and snd.say then
		safe_call(snd.say, snd, tostring(line), important ~= false, skip_forced ~= false)
	end
end

local function play_net_redirect(unit, variant)
	local mov = alive(unit) and unit:movement()
	if mov and mov.play_redirect then
		safe_call(mov.play_redirect, mov, variant)
		local sess = managers.network and managers.network:session()
		if sess and sess.send_to_peers then
			safe_call(sess.send_to_peers, sess, "play_distance_interact_redirect", unit, variant)
		end
	end
end

local function request_act(unit, variant, data)
	local mov = alive(unit) and unit:movement()
	if not (mov and not mov:chk_action_forbidden("action")) then return false end
	local brain = alive(unit) and unit:brain()
	if not (brain and brain.action_request) then return false end
	local ok = brain:action_request({ type = "act", variant = variant, body_part = 3, align_sync = true })
	if ok and data and data.internal_data then
		data.internal_data.gesture_arrest = true
	end
	return ok
end

local function shield_blocks(attacker, target_head_pos)
	if not (attacker and target_head_pos) then return false end
	if not (MASK and MASK.enemy_shield_check) then return false end
	local from = head_pos(attacker)
	if not from then return false end
	local ray = World:raycast("ray", from, target_head_pos, "ignore_unit", { attacker }, "slot_mask", MASK.enemy_shield_check)
	return ray and true or false
end

local function ensure_dyn_unit_loaded(unit_path)
	local dyn_res = managers.dyn_resource
	if not dyn_res or not unit_path then return end
	local unit_id = Idstring(unit_path)
	if not dyn_res:is_resource_ready(Idstring("unit"), unit_id, dyn_res.DYN_RESOURCES_PACKAGE) then
		safe_call(dyn_res.load, dyn_res, Idstring("unit"), unit_id, dyn_res.DYN_RESOURCES_PACKAGE)
	end
end

local function unit_team(unit)
	if not alive(unit) then return nil end
	local mov = unit:movement()
	return mov and mov.team and mov:team()
end

local function is_team_ai(unit)
	if not alive(unit) then return false end
	local groupai = managers.groupai
	if not groupai then return false end
	local state = groupai:state()
	return state and state:is_unit_team_AI(unit) or false
end

local function are_units_foes(a, b)
	local ta, tb = unit_team(a), unit_team(b)
	if not (ta and tb) then return false end
	return ta.foes and ta.foes[tb.id] or false
end

local function is_law_unit(unit)
	local t = unit_team(unit)
	return t and t.id == "law1"
end

local function get_unit_health_ratio(unit)
	if not alive(unit) then return 0 end
	local damage = unit:character_damage()
	if not damage then return 0 end
	return damage.health_ratio and damage:health_ratio() or 0
end

local function is_valid_unit(unit)
    return alive(unit) and unit:movement()
end

local function is_valid_target(attention_data)
    return attention_data and
           attention_data.identified and
           alive(attention_data.unit) and
           attention_data.reaction >= AIAttentionObject.REACT_COMBAT
end

local function is_in_grace_period(u_key, t)
    local cop_time = BB.cops_to_intimidate[u_key]
    return cop_time and (t - cop_time) < BB.grace_period
end

local function get_weapon_archetype(unit)
    local equipped_wep = unit:inventory() and unit:inventory():equipped_unit()
    if not equipped_wep then return "unknown" end

    local wep_tweak = equipped_wep:base() and equipped_wep:base()._tweak_data
    if not wep_tweak then return "unknown" end

    if wep_tweak.categories and table.contains(wep_tweak.categories, "sniper") then
        return "sniper"
    elseif wep_tweak.categories and table.contains(wep_tweak.categories, "shotgun") then
        return "shotgun"
    else
        return "rifle"
    end
end

local function calculate_threat_value(bot_unit, target_data, data)
    if not (alive(bot_unit) and target_data and target_data.unit) then
        return 0
    end

    local target_unit = target_data.unit
    local base_unit = target_unit:base()
    local dist = target_data.verified_dis or MathUtils.mvec3_distance(bot_unit:movement():m_head_pos(), target_data.m_head_pos)

    local threat = THREAT_WEIGHTS.DISTANCE_BASE / math.max(dist, 100)

    if base_unit then
        if base_unit:has_tag("tank") then
            threat = threat * (THREAT_WEIGHTS.DOZER / 10)
            local health_ratio = get_unit_health_ratio(target_unit)
            if health_ratio < 0.3 then
                threat = threat * 1.3
            end
        elseif base_unit:has_tag("spooc") then
            threat = threat * (THREAT_WEIGHTS.CLOAKER / 10)
            if dist < 1000 then
                threat = threat * 2.0
            end
        elseif base_unit:has_tag("taser") then
            local state = target_data.state or "normal"
            if state == "tasing_teammate" then
                threat = threat * (THREAT_WEIGHTS.TASER_ACTIVE / 10)
            else
                threat = threat * (THREAT_WEIGHTS.TASER / 10)
            end
        elseif base_unit:has_tag("medic") then
            threat = threat * (THREAT_WEIGHTS.MEDIC / 10)
        elseif base_unit:has_tag("sniper") then
            threat = threat * (THREAT_WEIGHTS.SNIPER / 10)
        end
    end

    if target_data.is_shield then
        threat = threat * (THREAT_WEIGHTS.SHIELD / 10)
    end

    if target_data.char_tweak and target_data.char_tweak.priority_shout then
        threat = threat * (THREAT_WEIGHTS.SPECIAL / 10)
    end

    local health_ratio = get_unit_health_ratio(target_unit)
    if health_ratio < 0.3 then
        threat = threat + THREAT_WEIGHTS.LOW_HEALTH_BONUS
    end

    local enemy_brain = target_unit:brain()
    local enemy_data = enemy_brain and enemy_brain._logic_data
    if enemy_data and enemy_data.attention_obj and enemy_data.attention_obj.u_key == data.key then
        threat = threat + THREAT_WEIGHTS.TARGETING_ME_BONUS
    end

    if dist > 3000 then
        threat = threat * 0.7
    elseif dist < 500 then
        threat = threat * 1.5
    end

    return threat
end

local function calculate_suitability(bot_unit, target_data)
    local score = 100.0
    local dist = target_data.verified_dis or MathUtils.mvec3_distance(bot_unit:movement():m_head_pos(), target_data.m_head_pos)

    local weapon_type = get_weapon_archetype(bot_unit)
    local target_unit = target_data.unit
    local is_sniper = target_unit:base() and target_unit:base():has_tag("sniper")
    local is_shield = target_data.is_shield

    if weapon_type == "sniper" then
        score = score + (is_sniper and 50 or 20)
        if dist < 800 then
            score = score - 30
        end
    elseif weapon_type == "shotgun" then
        score = score + math.max(0, 100 - dist / 10)
        if is_shield then
            score = score + 40
        end
    else
        if dist > 4000 then
            score = score - 50
        end
    end

    local bot_head_pos = bot_unit:movement():m_head_pos()
    local bot_fwd = bot_unit:movement():m_head_rot():y()
    local dir_to_target = target_data.m_head_pos - bot_head_pos
    MathUtils.mvec3_norm(dir_to_target)

    local angle = MathUtils.mvec3_dot(dir_to_target, bot_fwd)
    score = score + (angle * 50)

    if not target_data.verified then
        score = score * 0.7
    end

    if is_shield then
        local has_ap = managers.player and managers.player:has_category_upgrade("team", "crew_ai_ap_ammo")
        if has_ap or not shield_blocks(bot_unit, target_data.m_head_pos) then
            score = score + 30
        else
            score = score - 80
        end
    end

    return score
end

local BTNode = {}
BTNode.__index = BTNode

BTNode.SUCCESS = "success"
BTNode.FAILURE = "failure"
BTNode.RUNNING = "running"

function BTNode:new(name)
    local node = {
        name = name or "BTNode",
        _status = nil
    }
    setmetatable(node, self)
    return node
end

function BTNode:tick(context)
    return BTNode.FAILURE
end

function BTNode:reset()
    self._status = nil
end

local BTSequence = BTNode:new("Sequence")
BTSequence.__index = BTSequence
setmetatable(BTSequence, BTNode)

function BTSequence:new(name, children)
    local node = BTNode.new(self, name)
    node.children = children or {}
    node.current_index = 1
    return node
end

function BTSequence:tick(context)
    while self.current_index <= #self.children do
        local child = self.children[self.current_index]
        local result = child:tick(context)

        if result == BTNode.FAILURE then
            self.current_index = 1
            return BTNode.FAILURE
        elseif result == BTNode.RUNNING then
            return BTNode.RUNNING
        end

        self.current_index = self.current_index + 1
    end

    self.current_index = 1
    return BTNode.SUCCESS
end

function BTSequence:reset()
    BTNode.reset(self)
    self.current_index = 1
    for _, child in ipairs(self.children) do
        child:reset()
    end
end

local BTSelector = BTNode:new("Selector")
BTSelector.__index = BTSelector
setmetatable(BTSelector, BTNode)

function BTSelector:new(name, children)
    local node = BTNode.new(self, name)
    node.children = children or {}
    node.current_index = 1
    return node
end

function BTSelector:tick(context)
    while self.current_index <= #self.children do
        local child = self.children[self.current_index]
        local result = child:tick(context)

        if result == BTNode.SUCCESS then
            self.current_index = 1
            return BTNode.SUCCESS
        elseif result == BTNode.RUNNING then
            return BTNode.RUNNING
        end

        self.current_index = self.current_index + 1
    end

    self.current_index = 1
    return BTNode.FAILURE
end

function BTSelector:reset()
    BTNode.reset(self)
    self.current_index = 1
    for _, child in ipairs(self.children) do
        child:reset()
    end
end

local BTParallel = BTNode:new("Parallel")
BTParallel.__index = BTParallel
setmetatable(BTParallel, BTNode)

BTParallel.REQUIRE_ALL = "all"
BTParallel.REQUIRE_ONE = "one"

function BTParallel:new(name, children, policy)
    local node = BTNode.new(self, name)
    node.children = children or {}
    node.policy = policy or BTParallel.REQUIRE_ALL
    return node
end

function BTParallel:tick(context)
    local success_count = 0
    local failure_count = 0
    local running_count = 0

    for _, child in ipairs(self.children) do
        local result = child:tick(context)

        if result == BTNode.SUCCESS then
            success_count = success_count + 1
        elseif result == BTNode.FAILURE then
            failure_count = failure_count + 1
        elseif result == BTNode.RUNNING then
            running_count = running_count + 1
        end
    end

    if self.policy == BTParallel.REQUIRE_ALL then
        if success_count == #self.children then
            return BTNode.SUCCESS
        elseif failure_count > 0 then
            return BTNode.FAILURE
        end
    elseif self.policy == BTParallel.REQUIRE_ONE then
        if success_count > 0 then
            return BTNode.SUCCESS
        elseif failure_count == #self.children then
            return BTNode.FAILURE
        end
    end

    return BTNode.RUNNING
end

local BTInverter = BTNode:new("Inverter")
BTInverter.__index = BTInverter
setmetatable(BTInverter, BTNode)

function BTInverter:new(name, child)
    local node = BTNode.new(self, name)
    node.child = child
    return node
end

function BTInverter:tick(context)
    local result = self.child:tick(context)

    if result == BTNode.SUCCESS then
        return BTNode.FAILURE
    elseif result == BTNode.FAILURE then
        return BTNode.SUCCESS
    end

    return result
end

local BTRepeater = BTNode:new("Repeater")
BTRepeater.__index = BTRepeater
setmetatable(BTRepeater, BTNode)

function BTRepeater:new(name, child, count)
    local node = BTNode.new(self, name)
    node.child = child
    node.max_count = count or -1
    node.current_count = 0
    return node
end

function BTRepeater:tick(context)
    if self.max_count > 0 and self.current_count >= self.max_count then
        self.current_count = 0
        return BTNode.SUCCESS
    end

    local result = self.child:tick(context)

    if result ~= BTNode.RUNNING then
        self.current_count = self.current_count + 1
    end

    return BTNode.RUNNING
end

local BTCondition = BTNode:new("Condition")
BTCondition.__index = BTCondition
setmetatable(BTCondition, BTNode)

function BTCondition:new(name, check_func)
    local node = BTNode.new(self, name)
    node.check = check_func
    return node
end

function BTCondition:tick(context)
    return self.check(context) and BTNode.SUCCESS or BTNode.FAILURE
end

local BTAction = BTNode:new("Action")
BTAction.__index = BTAction
setmetatable(BTAction, BTNode)

function BTAction:new(name, action_func)
    local node = BTNode.new(self, name)
    node.action = action_func
    return node
end

function BTAction:tick(context)
    return self.action(context)
end

local BTCooldownCheck = BTNode:new("CooldownCheck")
BTCooldownCheck.__index = BTCooldownCheck
setmetatable(BTCooldownCheck, BTNode)

function BTCooldownCheck:new(name, data_key, cooldown_duration, time_key)
    local node = BTNode.new(self, name)
    node.data_key = data_key or "cooldown_data"
    node.cooldown_duration = cooldown_duration or 1
    node.time_key = time_key or "t"
    return node
end

function BTCooldownCheck:tick(context)
    local data = context.data and context.data.internal_data or {}
    local current_time = context[self.time_key] or game_time()
    local last_time = data[self.data_key]

    if not last_time or (current_time - last_time) >= self.cooldown_duration then
        data[self.data_key] = current_time
        return BTNode.SUCCESS
    end

    return BTNode.FAILURE
end

local BTDataCollector = BTNode:new("DataCollector")
BTDataCollector.__index = BTDataCollector
setmetatable(BTDataCollector, BTNode)

function BTDataCollector:new(name, config)
    local node = BTNode.new(self, name)
    node.source_key = config.source_key or "attention_objects"
    node.target_key = config.target_key or "collected_data"
    node.filter_func = config.filter_func or function() return true end
    node.transform_func = config.transform_func or function(item) return item end
    node.min_count = config.min_count or 0
    return node
end

function BTDataCollector:tick(context)
    local source = context[self.source_key] or {}
    local collected = {}

    for key, item in pairs(source) do
        if self.filter_func(item, context, key) then
            collected[key] = self.transform_func(item, context, key)
        end
    end

    context[self.target_key] = collected

    return (self.min_count == 0 or next(collected) ~= nil) and BTNode.SUCCESS or BTNode.FAILURE
end

local BTBestSelector = BTNode:new("BestSelector")
BTBestSelector.__index = BTBestSelector
setmetatable(BTBestSelector, BTNode)

function BTBestSelector:new(name, config)
    local node = BTNode.new(self, name)
    node.source_key = config.source_key or "candidates"
    node.score_func = config.score_func or function(item) return item.score or 0 end
    node.filter_func = config.filter_func or function() return true end
    node.result_keys = config.result_keys or {best = "selected_item", score = "selected_score"}
    node.maximize = config.maximize ~= false
    return node
end

function BTBestSelector:tick(context)
    local source = context[self.source_key] or {}
    local best_item, best_score, best_key = nil, nil, nil

    for key, item in pairs(source) do
        if self.filter_func(item, context, key) then
            local score = self.score_func(item, context, key)

            if not best_score or (self.maximize and score > best_score) or (not self.maximize and score < best_score) then
                best_score = score
                best_item = item
                best_key = key
            end
        end
    end

    if best_item then
        for result_type, context_key in pairs(self.result_keys) do
            if result_type == "best" then
                context[context_key] = best_item
            elseif result_type == "score" then
                context[context_key] = best_score
            elseif result_type == "key" then
                context[context_key] = best_key
            end
        end
        return BTNode.SUCCESS
    end

    return BTNode.FAILURE
end

local BTThresholdCheck = BTNode:new("ThresholdCheck")
BTThresholdCheck.__index = BTThresholdCheck
setmetatable(BTThresholdCheck, BTNode)

function BTThresholdCheck:new(name, config)
    local node = BTNode.new(self, name)
    node.value_func = config.value_func
    node.threshold = config.threshold
    node.operator = config.operator or ">="
    return node
end

function BTThresholdCheck:tick(context)
    local value = self.value_func(context)
    local threshold = type(self.threshold) == "function" and self.threshold(context) or self.threshold

    local result = false
    if self.operator == ">" then
        result = value > threshold
    elseif self.operator == "<" then
        result = value < threshold
    elseif self.operator == ">=" then
        result = value >= threshold
    elseif self.operator == "<=" then
        result = value <= threshold
    elseif self.operator == "==" then
        result = value == threshold
    elseif self.operator == "~=" then
        result = value ~= threshold
    end

    return result and BTNode.SUCCESS or BTNode.FAILURE
end

local BTStateCheck = BTNode:new("StateCheck")
BTStateCheck.__index = BTStateCheck
setmetatable(BTStateCheck, BTNode)

function BTStateCheck:new(name, check_funcs, mode)
    local node = BTNode.new(self, name)
    node.checks = type(check_funcs) == "table" and check_funcs or {check_funcs}
    node.mode = mode or "all"
    return node
end

function BTStateCheck:tick(context)
    if self.mode == "all" then
        for _, check_func in ipairs(self.checks) do
            if not check_func(context) then
                return BTNode.FAILURE
            end
        end
        return BTNode.SUCCESS
    else
        for _, check_func in ipairs(self.checks) do
            if check_func(context) then
                return BTNode.SUCCESS
            end
        end
        return BTNode.FAILURE
    end
end

local BTRangeFinder = BTNode:new("RangeFinder")
BTRangeFinder.__index = BTRangeFinder
setmetatable(BTRangeFinder, BTNode)

function BTRangeFinder:new(name, config)
    local node = BTNode.new(self, name)
    node.source_key = config.source_key
    node.origin_func = config.origin_func
    node.position_func = config.position_func
    node.max_distance = config.max_distance
    node.max_angle = config.max_angle
    node.direction_func = config.direction_func
    node.filter_func = config.filter_func or function() return true end
    node.result_key = config.result_key or "found_items"
    node.priority_func = config.priority_func
    return node
end

function BTRangeFinder:tick(context)
    local source = context[self.source_key] or {}
    local origin = self.origin_func(context)
    local direction = self.direction_func and self.direction_func(context)

    if not origin then
        return BTNode.FAILURE
    end

    local found = {}
    local best_item, best_priority = nil, -math.huge

    for key, item in pairs(source) do
        if self.filter_func(item, context, key) then
            local pos = self.position_func(item, context)

            if pos then
                local distance = MathUtils.mvec3_distance(origin, pos)

                if not self.max_distance or distance <= self.max_distance then
                    local valid = true

                    if self.max_angle and direction then
                        local vec = pos - origin
                        local angle = MathUtils.mvec3_angle(vec, direction)
                        valid = angle <= self.max_angle
                    end

                    if valid then
                        table.insert(found, {key = key, item = item, distance = distance})

                        if self.priority_func then
                            local priority = self.priority_func(item, context, key, distance)
                            if priority > best_priority then
                                best_priority = priority
                                best_item = item
                            end
                        end
                    end
                end
            end
        end
    end

    context[self.result_key] = found
    if self.priority_func and best_item then
        context[self.result_key .. "_best"] = best_item
    end

    return #found > 0 and BTNode.SUCCESS or BTNode.FAILURE
end

local BTCounter = BTNode:new("Counter")
BTCounter.__index = BTCounter
setmetatable(BTCounter, BTNode)

function BTCounter:new(name, config)
    local node = BTNode.new(self, name)
    node.source_key = config.source_key
    node.filter_func = config.filter_func or function() return true end
    node.count_key = config.count_key or "count"
    node.min_count = config.min_count
    node.max_count = config.max_count
    return node
end

function BTCounter:tick(context)
    local source = context[self.source_key] or {}
    local count = 0

    for key, item in pairs(source) do
        if self.filter_func(item, context, key) then
            count = count + 1
        end
    end

    context[self.count_key] = count

    local valid = true
    if self.min_count and count < self.min_count then
        valid = false
    end
    if self.max_count and count > self.max_count then
        valid = false
    end

    return valid and BTNode.SUCCESS or BTNode.FAILURE
end

local function build_target_selection_tree()
    return BTSelector:new("TargetSelection", {
        BTSequence:new("CoopTargetSelection", {
            BTCondition:new("IsCoopEnabled", function(ctx)
                return BB:get("coop", false)
            end),

            BTAction:new("UpdateTeammateStatus", function(ctx)
                if is_team_ai(ctx.unit) then
                    BB:update_teammate_status(ctx.unit)
                end
                return BTNode.SUCCESS
            end),

            BTDataCollector:new("CollectPotentialTargets", {
                source_key = "attention_objects",
                target_key = "potential_targets",
                filter_func = function(item, ctx, key)
                    return is_valid_target(item) and
                           item.verified_dis and
                           item.verified_dis > 0 and
                           not is_in_grace_period(key, ctx.t)
                end,
                transform_func = function(item, ctx, key)
                    local threat = calculate_threat_value(ctx.unit, item, ctx.data)

                    if ctx.last_target_u_key == key and
                       (ctx.t - (ctx.last_target_t or 0)) <= CONSTANTS.TARGET_SWITCH_DELAY then
                        threat = threat * 1.3
                    end

                    return {
                        data = item,
                        score = threat,
                        reaction = item.reaction
                    }
                end,
                min_count = 0
            }),

            BTSelector:new("SelectBestTarget", {
                BTSequence:new("SelectGlobalPriorityTarget", {
                    BTAction:new("GetGlobalPriorities", function(ctx)
                        ctx.global_priority_targets = BB:get_priority_targets()
                        return next(ctx.global_priority_targets) and BTNode.SUCCESS or BTNode.FAILURE
                    end),

                    BTAction:new("EvaluateGlobalTargets", function(ctx)
                        local best_target, best_score = nil, -1

                        for u_key, global_target in pairs(ctx.global_priority_targets) do
                            local local_target = ctx.potential_targets[u_key]

                            if local_target then
                                local dynamic_prio = global_target.priority

                                if global_target.state == "tasing_teammate" then
                                    dynamic_prio = dynamic_prio * 3
                                end

                                local is_dozer = global_target.unit:base() and
                                               global_target.unit:base():has_tag("tank")

                                if is_dozer then
                                    local current_attackers = BB:count_dozer_attackers(u_key)
                                    local attacker_limit = BB:get_dozer_attacker_limit(
                                        global_target.unit,
                                        local_target.data.verified_dis
                                    )

                                    if current_attackers >= attacker_limit then
                                        local already_targeting =
                                            BB.coop_data.dozer_attackers[ctx.data.key] == u_key
                                        if not already_targeting then
                                            dynamic_prio = dynamic_prio * 0.3
                                        end
                                    end
                                end

                                local allow_target = true
                                if not is_dozer and
                                   global_target.targeted_by and
                                   global_target.targeted_by ~= ctx.data.key then
                                    allow_target = false
                                end

                                if allow_target then
                                    local suitability = calculate_suitability(
                                        ctx.unit,
                                        local_target.data
                                    )

                                    if not BB:is_direction_covered(
                                        local_target.data.m_head_pos,
                                        ctx.unit
                                    ) then
                                        suitability = suitability + THREAT_WEIGHTS.DIRECTION_BONUS
                                    end

                                    local final_score = dynamic_prio * suitability

                                    if final_score > best_score then
                                        best_target = global_target
                                        best_score = final_score
                                        ctx.selected_u_key = u_key
                                        ctx.selected_target = local_target.data
                                        ctx.selected_score = local_target.score
                                        ctx.selected_reaction = local_target.reaction
                                    end
                                end
                            end
                        end

                        if best_target then
                            best_target.targeted_by = ctx.data.key
                            best_target.claimed_at = ctx.t

                            local is_dozer = best_target.unit:base() and
                                           best_target.unit:base():has_tag("tank")
                            if is_dozer then
                                BB.coop_data.dozer_attackers[ctx.data.key] = best_target.u_key
                            else
                                BB.coop_data.dozer_attackers[ctx.data.key] = nil
                            end

                            return BTNode.SUCCESS
                        end

                        return BTNode.FAILURE
                    end)
                }),

                BTAction:new("SelectLocalTarget", function(ctx)
                    local best_target, max_score = nil, -1
                    local global_priorities = BB:get_priority_targets()

                    for u_key, target in pairs(ctx.potential_targets) do
                        local g = global_priorities[u_key]
                        local is_dozer = target.data.unit:base() and
                                       target.data.unit:base():has_tag("tank")

                        local penalty = 1

                        if g and g.targeted_by and g.targeted_by ~= ctx.data.key then
                            if is_dozer then
                                local current_attackers = BB:count_dozer_attackers(u_key)
                                local attacker_limit = BB:get_dozer_attacker_limit(
                                    target.data.unit,
                                    target.data.verified_dis
                                )
                                if current_attackers >= attacker_limit then
                                    penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
                                end
                            else
                                penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
                            end
                        end

                        local effective = target.score * penalty

                        if effective > max_score then
                            max_score = effective
                            best_target = target
                            ctx.selected_u_key = u_key
                            ctx.selected_target = target.data
                            ctx.selected_score = target.score
                            ctx.selected_reaction = target.reaction
                        end
                    end

                    if best_target then
                        local is_dozer = best_target.data.unit:base() and
                                       best_target.data.unit:base():has_tag("tank")
                        if is_dozer then
                            BB.coop_data.dozer_attackers[ctx.data.key] = ctx.selected_u_key
                        else
                            BB.coop_data.dozer_attackers[ctx.data.key] = nil
                        end

                        return BTNode.SUCCESS
                    end

                    BB.coop_data.dozer_attackers[ctx.data.key] = nil
                    return BTNode.FAILURE
                end)
            }),

            BTAction:new("RecordLastTarget", function(ctx)
                if ctx.selected_target then
                    ctx.data._last_target_u_key = ctx.selected_u_key
                    ctx.data._last_target_t = ctx.t
                end
                return BTNode.SUCCESS
            end)
        }),

        BTSequence:new("SimpleTargetSelection", {
            BTDataCollector:new("CollectSimpleTargets", {
                source_key = "attention_objects",
                target_key = "potential_targets",
                filter_func = function(item, ctx, key)
                    return is_valid_target(item) and
                           item.verified_dis and
                           item.verified_dis > 0 and
                           not is_in_grace_period(key, ctx.t)
                end,
                transform_func = function(item, ctx, key)
                    local threat = calculate_threat_value(ctx.unit, item, ctx.data)

                    if ctx.last_target_u_key == key and
                       (ctx.t - (ctx.last_target_t or 0)) <= CONSTANTS.TARGET_SWITCH_DELAY then
                        threat = threat * 1.3
                    end

                    return {
                        data = item,
                        score = threat,
                        reaction = item.reaction
                    }
                end,
                min_count = 1
            }),

            BTBestSelector:new("SelectBestSimpleTarget", {
                source_key = "potential_targets",
                score_func = function(item) return item.score end,
                result_keys = {
                    best = "selected_target_obj",
                    score = "selected_score",
                    key = "selected_u_key"
                },
                maximize = true
            }),

            BTAction:new("ExtractTargetData", function(ctx)
                if ctx.selected_target_obj then
                    ctx.selected_target = ctx.selected_target_obj.data
                    ctx.selected_reaction = ctx.selected_target_obj.reaction
                    ctx.data._last_target_u_key = ctx.selected_u_key
                    ctx.data._last_target_t = ctx.t
                    return BTNode.SUCCESS
                end
                return BTNode.FAILURE
            end)
        })
    })
end

local function build_combat_behavior_tree()
    return BTSelector:new("CombatBehavior", {
        BTSequence:new("MeleeAttack", {
            BTCooldownCheck:new("CheckMeleeCooldown", "melee_t", CONSTANTS.MELEE_CHECK_INTERVAL, "t"),

            BTThresholdCheck:new("CheckLowAmmo", {
                value_func = function(ctx)
                    local unit = ctx.unit
                    if not alive(unit) then return 1 end

                    local unit_inventory = unit:inventory()
                    if not unit_inventory then return 1 end

                    local current_wep = unit_inventory:equipped_unit()
                    if not (current_wep and current_wep:base()) then return 1 end

                    local ammo_max, ammo = current_wep:base():ammo_info()
                    if not (ammo_max and ammo_max > 0) then return 1 end

                    return ammo / ammo_max
                end,
                threshold = 0.5,
                operator = "<="
            }),

            BTRangeFinder:new("FindMeleeTarget", {
                source_key = "detected_attention_objects",
                origin_func = function(ctx)
                    return ctx.unit and ctx.unit:movement() and ctx.unit:movement():m_head_pos()
                end,
                direction_func = function(ctx)
                    return ctx.unit and ctx.unit:movement() and ctx.unit:movement():m_rot():y()
                end,
                position_func = function(item) return item.m_head_pos end,
                max_distance = CONSTANTS.MELEE_DISTANCE,
                max_angle = CONSTANTS.MELEE_ANGLE,
                filter_func = function(item, ctx)
                    return item.identified and alive(item.unit) and are_units_foes(ctx.unit, item.unit)
                end,
                result_key = "melee_candidates",
                priority_func = function(item, ctx, key, distance)
                    if item.is_shield then
                        return 10
                    elseif not (item.char_tweak and item.char_tweak.priority_shout) then
                        local enemy = item.unit
                        local enemy_inventory = enemy:inventory()
                        local enemy_anim = enemy:anim_data()
                        if enemy_inventory and enemy_inventory:get_weapon() and enemy_anim and not enemy_anim.hurt then
                            return 5
                        end
                    end
                    return 0
                end
            }),

            BTAction:new("ExecuteMelee", function(ctx)
                local unit = ctx.unit
                if not alive(unit) then return BTNode.FAILURE end

                local target = ctx.melee_candidates_best
                if not target then return BTNode.FAILURE end

                local target_unit = target.unit
                local damage = target_unit:character_damage()
                if not (damage and damage._HEALTH_INIT) then return BTNode.FAILURE end

                local unit_inventory = unit:inventory()
                local current_wep = unit_inventory and unit_inventory:equipped_unit()

                local health_damage = math.ceil(damage._HEALTH_INIT / 2)
                local my_pos = unit:movement():m_head_pos()
                local vec = target.m_head_pos - my_pos
                local target_body = target_unit:body("body")
                if not target_body then return BTNode.FAILURE end

                local col_ray = {ray = -vec, body = target_body, position = target.m_head_pos}
                local damage_info = {
                    attacker_unit = unit,
                    weapon_unit = current_wep,
                    variant = target.is_shield and "melee" or "bullet",
                    damage = target.is_shield and 0 or health_damage,
                    col_ray = col_ray,
                    origin = my_pos
                }

                if target.is_shield then
                    damage_info.shield_knock = true
                    safe_call(damage.damage_melee, damage, damage_info)
                else
                    damage_info.knock_down = true
                    safe_call(damage.damage_bullet, damage, damage_info)
                end

                play_net_redirect(unit, "melee")

                return BTNode.SUCCESS
            end)
        }),

        BTSequence:new("ThrowConcussion", {
            BTCondition:new("IsConcEnabled", function(ctx)
                return BB:get("conc", false)
            end),

            BTAction:new("CheckConcCooldown", function(ctx)
                local my_data = ctx.data.internal_data or {}
                local t = ctx.t

                my_data._next_conc_eval_t = my_data._next_conc_eval_t or 0
                if t < my_data._next_conc_eval_t then
                    return BTNode.FAILURE
                end

                my_data._next_conc_eval_t = t + 1

                if my_data._conc_cooldown_t and t < my_data._conc_cooldown_t then
                    return BTNode.FAILURE
                end

                return BTNode.SUCCESS
            end),

            BTCondition:new("CheckConcResourceReady", function(ctx)
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

                return managers.dyn_resource:is_resource_ready(
                    Idstring("unit"),
                    Idstring(conc_tweak.unit),
                    managers.dyn_resource.DYN_RESOURCES_PACKAGE
                )
            end),

            BTAction:new("AnalyzeEnemyClusters", function(ctx)
                local unit = ctx.unit
                if not alive(unit) then return BTNode.FAILURE end

                local crim_mov = unit:movement()
                if not crim_mov then return BTNode.FAILURE end

                local from_pos = crim_mov:m_head_pos()
                local look_vec = crim_mov:m_rot():y()

                local close_enemies, shield_count, special_count = 0, 0, 0
                local enemy_cluster = {}

                for _, u_char in pairs(ctx.data.detected_attention_objects or {}) do
                    if u_char.identified and u_char.verified and u_char.verified_dis and u_char.verified_dis <= CONSTANTS.CONC_DISTANCE then
                        local enemy = u_char.unit
                        if alive(enemy) and are_units_foes(unit, enemy) then
                            local enemy_brain = enemy:brain()
                            if not (u_char.is_converted or (enemy_brain and enemy_brain:surrendered())) then
                                local vec = u_char.m_head_pos - from_pos
                                if vec and MathUtils.mvec3_angle(vec, look_vec) <= CONSTANTS.CONC_ANGLE then
                                    local enemy_base = enemy:base()
                                    local tweak_table = enemy_base and enemy_base._tweak_table

                                    if tweak_table and tweak_table ~= "tank" then
                                        close_enemies = close_enemies + 1

                                        if u_char.is_shield then
                                            shield_count = shield_count + 1
                                        end
                                        if u_char.char_tweak and u_char.char_tweak.priority_shout then
                                            special_count = special_count + 1
                                        end

                                        table.insert(enemy_cluster, u_char)
                                    end
                                end
                            end
                        end
                    end
                end

                local should_throw = (close_enemies >= 5) or (shield_count >= 2) or (special_count >= 2 and close_enemies >= 3)
                if not should_throw then
                    return BTNode.FAILURE
                end

                ctx.enemy_cluster = enemy_cluster
                ctx.close_enemies = close_enemies
                return BTNode.SUCCESS
            end),

            BTAction:new("FindBestCluster", function(ctx)
                local enemy_cluster = ctx.enemy_cluster
                if not enemy_cluster or #enemy_cluster == 0 then
                    return BTNode.FAILURE
                end

                local best_cluster_pos, best_cluster_count, target_unit = nil, 0, nil

                for i, u_char1 in ipairs(enemy_cluster) do
                    local cluster_count = 0

                    for j, u_char2 in ipairs(enemy_cluster) do
                        if i ~= j and u_char2.m_head_pos then
                            local dist = MathUtils.mvec3_distance(u_char1.m_head_pos, u_char2.m_head_pos)
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
                    return BTNode.FAILURE
                end

                ctx.conc_target_pos = best_cluster_pos
                ctx.conc_target_unit = target_unit
                return BTNode.SUCCESS
            end),

            BTAction:new("ThrowGrenade", function(ctx)
                local unit = ctx.unit
                if not alive(unit) then return BTNode.FAILURE end

                local target_pos = ctx.conc_target_pos
                if not target_pos then return BTNode.FAILURE end

                local conc_tweak = tweak_data.blackmarket.projectiles.concussion
                local crim_mov = unit:movement()
                local from_pos = crim_mov:m_head_pos()

                local mvec_spread_direction = target_pos - from_pos

                if ProjectileBase and ProjectileBase.spawn then
                    local cc_unit = ProjectileBase.spawn(conc_tweak.unit, from_pos, Rotation())
                    if cc_unit and cc_unit:base() then
                        MathUtils.mvec3_norm(mvec_spread_direction)
                        play_net_redirect(unit, "throw_grenade")
                        safe_say(unit, "g43", true, true)
                        cc_unit:base():throw({dir = mvec_spread_direction, owner = unit})

                        local my_data = ctx.data.internal_data or {}
                        my_data._conc_cooldown_t = ctx.t + CONSTANTS.CONC_COOLDOWN

                        return BTNode.SUCCESS
                    end
                end

                return BTNode.FAILURE
            end)
        }),

        BTSequence:new("SmartReload", {
            BTCooldownCheck:new("CheckReloadCooldown", "reload_t", CONSTANTS.RELOAD_CHECK_INTERVAL, "t"),

            BTStateCheck:new("CanReload", {
                function(ctx)
                    local unit = ctx.unit
                    if not alive(unit) then return false end
                    local unit_anim = unit:anim_data()
                    return not (unit_anim and unit_anim.reload)
                end,
                function(ctx)
                    local unit = ctx.unit
                    if not alive(unit) then return false end
                    local unit_movement = unit:movement()
                    return unit_movement and not unit_movement:chk_action_forbidden("reload")
                end
            }, "all"),

            BTAction:new("CheckAmmoAndReload", function(ctx)
                local unit = ctx.unit
                local unit_inventory = unit:inventory()
                if not unit_inventory then return BTNode.FAILURE end

                local current_wep = unit_inventory:equipped_unit()
                if not (current_wep and current_wep:base()) then return BTNode.FAILURE end

                local ammo_max, ammo = current_wep:base():ammo_info()
                if not (ammo_max and ammo_max > 0) then return BTNode.FAILURE end

                if BB:get("coop", false) then
                    local teammates_reloading = 0
                    for u_key, status in pairs(BB.coop_data.teammates_status) do
                        if u_key ~= unit:key() and status.is_reloading then
                            teammates_reloading = teammates_reloading + 1
                        end
                    end
                    if teammates_reloading >= CONSTANTS.MAX_RELOADING_TEAMMATES and ammo > 0 then
                        return BTNode.FAILURE
                    end
                end

                local nearby_threats = 0
                local closest_threat = math.huge
                for _, u_char in pairs(ctx.data.detected_attention_objects or {}) do
                    if u_char.identified and u_char.verified and alive(u_char.unit) and are_units_foes(unit, u_char.unit) then
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

                if ammo <= math.ceil(ammo_max * reload_threshold) then
                    local objective = ctx.data.objective
                    local in_cover = objective and objective.in_place
                    if in_cover or closest_threat > 1000 or ammo == 0 then
                        local brain = unit:brain()
                        if brain then
                            brain:action_request({type = "reload", body_part = 3})
                            return BTNode.SUCCESS
                        end
                    end
                end

                return BTNode.FAILURE
            end)
        })
    })
end

local function build_interaction_tree()
    return BTSequence:new("Interaction", {
        BTStateCheck:new("CanInteract", {
            function(ctx)
                local unit = ctx.unit
                if not alive(unit) then return false end
                local unit_damage = unit:character_damage()
                return not (unit_damage and unit_damage:need_revive())
            end,
            function(ctx)
                local unit = ctx.unit
                if not alive(unit) then return false end
                local anim_data = unit:anim_data()
                return not (anim_data and anim_data.tased)
            end,
            function(ctx)
                local my_data = ctx.data.internal_data or {}
                return not my_data.acting
            end,
            function(ctx)
                local unit = ctx.unit
                if not alive(unit) then return false end
                local unit_sound = unit:sound()
                return not (unit_sound and unit_sound:speaking())
            end,
            function(ctx)
                local my_data = ctx.data.internal_data or {}
                local t = ctx.t
                if my_data._intimidate_t and my_data._intimidate_t + CONSTANTS.INTIMIDATE_COOLDOWN >= t then
                    return false
                end
                my_data._intimidate_t = t
                return true
            end
        }, "all"),

        BTSelector:new("ChooseInteraction", {
            BTSequence:new("IntimidateCivilian", {
                BTAction:new("FindCivilian", function(ctx)
                    if not (TeamAILogicIdle and TeamAILogicIdle.find_civilian_to_intimidate) then
                        return BTNode.FAILURE
                    end

                    local civ = TeamAILogicIdle.find_civilian_to_intimidate(
                        ctx.unit,
                        CONSTANTS.INTIMIDATE_ANGLE,
                        CONSTANTS.INTIMIDATE_DISTANCE
                    )

                    if alive(civ) then
                        ctx.civilian_target = civ
                        return BTNode.SUCCESS
                    end

                    return BTNode.FAILURE
                end),

                BTAction:new("IntimidateCiv", function(ctx)
                    if not (TeamAILogicIdle and TeamAILogicIdle.intimidate_civilians) then
                        return BTNode.FAILURE
                    end

                    local unit = ctx.unit
                    local anim_data = unit:anim_data()
                    local carrying = unit:movement() and unit:movement():carrying_bag()
                    local allow_actions = (not anim_data.reload) and (not carrying)

                    safe_call(TeamAILogicIdle.intimidate_civilians, ctx.data, unit, true, allow_actions)
                    return BTNode.SUCCESS
                end)
            }),

            BTSequence:new("IntimidateEnemy", {
                BTAction:new("FindEnemyToIntim", function(ctx)
                    local unit = ctx.unit
                    if not (alive(unit) and unit:movement()) then
                        return BTNode.FAILURE
                    end

                    local look_vec = unit:movement():m_rot():y()
                    local has_room = managers.groupai and managers.groupai:state() and
                                   managers.groupai:state():has_room_for_police_hostage()
                    local consider_all = BB:get("dom", false)

                    local targets = {}
                    if consider_all then
                        targets = ctx.data.detected_attention_objects or {}
                    else
                        for u_key, t in pairs(BB.cops_to_intimidate or {}) do
                            if ctx.t - t < BB.grace_period then
                                local att_obj = ctx.data.detected_attention_objects and
                                              ctx.data.detected_attention_objects[u_key]
                                if att_obj then
                                    targets[u_key] = att_obj
                                end
                            end
                        end
                    end

                    local best_nmy, best_dis

                    for _, u_char in pairs(targets) do
                        if u_char and u_char.identified and u_char.verified then
                            local enemy = u_char.unit
                            if alive(enemy) then
                                if not BB:is_blacklisted_cop(enemy:key()) then
                                    local anim_data = enemy:anim_data()
                                    local is_surrender_state = anim_data and
                                                              (anim_data.hands_back or anim_data.surrender)

                                    if are_units_foes(unit, enemy) or is_surrender_state then
                                        local intim_dis = u_char.verified_dis
                                        if intim_dis and intim_dis <= CONSTANTS.INTIMIDATE_DISTANCE and u_char.m_pos then
                                            local vec = u_char.m_pos - ctx.data.m_pos
                                            if MathUtils.mvec3_angle(vec, look_vec) <= CONSTANTS.INTIMIDATE_ANGLE then
                                                local char_tweak = u_char.char_tweak
                                                if char_tweak and char_tweak.surrender and not char_tweak.priority_shout then
                                                    local enemy_inventory = enemy:inventory()
                                                    if enemy_inventory and enemy_inventory:get_weapon() and anim_data then
                                                        if has_room or is_surrender_state then
                                                            local health_ratio = get_unit_health_ratio(enemy)
                                                            local is_hurt = health_ratio < 1

                                                            local intim_priority = anim_data.hands_back and 3
                                                                or anim_data.surrender and 2
                                                                or (is_hurt and 1)

                                                            if intim_priority then
                                                                intim_dis = intim_dis / intim_priority
                                                                if (not best_dis) or best_dis > intim_dis then
                                                                    best_nmy = enemy
                                                                    best_dis = intim_dis
                                                                end
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if alive(best_nmy) then
                        ctx.enemy_to_intimidate = best_nmy
                        return BTNode.SUCCESS
                    end

                    return BTNode.FAILURE
                end),

                BTAction:new("IntimidateEnemy", function(ctx)
                    local intim_unit = ctx.enemy_to_intimidate
                    if not alive(intim_unit) then return BTNode.FAILURE end

                    if BB:is_blacklisted_cop(intim_unit:key()) then
                        return BTNode.FAILURE
                    end

                    local anim_data = intim_unit:anim_data()
                    if not anim_data then return BTNode.FAILURE end

                    local act_name, sound_name
                    if anim_data.hands_back then
                        act_name, sound_name = "arrest", "l03x_sin"
                    elseif anim_data.surrender then
                        act_name, sound_name = "arrest", "l02x_sin"
                    else
                        act_name, sound_name = "gesture_stop", "l01x_sin"
                    end

                    local unit = ctx.unit
                    if not alive(unit) then return BTNode.FAILURE end

                    safe_say(unit, sound_name, true, true)

                    local carrying = unit:movement() and unit:movement():carrying_bag()
                    local allow_actions = (not unit:anim_data().reload) and (not carrying)

                    if allow_actions then
                        request_act(unit, act_name, ctx.data)
                    end

                    BB:on_intimidation_attempt(intim_unit:key())

                    local intim_brain = intim_unit:brain()
                    if intim_brain and intim_brain.on_intimidated then
                        intim_brain:on_intimidated(1, unit)
                    end

                    return BTNode.SUCCESS
                end)
            }),

            BTSequence:new("MarkEnemy", {
                BTCondition:new("CheckMarkCooldown", function(ctx)
                    ctx.data._last_mark_t = ctx.data._last_mark_t or 0
                    return ctx.data._last_mark_t + CONSTANTS.MARK_COOLDOWN < ctx.t
                end),

                BTAction:new("FindEnemyToMark", function(ctx)
                    if not (TeamAILogicAssault and TeamAILogicAssault.find_enemy_to_mark) then
                        return BTNode.FAILURE
                    end

                    local nmy = TeamAILogicAssault.find_enemy_to_mark(
                        ctx.data.detected_attention_objects,
                        ctx.unit
                    )

                    if alive(nmy) then
                        ctx.enemy_to_mark = nmy
                        return BTNode.SUCCESS
                    end

                    return BTNode.FAILURE
                end),

                BTAction:new("MarkEnemy", function(ctx)
                    if not (TeamAILogicAssault and TeamAILogicAssault.mark_enemy) then
                        return BTNode.FAILURE
                    end

                    local unit = ctx.unit
                    local anim_data = unit:anim_data()
                    local carrying = unit:movement() and unit:movement():carrying_bag()
                    local allow_actions = (not anim_data.reload) and (not carrying)

                    safe_call(TeamAILogicAssault.mark_enemy, ctx.data, unit, ctx.enemy_to_mark, true, allow_actions)
                    ctx.data._last_mark_t = ctx.t

                    return BTNode.SUCCESS
                end)
            })
        })
    })
end

local function build_main_ai_tree()
    return BTParallel:new("MainAI", {
        build_target_selection_tree(),
        build_combat_behavior_tree(),
        build_interaction_tree()
    }, BTParallel.REQUIRE_ONE)
end


local function visualize_tree(root_node)
    local lines = {}

    local function build_node_recursive(node, prefix, is_last)
        if not node then return end

        local line_prefix = prefix .. (is_last and "`-- " or "|-- ")

        local node_type = getmetatable(node) and getmetatable(node).__index.name or "Unknown"
        local node_name = node.name or "Unnamed"

        local info = string.format("[%s] %s", node_type, node_name)

        if node_type == "Repeater" then
            local count_str = (node.max_count == -1) and "infinite" or tostring(node.max_count)
            info = info .. " (" .. count_str .. " times)"
        elseif node_type == "Parallel" then
            info = info .. " (Policy: " .. (node.policy or "N/A") .. ")"
        end

        table.insert(lines, line_prefix .. info)

        local children = {}
        if node.children then
            children = node.children
        elseif node.child then
            children = { node.child }
        end

        local child_count = #children
        if child_count > 0 then
            local next_prefix = prefix .. (is_last and "    " or "|   ")
            for i, child in ipairs(children) do
                build_node_recursive(child, next_prefix, i == child_count)
            end
        end
    end

    if not root_node then
        return "Tree is empty."
    end

    local root_type = getmetatable(root_node) and getmetatable(root_node).__index.name or "Unknown"
    table.insert(lines, string.format("[%s] %s", root_type, root_node.name))

    local children = root_node.children or (root_node.child and {root_node.child}) or {}
    local child_count = #children
    for i, child in ipairs(children) do
        build_node_recursive(child, "", i == child_count)
    end

    return table.concat(lines, "\n")
end

BB._path = ModPath
BB._data_path = SavePath .. "bb_data.txt"
BB._data = BB._data or {}
BB.cops_to_intimidate = BB.cops_to_intimidate or {}
BB.grace_period = BB.grace_period or CONSTANTS.GRACE_PERIOD
BB.dom_failures = BB.dom_failures or {}
BB.dom_blacklist = BB.dom_blacklist or {}
BB.dom_pending = BB.dom_pending or {}
BB.coop_data = BB.coop_data or {
	priority_targets = {},
	teammates_status = {},
	dozer_attackers = {},
	target_directions = {}
}

BB.behavior_trees = {
    target_selection = build_target_selection_tree(),
    combat = build_combat_behavior_tree(),
    interaction = build_interaction_tree(),
    main = build_main_ai_tree()
}
bb_log("------------Main Behavior Tree------------\n" .. visualize_tree(BB and BB.behavior_trees and BB.behavior_trees.main))

function BB:Save()
	local ok, encoded = pcall(json.encode, self._data)
	if not ok then
		bb_log("Failed to encode save data", "ERROR")
		return
	end

	local file = io.open(self._data_path, "w")
	if file then
		file:write(encoded)
		file:close()
		bb_log("Data saved")
	else
		bb_log("Failed to open save file", "ERROR")
	end
end

function BB:Load()
	local file = io.open(self._data_path, "r")
	if not file then
		bb_log("No save file found, using defaults")
		return
	end

	local raw = file:read("*all")
	file:close()

	if not raw or raw == "" then
		bb_log("Save file is empty")
		return
	end

	local ok, decoded = pcall(json.decode, raw)
	if ok and type(decoded) == "table" then
		self._data = decoded
		bb_log("Data loaded")
	else
		bb_log("Failed to decode save data", "ERROR")
	end
end

function BB:get(key, default)
	local v = self._data[key]
	return v ~= nil and v or default
end

BB:Load()

function BB:is_blacklisted_cop(u_key)
	return self.dom_blacklist and self.dom_blacklist[u_key] == true
end

function BB:clear_cop_state(u_key)
	if not u_key then return end
	self.cops_to_intimidate[u_key] = nil
	self.dom_failures[u_key] = nil
	self.dom_blacklist[u_key] = nil
	self.dom_pending[u_key] = nil
end

function BB:on_intimidation_attempt(u_key)
	if not u_key or self:is_blacklisted_cop(u_key) then return end
	self.dom_pending[u_key] = game_time()
end

function BB:on_intimidation_result(u_key, success)
	if not u_key then return end
	self.dom_pending[u_key] = nil

	if success then
		self.dom_failures[u_key] = nil
		self.dom_blacklist[u_key] = nil
		return
	end

	local rec = self.dom_failures[u_key] or { attempts = 0 }
	rec.attempts = (rec.attempts or 0) + 1
	rec.last_t = game_time()
	self.dom_failures[u_key] = rec

	if rec.attempts >= CONSTANTS.INTIMIDATE_MAX_ATTEMPTS then
		self.dom_blacklist[u_key] = true
		self.cops_to_intimidate[u_key] = nil
	end
end

function BB:add_cop_to_intimidation_list(unit_key)
	if not unit_key then return end
	if self:is_blacklisted_cop(unit_key) then return end

	local t = game_time()
	local prev_t = self.cops_to_intimidate[unit_key]
	self.cops_to_intimidate[unit_key] = t

	if not Network:is_server() then return end

	local is_new = not prev_t or (t - prev_t) > self.grace_period
	if not is_new then return end

	local function clear_attention_for_unit(unit)
		if not alive(unit) then return end
		local brain = unit:brain()
		if not (brain and brain._logic_data) then return end

		local att_obj = brain._logic_data.attention_obj
		if att_obj and att_obj.u_key == unit_key then
			if CopLogicBase and CopLogicBase._set_attention_obj then
				CopLogicBase._set_attention_obj(brain._logic_data)
			end
		end
	end

	local gstate = managers.groupai and managers.groupai:state()
	if not gstate then return end

	if gstate._ai_criminals then
		for _, sighting in pairs(gstate._ai_criminals) do
			if sighting and sighting.unit then
				clear_attention_for_unit(sighting.unit)
			end
		end
	end

	if gstate._converted_police then
		for _, unit in pairs(gstate._converted_police) do
			clear_attention_for_unit(unit)
		end
	end
end

function BB:update_teammate_status(unit)
	if not alive(unit) then return end
	if not self:get("coop", false) then return end

	local u_key = unit:key()
	local health_ratio = get_unit_health_ratio(unit)
	local unit_movement = unit:movement()
	local pos = unit_movement and unit_movement:m_head_pos()
	local t = game_time()

	local anim_data = unit:anim_data()
	local is_reloading = anim_data and anim_data.reload

	local facing_dir = unit_movement and unit_movement:m_head_rot() and unit_movement:m_head_rot():y()

	self.coop_data.teammates_status[u_key] = {
		unit = unit,
		health_ratio = health_ratio,
		position = pos,
		facing_direction = facing_dir,
		in_danger = health_ratio < 0.4,
		needs_cover = health_ratio < 0.25,
		is_reloading = is_reloading,
		last_update = t
	}
end

function BB:count_active_teammates()
	if not self:get("coop", false) then return 0 end

	local count = 0
	local t = game_time()
	for u_key, status in pairs(self.coop_data.teammates_status) do
		if alive(status.unit) and (t - status.last_update) < 2 then
			count = count + 1
		end
	end
	return count
end

function BB:get_dozer_attacker_limit(dozer_unit, dozer_distance)
	if not alive(dozer_unit) then return 1 end

	local team_size = self:count_active_teammates()
	local health_ratio = get_unit_health_ratio(dozer_unit)

	local base_limit = 1
	if team_size >= 4 then
		base_limit = 2
	elseif team_size >= 3 then
		base_limit = 1
	end

	if health_ratio < 0.3 then
		base_limit = math.max(1, base_limit - 1)
	elseif health_ratio > 0.7 and team_size >= 3 then
		base_limit = base_limit + 1
	end

	if dozer_distance and dozer_distance < 800 then
		base_limit = base_limit + 1
	elseif dozer_distance and dozer_distance > 2000 then
		base_limit = math.max(1, base_limit - 1)
	end

	return math.min(base_limit, math.max(1, math.floor(team_size / 2)))
end

function BB:count_dozer_attackers(dozer_u_key)
	if not dozer_u_key then return 0 end

	local count = 0
	local t = game_time()

	for u_key, target_u_key in pairs(self.coop_data.dozer_attackers) do
		if target_u_key == dozer_u_key then
			local teammate = self.coop_data.teammates_status[u_key]
			if teammate and alive(teammate.unit) and (t - teammate.last_update) < CONSTANTS.DOZER_FOCUS_REFRESH then
				count = count + 1
			else
				self.coop_data.dozer_attackers[u_key] = nil
			end
		end
	end

	return count
end

function BB:is_direction_covered(target_pos, my_unit)
	if not (target_pos and alive(my_unit)) then return false end

	local my_pos = my_unit:movement() and my_unit:movement():m_head_pos()
	if not my_pos then return false end

	local my_dir = target_pos - my_pos
	MathUtils.mvec3_norm(my_dir)

	local threshold = 0.7

	for u_key, status in pairs(self.coop_data.teammates_status) do
		if u_key ~= my_unit:key() and status.position and status.facing_direction then
			local other_to_target = target_pos - status.position
			MathUtils.mvec3_norm(other_to_target)

			local dot = MathUtils.mvec3_dot(my_dir, other_to_target)
			if dot > threshold then
				return true
			end
		end
	end

	return false
end

function BB:update_priority_target(unit, priority, state_info)
    if not (alive(unit) and self:get("coop", false)) then return end

    local u_key = unit:key()
    local t = game_time()

    local existing_target = self.coop_data.priority_targets[u_key]
    if existing_target then
        existing_target.priority = math.max(existing_target.priority, priority)
        existing_target.last_seen = t
        if state_info then
            existing_target.state = state_info
        end
    else
        self.coop_data.priority_targets[u_key] = {
            unit = unit,
            u_key = u_key,
            priority = priority,
            first_seen = t,
            last_seen = t,
            targeted_by = nil,
            claimed_at = 0,
            state = state_info or "normal"
        }
    end
end

function BB:get_priority_targets()
    if not self:get("coop", false) then return {} end

    local t = game_time()
    local active_targets = {}

    for u_key, target_data in pairs(self.coop_data.priority_targets) do
        if alive(target_data.unit) and (t - target_data.last_seen) < CONSTANTS.PRIORITY_TARGET_DURATION then
            if target_data.targeted_by then
                local targeting = self.coop_data.teammates_status[target_data.targeted_by]

                local claim_timed_out = (t - (target_data.claimed_at or 0)) > CONSTANTS.PRIORITY_TARGET_CLAIM_TIMEOUT
                local claim_stale = true
                if targeting and alive(targeting.unit) then
                    local lu = targeting.last_update or 0
                    claim_stale = (t - lu) > CONSTANTS.PRIORITY_TARGET_CLAIM_TIMEOUT
                end

                if claim_timed_out or claim_stale then
                    target_data.targeted_by = nil
                    target_data.claimed_at = 0
                end
            end
            active_targets[u_key] = target_data
        else
            self.coop_data.priority_targets[u_key] = nil
        end
    end

    return active_targets
end

local function remove_ai_from_bullet_mask(self, setup_data)
	local user_unit = setup_data and setup_data.user_unit
	if alive(user_unit) and is_team_ai(user_unit) and self._bullet_slotmask then
		local ai_friends_mask = MASK.criminals_no_deployables + MASK.players + MASK.hostages
		self._bullet_slotmask = self._bullet_slotmask - ai_friends_mask
	end
end

Hooks:Add("LocalizationManagerPostInit", "LocalizationManagerPostInit_BB", function(loc)
	if not loc then
		bb_log("LocalizationManager is nil", "WARN")
		return
	end

	local loc_dir = BB._path .. "loc/"
	local files_ok, files = pcall(file.GetFiles, loc_dir)

	if files_ok and files then
		local lang_key = SystemInfo:language():key()
		for _, filename in pairs(files) do
			local lang = filename:match("^(.*)%.txt$")
			if lang and Idstring(lang):key() == lang_key then
				safe_call(loc.load_localization_file, loc, loc_dir .. filename)
				break
			end
		end
	end

	safe_call(loc.load_localization_file, loc, BB._path .. "loc/english.txt", false)
end)

Hooks:Add("MenuManagerInitialize", "MenuManagerInitialize_BB", function(menu_manager)
	if not menu_manager then
		bb_log("MenuManager is nil", "WARN")
		return
	end

	local function register_toggle(cb_name, key)
		MenuCallbackHandler[cb_name] = function(self, item)
			BB._data[key] = as_bool_from_item(item)
			BB:Save()
		end
	end

	local function register_choice(cb_name, key, default_num)
		MenuCallbackHandler[cb_name] = function(self, item)
			BB._data[key] = as_number_from_item(item, default_num)
			BB:Save()
		end
	end

	register_choice("callback_health_choice", "health", 1)
	register_choice("callback_move_choice", "move", 1)
	register_choice("callback_dodge_choice", "dodge", 4)
	register_choice("callback_dmgmul_choice", "dmgmul", 5)

	register_toggle("callback_firemode_toggle", "firemode")
	register_toggle("callback_dwn_toggle", "instadwn")
	register_toggle("callback_clk_toggle", "clkarrest")
	register_toggle("callback_chat_toggle", "chat")
	register_toggle("callback_doc_toggle", "doc")
	register_toggle("callback_dom_toggle", "dom")
	register_toggle("callback_biglob_toggle", "biglob")
	register_toggle("callback_reflex_toggle", "reflex")
	register_toggle("callback_maskup_toggle", "maskup")
	register_toggle("callback_equip_toggle", "equip")
	register_toggle("callback_combat_toggle", "combat")
	register_toggle("callback_ammo_toggle", "ammo")
	register_toggle("callback_conc_toggle", "conc")
	register_toggle("callback_coop_toggle", "coop")

	if MenuHelper and MenuHelper.LoadFromJsonFile then
		MenuHelper:LoadFromJsonFile(BB._path .. "menu.txt", BB, BB._data)
	else
		bb_log("MenuHelper not found", "WARN")
	end
end)

if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
	if GroupAIStateBase then
		local is_server = Network:is_server()

		if GroupAIStateBase.init then
			local old_init = GroupAIStateBase.init
			function GroupAIStateBase:init(...)
				if is_server and BB:get("conc", false) then
					if tweak_data.blackmarket and tweak_data.blackmarket.projectiles then
						local conc_data = tweak_data.blackmarket.projectiles.concussion
						if conc_data and conc_data.unit then
							ensure_dyn_unit_loaded(conc_data.unit)
						end
					end
				end
				return old_init(self, ...)
			end
		end

		if GroupAIStateBase.chk_say_teamAI_combat_chatter then
			local old_chatter = GroupAIStateBase.chk_say_teamAI_combat_chatter
			function GroupAIStateBase:chk_say_teamAI_combat_chatter(...)
				if BB:get("chat", false) then
					return
				end
				return old_chatter(self, ...)
			end
		end

		if GroupAIStateBase.on_tase_start then
			local old_tase = GroupAIStateBase.on_tase_start
			function GroupAIStateBase:on_tase_start(cop_key, criminal_key, ...)
				if self._ai_criminals then
					local bot_record = self._ai_criminals[criminal_key]
					if bot_record and bot_record.unit then
						local cop_data = self._police and self._police[cop_key]
						local taser_unit = cop_data and cop_data.unit

						if alive(taser_unit) then
							local contour = taser_unit:contour()
							if contour and managers.player then
								local mark_id = managers.player:get_contour_for_marked_enemy()
								if not contour._contour_list or not contour:has_id(mark_id) then
									if alive(bot_record.unit) then
										safe_say(bot_record.unit, "f32x_any", true, true)
									end
									safe_call(contour.add, contour, "mark_enemy", true)
								end
							end
						end
					end
				end

				if BB:get("coop", false) then
					local cop_data = self._police and self._police[cop_key]
					local taser_unit = cop_data and cop_data.unit

					if alive(taser_unit) then
						local criminal_data = self:all_char_criminals() and self:all_char_criminals()[criminal_key]
						if criminal_data and criminal_data.unit then
							BB:update_priority_target(taser_unit, 25.0, "tasing_teammate")
						end
					end
				end

				return old_tase(self, cop_key, criminal_key, ...)
			end
		end

		function GroupAIStateBase:_get_balancing_multiplier(balance_multipliers, ...)
			local nr_crim = 0
			for _, u_data in pairs(self:all_char_criminals() or {}) do
				if not u_data.status then
					nr_crim = nr_crim + 1
				end
			end
			nr_crim = MathUtils.clamp(nr_crim, 1, 4)
			return balance_multipliers and balance_multipliers[nr_crim] or 1
		end
	end
end

if RequiredScript == "lib/units/player_team/teamaibase" then
	if TeamAIBase then
		local is_server = Network:is_server()

		if TeamAIBase.post_init then
			local old_post = TeamAIBase.post_init
			function TeamAIBase:post_init(...)
				old_post(self, ...)
				self._upgrades = self._upgrades or {}
				self._upgrade_levels = self._upgrade_levels or {}

				if is_server then
					local upgrades = {
						"intimidate_enemies", "empowered_intimidation_mul", "intimidation_multiplier",
						"civ_calming_alerts", "intimidate_aura", "civ_intimidation_mul"
					}
					for _, upgrade in ipairs(upgrades) do
						self:set_upgrade_value("player", upgrade, 1)
					end
				end
			end
		end

		function TeamAIBase:set_upgrade_value(category, upgrade, level)
			if HuskPlayerBase and HuskPlayerBase.set_upgrade_value then
				HuskPlayerBase.set_upgrade_value(self, category, upgrade, level)
			end
		end

		function TeamAIBase:upgrade_value(category, upgrade)
			return self._upgrades and self._upgrades[category] and self._upgrades[category][upgrade]
		end

		function TeamAIBase:upgrade_level(category, upgrade)
			return self._upgrade_levels and self._upgrade_levels[category] and self._upgrade_levels[category][upgrade]
		end
	end
end

if RequiredScript == "lib/units/player_team/teamaidamage" then
	if TeamAIDamage then
		if BB:get("doc", false) then
			if TeamAIDamage._apply_damage then
				local old_damage = TeamAIDamage._apply_damage
				function TeamAIDamage:_apply_damage(...)
					local damage_percent, health_subtracted = old_damage(self, ...)
					if not self._unit then return damage_percent, health_subtracted end

					local brain = self._unit:brain()
					if not (brain and brain._logic_data) then return damage_percent, health_subtracted end

					local my_data = brain._logic_data.internal_data
					if my_data and not my_data.said_hurt then
						if self._health_ratio and self._health_ratio <= 0.2 and not self:need_revive() then
							my_data.said_hurt = true
							if self._unit:sound() then
								safe_say(self._unit, "g80x_plu", true, true)
							end
						end
					end
					return damage_percent, health_subtracted
				end
			end

			if TeamAIDamage._regenerated then
				local old_regen = TeamAIDamage._regenerated
				function TeamAIDamage:_regenerated()
					if self._unit then
						local brain = self._unit:brain()
						if brain and brain._logic_data then
							local my_data = brain._logic_data.internal_data
							if my_data then
								my_data.said_hurt = false
							end
						end
					end
					return old_regen(self)
				end
			end
		end

        if TeamAIDamage._check_bleed_out then
            local old_checkbleedout = TeamAIDamage._check_bleed_out
            function TeamAIDamage:_check_bleed_out()
                if self._health <= 0 and BB:get("instadwn", false) then
                    managers.groupai:state():on_criminal_disabled(self._unit)
                    if Network:is_server() then
                        managers.groupai:state():report_criminal_downed(self._unit)
                    end

                    self:_die()

                    local dmg_info = {
                        variant = "bleeding",
                        result = {
                            type = "death"
                        }
                    }
                    self:_call_listeners(dmg_info)
                    return
                end

                return old_checkbleedout(self)
            end
        end

		function TeamAIDamage:friendly_fire_hit()
			return
		end
	end
end

if RequiredScript == "lib/units/interactions/interactionext" then
	if ReviveInteractionExt then
		if Network:is_server() then
			local function cancel_other_rescue_objectives(revive_unit, rescuer)
				if not (alive(revive_unit) and alive(rescuer)) then return end

				local gstate = managers.groupai and managers.groupai:state()
				if not (gstate and gstate.all_AI_criminals) then return end

				local revive_key = revive_unit:key()
				local rescuer_key = rescuer:key()

				for u_key, u_data in pairs(gstate:all_AI_criminals() or {}) do
					if u_key ~= rescuer_key and u_data.unit and alive(u_data.unit) then
						local brain = u_data.unit:brain()
						if brain and brain._logic_data then
							local obj = brain._logic_data.objective
							if obj and obj.type == "revive"
							   and obj.follow_unit
							   and alive(obj.follow_unit)
							   and obj.follow_unit:key() == revive_key then
								brain:set_objective(nil)
							end
						end
					end
				end
			end

			if ReviveInteractionExt._at_interact_start then
				local old_start = ReviveInteractionExt._at_interact_start
				function ReviveInteractionExt:_at_interact_start(player, ...)
					old_start(self, player, ...)
					if self.tweak_data == "revive" or self.tweak_data == "free" then
						cancel_other_rescue_objectives(self._unit, player)
					end
				end
			end
		end
	end
end

if RequiredScript == "lib/tweak_data/weapontweakdata" then
	if WeaponTweakData and WeaponTweakData.init then
		if BB:get("combat", false) then
			local old_init = WeaponTweakData.init
			function WeaponTweakData:init(...)
				old_init(self, ...)

				for k, v in pairs(self) do
					if type(v) == "table" and k:match("_crew$") then
						v.DAMAGE = 3
						if v.auto and v.auto.fire_rate then
							v.auto.fire_rate = 0.2
						end
					end
				end

				local weapon_configs = {
					{ name = "m14_crew", usage = "is_pistol", anim_usage = "is_rifle" },
					{ name = "contraband_crew", usage = "is_pistol", anim_usage = "is_rifle" },
					{ name = "sub2000_crew", usage = "is_pistol" },
					{ name = "spas12_crew", usage = "is_shotgun_mag", anim_usage = "is_shotgun_pump" },
					{ name = "ben_crew", usage = "is_shotgun_mag", anim_usage = "is_shotgun_pump" },
					{ name = "ching_crew", usage = "is_pistol", anim_usage = "is_rifle" },
					{ name = "m95_crew", usage = "rifle", anim_usage = "is_bullpup" }
				}

				for _, config in ipairs(weapon_configs) do
					if self[config.name] then
						self[config.name].usage = config.usage
						if config.anim_usage then
							self[config.name].anim_usage = config.anim_usage
						end
					end
				end
			end
		end
	end
end

if RequiredScript == "lib/managers/criminalsmanager" then
	if CriminalsManager then
		local is_offline = Global and Global.game_settings and Global.game_settings.single_player
		local is_server = Network:is_server()
		local total_chars = CriminalsManager.get_num_characters and CriminalsManager.get_num_characters() or 4

		if BB:get("biglob", false) then
			CriminalsManager.MAX_NR_TEAM_AI = total_chars
		end

		if tweak_data and tweak_data.character and tweak_data.character.presets then
			local char_preset = tweak_data.character.presets
			local health_options = { nil, 75, 144 }
			local dodge_options = { "poor", "average", "heavy", "athletic", "ninja" }

			if char_preset.gang_member_damage then
				local health_idx = BB:get("health", 1)
				if health_options[health_idx] then
					char_preset.gang_member_damage.HEALTH_INIT = health_options[health_idx]
				end
			end

			local gang_weapon = char_preset.weapon and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)
			if gang_weapon then
				local dodge_idx = BB:get("dodge", 4)
				local dodge_preset = dodge_options[dodge_idx]
				local damage_mul = BB:get("dmgmul", 5)

				for _, v in pairs(gang_weapon) do
					v.focus_delay = 0
					v.aim_delay = { 0, 0 }
					v.RELOAD_SPEED = 1

					if char_preset.weapon and char_preset.weapon.sniper and char_preset.weapon.sniper.is_rifle then
						v.range = deep_clone(char_preset.weapon.sniper.is_rifle.range)
					end

					if BB:get("combat", false) then
						v.spread = 5
						v.FALLOFF = {
							{ r = 1500, acc = {1, 1}, dmg_mul = damage_mul, recoil = {0.2, 0.2}, mode = {0, 0, 0, 1} },
							{ r = 4500, acc = {1, 1}, dmg_mul = 1, recoil = {2, 2}, mode = {0, 0, 0, 1} }
						}
					end
				end

				for _, v in pairs(tweak_data.character) do
					if type(v) == "table" and v.access == "teamAI1" then
						v.no_run_start = true
						v.no_run_stop = true
						v.always_face_enemy = true

						if char_preset.hurt_severities and char_preset.hurt_severities.only_light_hurt then
							v.damage = v.damage or {}
							v.damage.hurt_severity = char_preset.hurt_severities.only_light_hurt
						end

						if is_server and char_preset.move_speed and char_preset.move_speed.lightning then
							v.move_speed = char_preset.move_speed.lightning
						end

						local move_choice = BB:get("move", 1)
						if move_choice == 2 and dodge_preset and char_preset.dodge and char_preset.dodge[dodge_preset] then
							v.dodge = char_preset.dodge[dodge_preset]
						elseif move_choice == 3 then
							v.allowed_poses = { stand = true }
						end

						local orig_weapons = v.weapon and v.weapon.weapons_of_choice
						v.weapon = deep_clone(gang_weapon)
						if orig_weapons then
							v.weapon.weapons_of_choice = orig_weapons
						end

						if BB:get("combat", false) then
							if v.weapon.is_sniper and v.weapon.is_sniper.FALLOFF and v.weapon.is_sniper.FALLOFF[1] then
								v.weapon.is_sniper.FALLOFF[1].dmg_mul = damage_mul * 5
								v.weapon.is_sniper.FALLOFF[1].recoil = {1, 1}
							end
							if v.weapon.is_shotgun_pump and v.weapon.is_shotgun_pump.FALLOFF and v.weapon.is_shotgun_pump.FALLOFF[1] then
								v.weapon.is_shotgun_pump.FALLOFF[1].dmg_mul = damage_mul * 2.5
								v.weapon.is_shotgun_pump.FALLOFF[1].recoil = {0.5, 0.5}
							end
							if v.weapon.rifle and v.weapon.rifle.FALLOFF and v.weapon.rifle.FALLOFF[1] then
								v.weapon.rifle.FALLOFF[1].dmg_mul = damage_mul * 10
								v.weapon.rifle.FALLOFF[1].recoil = {2, 2}
							end
						end
					end
				end
			end
		end

		if is_offline and not BB:get("biglob", false) then
			if CriminalsManager.character_color_id_by_unit then
				local old_color = CriminalsManager.character_color_id_by_unit
				function CriminalsManager:character_color_id_by_unit(unit, ...)
					local char_data = self:character_data_by_unit(unit)
					if char_data and char_data.ai then
						char_data.ai_id = char_data.ai_id or (self:nr_AI_criminals() + 1)
						return char_data.ai_id
					end
					return old_color(self, unit, ...)
				end
			end
		end
	end
end

if RequiredScript == "lib/tweak_data/playertweakdata" then
	if PlayerTweakData then
		function PlayerTweakData:_set_singleplayer(...)
			return
		end
	end
end

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then
	if NewNPCRaycastWeaponBase and NewNPCRaycastWeaponBase.setup then
		local old_setup = NewNPCRaycastWeaponBase.setup
		function NewNPCRaycastWeaponBase:setup(setup_data, ...)
			old_setup(self, setup_data, ...)
			remove_ai_from_bullet_mask(self, setup_data)
		end
	end
end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
	if NPCRaycastWeaponBase and NPCRaycastWeaponBase.setup then
		local old_setup = NPCRaycastWeaponBase.setup
		function NPCRaycastWeaponBase:setup(setup_data, ...)
			old_setup(self, setup_data, ...)
			remove_ai_from_bullet_mask(self, setup_data)
		end
	end
end

if RequiredScript == "lib/units/player_team/teamaimovement" then
	if TeamAIMovement then
		if BB:get("clkarrest", false) then
			local settings = Global and Global.game_settings
			local is_private = settings and settings.permission and settings.permission ~= "public"
			local is_offline = settings and settings.single_player

			if TeamAIMovement.on_SPOOCed then
				local old_spooc = TeamAIMovement.on_SPOOCed
				function TeamAIMovement:on_SPOOCed(...)
					if is_private or is_offline then
						return self:on_cuffed()
					end
					return old_spooc(self, ...)
				end
			end
		end

		if not BotWeapons then
			if HuskPlayerMovement then
				TeamAIMovement.set_visual_carry = HuskPlayerMovement.set_visual_carry
				TeamAIMovement._destroy_current_carry_unit = HuskPlayerMovement._destroy_current_carry_unit
				TeamAIMovement._create_carry_unit = HuskPlayerMovement._create_carry_unit
			end

			if not BB:get("equip", false) then
				function TeamAIMovement:check_visual_equipment()
					if not (tweak_data.levels and managers.job) then return end

					local lvl_td = tweak_data.levels[managers.job:current_level_id()]
					local bags = { {g_medicbag = true}, {g_ammobag = true} }
					local bag = bags[math.random(#bags)]

					for k, v in pairs(bag) do
						local mesh_obj = self._unit:get_object(Idstring(k))
						if mesh_obj then
							mesh_obj:set_visibility(v)
						end
					end

					if lvl_td and not lvl_td.player_sequence and self._unit:damage() then
						safe_call(self._unit:damage().run_sequence_simple, self._unit:damage(), "var_model_02")
					end
				end
			end

			if TeamAIMovement.set_carrying_bag then
				local old_set = TeamAIMovement.set_carrying_bag
				function TeamAIMovement:set_carrying_bag(unit, ...)
					if not managers.hud then return old_set(self, unit, ...) end

					local bag_unit = unit or self._carry_unit

					if unit and unit:carry_data() then
						self:set_visual_carry(unit:carry_data():carry_id())
					else
						self:set_visual_carry(nil)
					end

					if alive(bag_unit) then
						bag_unit:set_visible(not unit)
					end

					local name_label_id = self._unit and self._unit:unit_data() and self._unit:unit_data().name_label_id
					local name_label = name_label_id and managers.hud:_get_name_label(name_label_id)
					if name_label and name_label.panel then
						local bag_panel = name_label.panel:child("bag")
						if bag_panel then
							bag_panel:set_visible(unit and true or false)
						end
					end

					return old_set(self, unit, ...)
				end
			end
		end

		if TeamAIMovement.throw_bag then
			local old_throw = TeamAIMovement.throw_bag
			function TeamAIMovement:throw_bag(...)
				if self:carrying_bag() then
					local carry_tweak = self:carry_tweak()
					if carry_tweak and managers.player then
						local data = self._ext_brain and self._ext_brain._logic_data
						local objective = data and data.objective

						if objective and objective.type == "revive" then
							local no_cooldown = managers.player.is_custom_cooldown_not_active
								and managers.player:is_custom_cooldown_not_active("team", "crew_inspire")
							if no_cooldown or carry_tweak.can_run then
								return
							end
						end
					end
				end
				return old_throw(self, ...)
			end
		end
	end
end

if RequiredScript == "lib/units/player_team/actions/lower_body/criminalactionwalk" then
	if CriminalActionWalk then
		function CriminalActionWalk:init(...)
			if CriminalActionWalk.super and CriminalActionWalk.super.init then
				return CriminalActionWalk.super.init(self, ...)
			end
		end

		local function get_bag_speed_modifier(ext_movement)
			if not (ext_movement and ext_movement:carrying_bag()) then return 1 end

			local carry_id = ext_movement:carry_id()
			if not (carry_id and tweak_data.carry) then return 1 end

			local carry_td = tweak_data.carry[carry_id]
			if not carry_td then return 1 end

			local carry_type = carry_td.type
			if carry_type and tweak_data.carry.types and tweak_data.carry.types[carry_type] then
				local move_mod = tweak_data.carry.types[carry_type].move_speed_modifier or 1
				return math.min(1, move_mod * 1.5)
			end

			return 1
		end

		function CriminalActionWalk:_get_max_walk_speed(...)
			if not (CriminalActionWalk.super and CriminalActionWalk.super._get_max_walk_speed) then
				return { 150 }
			end

			local speed = deep_clone(CriminalActionWalk.super._get_max_walk_speed(self, ...))
			local mod = get_bag_speed_modifier(self._ext_movement)

			for i = 1, #speed do
				speed[i] = speed[i] * mod
			end

			return speed
		end

		function CriminalActionWalk:_get_current_max_walk_speed(move_dir, ...)
			if not (CriminalActionWalk.super and CriminalActionWalk.super._get_current_max_walk_speed) then
				return 150
			end

			local speed = CriminalActionWalk.super._get_current_max_walk_speed(self, move_dir, ...)
			return speed * get_bag_speed_modifier(self._ext_movement)
		end
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
	if TeamAILogicIdle then
        function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
            local unit = data.unit
            if not is_valid_unit(unit) then
                return nil, nil, nil
            end

            local context = {
                unit = unit,
                data = data,
                t = data.t or game_time(),
                attention_objects = attention_objects,
                last_target_u_key = data._last_target_u_key,
                last_target_t = data._last_target_t or 0,

                selected_target = nil,
                selected_score = nil,
                selected_reaction = nil,
                selected_u_key = nil
            }

            BB.behavior_trees.target_selection:reset()
            local result = BB.behavior_trees.target_selection:tick(context)

            if result == BTNode.SUCCESS and context.selected_target then
                return context.selected_target, context.selected_score, context.selected_reaction
            end

            return nil, nil, nil
        end

		if BB:get("maskup", false) then
			if TeamAILogicIdle.on_alert then
				local old_onalert = TeamAILogicIdle.on_alert
				function TeamAILogicIdle.on_alert(data, alert_data, ...)
					if data.cool then
						local alert_type = alert_data[1]
						if CopLogicBase and CopLogicBase.is_alert_aggressive and CopLogicBase.is_alert_aggressive(alert_type) then
							local unit = data.unit
							if alive(unit) and unit:movement() then
								unit:movement():set_cool(false)
							end
						end
					end
					return old_onalert(data, alert_data, ...)
				end
			end
		end
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
	if TeamAILogicAssault then
		local math_ceil = math.ceil
		local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

		function TeamAILogicAssault.find_enemy_to_mark(enemies, my_unit)
			if not (alive(my_unit) and managers.player) then
				return nil
			end

			local unit_movement = my_unit:movement()
			if not unit_movement then
				return nil
			end

			local player_manager = managers.player
			local contour_id = player_manager.get_contour_for_marked_enemy and player_manager:get_contour_for_marked_enemy() or "mark_enemy"
			local has_ap = player_manager:has_category_upgrade("team", "crew_ai_ap_ammo") or false

			local my_head = unit_movement:m_head_pos()
			local best_unit, best_score

			for _, attention_info in pairs(enemies or {}) do
				if attention_info.identified and (attention_info.verified or attention_info.nearly_visible) then
					local att_unit = attention_info.unit
					if alive(att_unit) then
						local reaction = attention_info.reaction or AIAttentionObject.REACT_IDLE
						if reaction >= REACT_COMBAT then
							local att_base = att_unit:base()

							local is_turret = attention_info.is_deployable
							local is_special =
								(att_base and att_base.has_tag and att_base:has_tag("special"))
								or (attention_info.char_tweak and attention_info.char_tweak.priority_shout)
								or attention_info.is_shield

							if is_special or is_turret then
								local target_head = attention_info.m_head_pos
								if not target_head and att_unit.movement and att_unit:movement() then
									target_head = att_unit:movement():m_head_pos()
								end

								local dis = attention_info.verified_dis
								if not dis and target_head then
									dis = MathUtils.mvec3_distance(my_head, target_head)
								end

								if dis and dis <= CONSTANTS.MARK_DISTANCE then
									local u_contour = att_unit:contour()
									if u_contour and not (u_contour:has_id(contour_id)
										or u_contour:has_id("mark_unit_dangerous")
										or u_contour:has_id("mark_enemy")) then

										local shield_blocked = false
										if target_head then
											shield_blocked = shield_blocks(my_unit, target_head)
										end

										local can_hit = has_ap or dis <= CONSTANTS.MELEE_DISTANCE or not shield_blocked
										if (not attention_info.is_shield) or can_hit then
											local score = dis
											if attention_info.verified then score = score - 150 end
											if attention_info.is_shield then score = score - 200 end

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

        function TeamAILogicAssault.mark_enemy(data, criminal, to_mark, play_sound, play_action)
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
            local is_turret = mark_base.sentry_gun
            local is_special_enemy = (mark_base.has_tag and mark_base:has_tag("special")) or (char_tweak and char_tweak.priority_shout)

            if not is_special_enemy and not is_turret then
                return
            end

            if play_sound and criminal.sound and criminal:sound() then
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
                local prefer_id = player_manager and player_manager.get_contour_for_marked_enemy and player_manager:get_contour_for_marked_enemy() or "mark_enemy"

                local c_id = is_turret and "mark_unit_dangerous" or prefer_id

                if not contour:has_id(c_id) then
                    safe_call(contour.add, contour, c_id, true)
                end
            end

            data._ai_last_mark_t = t
        end

        if Network:is_server() then
            if TeamAILogicAssault.update then
                local old_update = TeamAILogicAssault.update
                function TeamAILogicAssault.update(data, ...)
                    local unit = data.unit

                    local context = {
                        unit = unit,
                        data = data,
                        t = game_time(),
                        detected_attention_objects = data.detected_attention_objects
                    }

                    BB.behavior_trees.combat:reset()
                    BB.behavior_trees.combat:tick(context)

                    return old_update(data, ...)
                end
            end
        end

		if TeamAILogicAssault.exit then
			local old_exit = TeamAILogicAssault.exit
			function TeamAILogicAssault.exit(data, ...)
                local context = {
                    unit = data.unit,
                    data = data,
                    t = game_time(),
                    detected_attention_objects = data.detected_attention_objects
                }

                BB.behavior_trees.combat:reset()
                BB.behavior_trees.combat:tick(context)

				return old_exit(data, ...)
			end
		end
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
	if TeamAILogicBase then
		local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

		function TeamAILogicBase._set_attention_obj(data, new_att_obj, new_reaction)
            local context = {
                unit = data.unit,
                data = data,
                t = game_time()
            }

            BB.behavior_trees.interaction:reset()
            BB.behavior_trees.interaction:tick(context)

			data.attention_obj = new_att_obj
			if new_att_obj then
				new_att_obj.reaction = new_reaction or new_att_obj.reaction
			end
		end

		function TeamAILogicBase._get_logic_state_from_reaction(data, reaction)
			return (not reaction or reaction < REACT_COMBAT) and "idle" or "assault"
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
	if CopActionShoot and CopActionShoot._get_shoot_falloff then
		if BB:get("combat", false) then
			local math_lerp = math.lerp
			local old_shoot = CopActionShoot._get_shoot_falloff
			function CopActionShoot:_get_shoot_falloff(target_dis, falloff, ...)
				if self and self._unit and alive(self._unit) and is_team_ai(self._unit) then
					local i = #falloff
					local data = falloff[i]

					for i_range = 1, #falloff do
						local range_data = falloff[i_range]
						if range_data and target_dis < range_data.r then
							i, data = i_range, range_data
							break
						end
					end

					if i > 1 then
						local prev_data = falloff[i - 1]
						local t = (target_dis - prev_data.r) / (data.r - prev_data.r)

						local n_data = {
							dmg_mul = math_lerp(prev_data.dmg_mul, data.dmg_mul, t),
							r = target_dis,
							acc = {math_lerp(prev_data.acc[1], data.acc[1], t), math_lerp(prev_data.acc[2], data.acc[2], t)},
							recoil = {math_lerp(prev_data.recoil[1], data.recoil[1], t), math_lerp(prev_data.recoil[2], data.recoil[2], t)},
							mode = data.mode
						}
						return n_data, i
					end

					return data, i
				end
				return old_shoot(self, target_dis, falloff, ...)
			end
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/copbrain" then
	if CopBrain and CopBrain.convert_to_criminal then
		local old_convert = CopBrain.convert_to_criminal
		function CopBrain:convert_to_criminal(...)
			old_convert(self, ...)
			if self._logic_data and self._logic_data.char_tweak then
				local char_tweak = deep_clone(self._logic_data.char_tweak)
				char_tweak.access = "teamAI1"
				char_tweak.always_face_enemy = true
				self._logic_data.char_tweak = char_tweak
			end
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/copdamage" then
	if CopDamage then
		if CopDamage.damage_melee then
			local old_melee = CopDamage.damage_melee
			function CopDamage:damage_melee(attack_data, ...)
				if attack_data and attack_data.variant == "taser_tased" and self._unit then
					BB:add_cop_to_intimidation_list(self._unit:key())
				end
				return old_melee(self, attack_data, ...)
			end
		end

		if CopDamage.sync_damage_melee then
			local old_sync_melee = CopDamage.sync_damage_melee
			function CopDamage:sync_damage_melee(variant, ...)
				if variant == 5 and self._unit then
					BB:add_cop_to_intimidation_list(self._unit:key())
				end
				return old_sync_melee(self, variant, ...)
			end
		end

		if BB:get("combat", false) then
			if CopDamage.damage_bullet then
				local old_bullet = CopDamage.damage_bullet
				function CopDamage:damage_bullet(attack_data, ...)
					if self._unit and alive(self._unit) and self._unit:base() and self._unit:base():has_tag("sniper") then
						if attack_data then
							local attacker_unit = attack_data.attacker_unit
							if alive(attacker_unit) and is_team_ai(attacker_unit) and self._HEALTH_INIT then
								attack_data.damage = self._HEALTH_INIT
							end
						end
					end
					return old_bullet(self, attack_data, ...)
				end
			end
		end

		if CopDamage.stun_hit then
			local old_stun = CopDamage.stun_hit
			function CopDamage:stun_hit(...)
				if self._unit and alive(self._unit) and not is_law_unit(self._unit) then
					return
				end
				return old_stun(self, ...)
			end
		end

		if CopDamage.die then
			local old_die = CopDamage.die
			function CopDamage:die(attack_data, ...)
				local unit = self._unit
				local u_key = alive(unit) and unit:key()

				if BB:get("ammo", false) and attack_data then
					local attacker_unit = attack_data.attacker_unit
					if alive(attacker_unit) and is_team_ai(attacker_unit) and self._pickup == "ammo" then
						self:set_pickup(nil)
					end
				end

				local res = old_die(self, attack_data, ...)

				if u_key then
					BB:clear_cop_state(u_key)
					if BB.coop_data and BB.coop_data.priority_targets then
						BB.coop_data.priority_targets[u_key] = nil
					end
					if BB.coop_data and BB.coop_data.dozer_attackers then
						for bot_key, target_key in pairs(BB.coop_data.dozer_attackers) do
							if target_key == u_key then
								BB.coop_data.dozer_attackers[bot_key] = nil
							end
						end
					end
				end

				return res
			end
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
	if CopLogicBase then
		if BB:get("reflex", false) then
			if CopLogicBase._upd_attention_obj_detection then
				local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
				local old_upd = CopLogicBase._upd_attention_obj_detection

				function CopLogicBase._upd_attention_obj_detection(data, min_reaction, max_reaction, ...)
					local unit = data.unit
					if alive(unit) and is_team_ai(unit) then
						local t = data.t
						local my_key = data.key
						local detected_obj = data.detected_attention_objects or {}
						local unit_mov = unit:movement()
						if not unit_mov then
							return old_upd(data, min_reaction, max_reaction, ...)
						end

						local my_pos = unit_mov:m_head_pos()
						local my_access = data.SO_access
						local my_team = data.team
						local slotmask = data.visibility_slotmask
						local my_tracker = unit_mov:nav_tracker()
						if not my_tracker then
							return old_upd(data, min_reaction, max_reaction, ...)
						end

						local chk_vis_func = my_tracker.check_visibility
						local gstate = managers.groupai and managers.groupai:state()
						if not gstate then
							return old_upd(data, min_reaction, max_reaction, ...)
						end

						local all_attention_objects = gstate:get_AI_attention_objects_by_filter(data.SO_access_str, my_team)

						for u_key, attention_info in pairs(all_attention_objects or {}) do
							if u_key ~= my_key and not detected_obj[u_key] then
								local att_tracker = attention_info.nav_tracker
								if (not att_tracker) or chk_vis_func(my_tracker, att_tracker) then
									local att_handler = attention_info.handler
									if att_handler and att_handler.get_attention then
										local settings = att_handler:get_attention(my_access, min_reaction, max_reaction, my_team)
										if settings and att_handler.get_detection_m_pos then
											local attention_pos = att_handler:get_detection_m_pos()
											if attention_pos then
												local vis_ray = World:raycast("ray", my_pos, attention_pos, "slot_mask", slotmask, "ray_type", "ai_vision")
												if not vis_ray or (vis_ray.unit and vis_ray.unit:key() == u_key) then
													if CopLogicBase._create_detected_attention_object_data then
														local att_obj = CopLogicBase._create_detected_attention_object_data(t, unit, u_key, attention_info, settings)
														if att_obj then
															local new_reaction = (settings and settings.reaction) or AIAttentionObject.REACT_IDLE

															if new_reaction < REACT_COMBAT then
																local their_team = attention_info.team
																local foes = my_team and my_team.foes
																if their_team and foes and foes[their_team.id] then
																	new_reaction = REACT_COMBAT
																end
															end

															att_obj.identified = true
															att_obj.identified_t = t
															att_obj.reaction = new_reaction
															att_obj.settings.reaction = new_reaction
															detected_obj[u_key] = att_obj
														end
													end
												end
											end
										end
									end
								end
							end
						end
					end

					return old_upd(data, min_reaction, max_reaction, ...)
				end
			end
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then
	if CopLogicIdle then
		if Network:is_server() then
			if CopLogicIdle.enter then
				local old_enter = CopLogicIdle.enter
				function CopLogicIdle.enter(data, ...)
					old_enter(data, ...)
					if data.is_converted and TeamAILogicAssault and TeamAILogicAssault.check_smart_reload then
						safe_call(TeamAILogicAssault.check_smart_reload, data)
					end
				end
			end

			if CopLogicIdle.on_intimidated then
				local old_intim = CopLogicIdle.on_intimidated
				function CopLogicIdle.on_intimidated(data, ...)
					local surrender = old_intim(data, ...)
					local unit = data.unit
					if alive(unit) then
						local u_key = unit:key()

						if BB.dom_pending and BB.dom_pending[u_key] then
							BB:on_intimidation_result(u_key, surrender and true or false)
						end

						BB:add_cop_to_intimidation_list(u_key)

						if surrender and unit:base() and unit:base().set_slot then
							unit:base():set_slot(unit, SLOTS.HOSTAGES)
							BB:clear_cop_state(u_key)
						end
					end
					return surrender
				end
			end

			if CopLogicIdle._get_priority_attention then
				local old_prio = CopLogicIdle._get_priority_attention
				function CopLogicIdle._get_priority_attention(data, attention_objects, reaction_func)
					local best_target, best_priority, best_reaction = old_prio(data, attention_objects, reaction_func)
					if data.is_converted and TeamAILogicIdle and TeamAILogicIdle._get_priority_attention then
						best_target, best_priority, best_reaction = TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
					end
					return best_target, best_priority, best_reaction
				end
			end
		end
	end
end

if RequiredScript == "lib/managers/mission/elementmissionend" then
	if ElementMissionEnd then
		local is_offline = Global and Global.game_settings and Global.game_settings.single_player

		function ElementMissionEnd:on_executed(instigator)
			if not self._values.enabled then return end
			if self._values.state ~= "none" and managers.platform and managers.platform:presence() == "Playing" then
				if self._values.state == "success" then
					local num_winners = 0
					if managers.network and managers.network:session() then
						num_winners = managers.network:session():amount_of_alive_players()
					end
					if is_offline and managers.groupai and managers.groupai:state() then
						num_winners = num_winners + managers.groupai:state():amount_of_winning_ai_criminals()
					end
					if managers.network and managers.network:session() then
						managers.network:session():send_to_peers("mission_ended", true, num_winners)
					end
					if game_state_machine and managers.player and managers.player:player_unit() then
						game_state_machine:change_state_by_name("victoryscreen", {
							num_winners = num_winners,
							personal_win = alive(managers.player:player_unit())
						})
					end
				elseif self._values.state == "failed" then
					if managers.network and managers.network:session() then
						managers.network:session():send_to_peers("mission_ended", false, 0)
					end
					if game_state_machine then
						game_state_machine:change_state_by_name("gameoverscreen")
					end
				elseif self._values.state == "leave" then
					if MenuCallbackHandler and MenuCallbackHandler.leave_mission then
						MenuCallbackHandler:leave_mission()
					end
				elseif self._values.state == "leave_safehouse" and instigator and instigator:base() and instigator:base().is_local_player then
					if MenuCallbackHandler and MenuCallbackHandler.leave_safehouse then
						MenuCallbackHandler:leave_safehouse()
					end
				end
			elseif Application:editor() and managers.editor then
				managers.editor:output_error("Cant change to state " .. tostring(self._values.state) .. " in mission end element " .. tostring(self._editor_name) .. ".")
			end
			if ElementMissionEnd.super and ElementMissionEnd.super.on_executed then
				ElementMissionEnd.super.on_executed(self, instigator)
			end
		end
	end
end
