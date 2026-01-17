_G.BB = _G.BB or {}
local BB = _G.BB

dofile(ModPath .. "lua/bb_constants.lua")
local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local SLOTS = BB.SLOTS
local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP

dofile(ModPath .. "lua/bb_utils.lua")
local Utils = BB.Utils
local UnitOps = BB.UnitOps

dofile(ModPath .. "lua/bb_cache.lua")
local CacheManager = BB.CacheManager
local CoopCacheManager = BB.CoopCacheManager

dofile(ModPath .. "lua/bb_enemy_classifier.lua")
local EnemyClassifier = BB.EnemyClassifier

dofile(ModPath .. "lua/bb_combat_helper.lua")
local CombatHelper = BB.CombatHelper

dofile(ModPath .. "lua/bb_threat_assessment.lua")
local ThreatAssessment = BB.ThreatAssessment

local MASK = {
    AI_visibility = Utils.get_safe_mask("AI_visibility", { 1, 11, 38, 39 }),
    enemy_shield_check = Utils.get_safe_mask("enemy_shield_check", 8),
    hostages = Utils.get_safe_mask("hostages", 22),
    players = Utils.get_safe_mask("players", SLOTS.PLAYERS),
    criminals_no_deployables = Utils.get_safe_mask("criminals_no_deployables", SLOTS.CRIMINALS_NO_DEPLOYABLES),
}
BB.MASK = MASK

local bb_log = Utils.log
local safe_call = Utils.safe_call
local clamp = Utils.clamp
local game_time = Utils.game_time
local head_pos = UnitOps.head_pos
local unit_team = UnitOps.team
local is_team_ai = UnitOps.is_team_ai
local unit_has_tag = UnitOps.has_tag
local are_units_foes = UnitOps.are_foes
local is_law_unit = UnitOps.is_law_unit
local get_unit_health_ratio = UnitOps.health_ratio
local is_unit_in_slot = UnitOps.is_in_slot
local safe_say = UnitOps.say
local play_net_redirect = UnitOps.play_redirect
local request_act = UnitOps.request_act
local is_turret_unit = EnemyClassifier.is_turret
local is_shield_unit = EnemyClassifier.is_shield
local is_special_unit = EnemyClassifier.is_special
local is_dozer_unit = EnemyClassifier.is_dozer
local is_sniper_unit = EnemyClassifier.is_sniper
local is_taser_unit = EnemyClassifier.is_taser
local is_cloaker_unit = EnemyClassifier.is_cloaker
local is_medic_unit = EnemyClassifier.is_medic

local function shield_blocks(attacker, target_head_pos)
    return CombatHelper.shield_blocks(attacker, target_head_pos, MASK.enemy_shield_check)
end

local function ensure_dyn_unit_loaded(unit_path)
    return CombatHelper.ensure_dyn_unit_loaded(unit_path)
end

BB.classify_enemy = EnemyClassifier.classify

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
    target_directions = {},
}
BB._last_coop_scan = BB._last_coop_scan or {}

function BB:Save()
    local ok, encoded = safe_call(json.encode, self._data)
    if not ok then
        bb_log("Failed to encode save data", "ERROR")
        return
    end

    local file = io.open(self._data_path, "w")
    if file then
        file:write(encoded)
        file:close()
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

    local ok, decoded = safe_call(json.decode, raw)
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
    if not u_key then
        return
    end

    self.cops_to_intimidate[u_key] = nil
    self.dom_failures[u_key] = nil
    self.dom_blacklist[u_key] = nil
    self.dom_pending[u_key] = nil
end

function BB:on_intimidation_attempt(u_key)
    if not u_key or self:is_blacklisted_cop(u_key) then
        return
    end

    self.dom_pending[u_key] = game_time()
end

function BB:on_intimidation_result(u_key, success)
    if not u_key then
        return
    end

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
    if not unit_key or self:is_blacklisted_cop(unit_key) then
        return
    end

    local t = game_time()
    local prev_t = self.cops_to_intimidate[unit_key]
    self.cops_to_intimidate[unit_key] = t

    if not Network:is_server() then
        return
    end

    local is_new = not prev_t or (t - prev_t) > self.grace_period
    if not is_new then
        return
    end

    local function clear_attention_for_unit(unit)
        if not alive(unit) then
            return
        end

        local brain = unit:brain()
        if not (brain and brain._logic_data) then
            return
        end

        local att_obj = brain._logic_data.attention_obj
        if att_obj and att_obj.u_key == unit_key then
            if CopLogicBase and CopLogicBase._set_attention_obj then
                CopLogicBase._set_attention_obj(brain._logic_data, nil, nil)
            end
        end
    end

    local gstate = managers.groupai and managers.groupai:state()
    if not gstate then
        return
    end

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
    if not alive(unit) or not self:get("coop", false) then
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
        in_danger = health_ratio < 0.4,
        needs_cover = health_ratio < 0.25,
        is_reloading = is_reloading,
        last_update = t,
    }

    CoopCacheManager.teammate_status:set(u_key, status, 1)

    local original_u_key = unit:key()
    self.coop_data.teammates_status[original_u_key] = status

    return status
end

function BB:count_active_teammates()
    if not self:get("coop", false) then
        return 0
    end

    local count = 0
    local t = game_time()
    local keys = CoopCacheManager.teammate_status:keys()

    for _, u_key in ipairs(keys) do
        local status = CoopCacheManager.teammate_status:get(u_key)
        if status and status.unit and alive(status.unit) then
            count = count + 1
        else
            CoopCacheManager.teammate_status:clear(u_key)
            self.coop_data.teammates_status[u_key] = nil
        end
    end

    return count
end

function BB:get_dozer_attacker_limit(dozer_unit, dozer_distance)
    if not alive(dozer_unit) then
        return 1
    end

    local team_size = self:count_active_teammates()
    local health_ratio = get_unit_health_ratio(dozer_unit)
    local base_limit = team_size >= 4 and 2 or (team_size >= 3 and 1 or 1)

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

function BB:count_dozer_attackers(dozer_u_key)
    if not dozer_u_key then
        return 0
    end

    local count = 0
    local t = game_time()

    for u_key, target_u_key in pairs(self.coop_data.dozer_attackers) do
        if target_u_key == dozer_u_key then
            local teammate = self.coop_data.teammates_status[u_key]
            if teammate and teammate.unit and alive(teammate.unit)
                    and (t - (teammate.last_update or 0)) < CONSTANTS.DOZER_FOCUS_REFRESH
            then
                count = count + 1
            else
                self.coop_data.dozer_attackers[u_key] = nil
            end
        end
    end

    return count
end

function BB:is_direction_covered(target_pos, my_unit)
    if not (target_pos and alive(my_unit)) then
        return false
    end

    local my_pos = my_unit:movement() and my_unit:movement():m_head_pos()
    if not my_pos or mvector3.distance(target_pos, my_pos) < 0.1 then
        return false
    end

    local my_dir = target_pos - my_pos
    mvector3.normalize(my_dir)

    local same_dir_threshold = 0.75
    local face_target_threshold = 0.75

    for u_key, status in pairs(self.coop_data.teammates_status) do
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

function BB:update_priority_target(unit, priority, state_info)
    if not (alive(unit) and self:get("coop", false)) then
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
            existing_target.state = state_info
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

    self.coop_data.priority_targets[u_key] = CoopCacheManager.priority_target:get(u_key_str)
end

function BB:get_priority_targets()
    if not self:get("coop", false) then
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
                self.coop_data.priority_targets[target_data.u_key] = nil
            end
        end
    end

    return active_targets
end


local function _bb_closest_teammate_info(pos)
    if not (pos and BB.coop_data) then
        return nil, false, nil
    end

    local cache_key = string.format("%.0f_%.0f_%.0f", pos.x, pos.y, pos.z)
    local cached = CoopCacheManager.teammate_distance:get(cache_key)
    if cached then
        return cached.min_dist, cached.in_danger_any, cached.who
    end

    local t = game_time()
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

function BB:compute_dynamic_priority(my_unit, att_obj, data)
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

    local ally_dist, ally_in_danger = pos and _bb_closest_teammate_info(pos)
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

    if pos and not BB:is_direction_covered(pos, my_unit) then
        prio = prio + (THREAT_WEIGHTS.DIRECTION_BONUS / 3)
    end

    if att_obj.verified then
        prio = prio + 2
    end

    if dis > 3500 and not flags.sniper and not flags.turret then
        prio = prio * 0.8
    end

    prio = prio * team_factor
    return prio, state
end

function BB:scan_and_update_priorities(data)
    if not (self:get("coop", false) and data and data.unit and alive(data.unit)) then
        return
    end

    local t = data.t or game_time()
    local my_key = data.key
    local last = BB._last_coop_scan[my_key] or 0

    if t - last < CONSTANTS.COOP_REFRESH_INTERVAL then
        return
    end

    BB._last_coop_scan[my_key] = t

    for _, att_obj in pairs(data.detected_attention_objects or {}) do
        if att_obj.identified
                and att_obj.reaction
                and att_obj.reaction >= AIAttentionObject.REACT_COMBAT
                and att_obj.unit
                and alive(att_obj.unit)
        then
            local prio, st = self:compute_dynamic_priority(data.unit, att_obj, data)
            if prio and prio > 0 then
                self:update_priority_target(att_obj.unit, prio, st)
            end
        end
    end
end

dofile(ModPath .. "lua/bb_combat_behavior.lua")
local CombatBehavior = BB.CombatBehavior

dofile(ModPath .. "lua/bb_intimidation_system.lua")
local IntimidationSystem = BB.IntimidationSystem

dofile(ModPath .. "lua/bb_hooks.lua")

