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

dofile(ModPath .. "lua/bb_clustering.lua")
local Clustering = BB.Clustering

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

BB._path = ModPath
BB._data_path = SavePath .. "bb_data.txt"
BB._data = BB._data or {}
BB.cops_to_intimidate = BB.cops_to_intimidate or {}
BB.grace_period = BB.grace_period or CONSTANTS.GRACE_PERIOD
BB.dom_failures = BB.dom_failures or {}
BB.dom_blacklist = BB.dom_blacklist or {}
BB.dom_pending = BB.dom_pending or {}

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
    return u_key and self.dom_blacklist and self.dom_blacklist[tostring(u_key)] == true
end

function BB:clear_cop_state(u_key)
    if not u_key then
        return
    end

    u_key = tostring(u_key)

    self.cops_to_intimidate[u_key] = nil
    self.dom_failures[u_key] = nil
    self.dom_blacklist[u_key] = nil
    self.dom_pending[u_key] = nil
end

function BB:on_intimidation_attempt(u_key)
    if not u_key or self:is_blacklisted_cop(u_key) then
        return
    end

    self.dom_pending[tostring(u_key)] = game_time()
end

function BB:on_intimidation_result(u_key, success)
    if not u_key then
        return
    end

    u_key = tostring(u_key)

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
    unit_key = tostring(unit_key)
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
        if att_obj and tostring(att_obj.u_key) == unit_key then
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

dofile(ModPath .. "lua/bb_hungarian.lua")
local Hungarian = BB.Hungarian

dofile(ModPath .. "lua/bb_coop.lua")
local CoopSystem = BB.CoopSystem

dofile(ModPath .. "lua/bb_combat_behavior.lua")
local CombatBehavior = BB.CombatBehavior

dofile(ModPath .. "lua/bb_concussion.lua")
local ConcussionSystem = BB.ConcussionSystem

dofile(ModPath .. "lua/bb_intimidation_system.lua")
local IntimidationSystem = BB.IntimidationSystem

dofile(ModPath .. "lua/bb_hooks.lua")

