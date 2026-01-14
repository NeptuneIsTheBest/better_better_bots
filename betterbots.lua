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

Hooks:Add("LocalizationManagerPostInit", "LocalizationManagerPostInit_BB", function(loc)
    if not loc then
        bb_log("LocalizationManager is nil", "WARN")
        return
    end

    local loc_dir = BB._path .. "loc/"
    local files_ok, files = safe_call(file.GetFiles, loc_dir)

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
        MenuCallbackHandler[cb_name] = function(_, item)
            BB._data[key] = Utils.as_bool_from_item(item)
            BB:Save()
        end
    end

    local function register_choice(cb_name, key, default_num)
        MenuCallbackHandler[cb_name] = function(_, item)
            BB._data[key] = Utils.as_number_from_item(item, default_num)
            BB:Save()
        end
    end

    register_choice("callback_health_choice", "health", 1)
    register_choice("callback_move_choice", "move", 1)
    register_choice("callback_dodge_choice", "dodge", 4)
    register_choice("callback_dmgmul_choice", "dmgmul", 5)

    local toggles = {
        "dwn",
        "clk",
        "chat",
        "doc",
        "dom",
        "biglob",
        "reflex",
        "maskup",
        "equip",
        "combat",
        "ammo",
        "conc",
        "coop",
        "keepstaying",
    }

    for _, name in ipairs(toggles) do
        local key = name == "dwn" and "instadwn"
                or (name == "clk" and "clkarrest" or name)
        register_toggle("callback_" .. name .. "_toggle", key)
    end

    if MenuHelper and MenuHelper.LoadFromJsonFile then
        MenuHelper:LoadFromJsonFile(BB._path .. "menu.txt", BB, BB._data)
    else
        bb_log("MenuHelper not found", "WARN")
    end
end)

local function remove_ai_and_players_from_bullet_mask(self)
    local user_unit = self._setup and self._setup.user_unit
    if alive(user_unit)
            and (is_unit_in_slot(user_unit, SLOTS.PLAYERS)
            or is_unit_in_slot(user_unit, SLOTS.CRIMINALS_NO_DEPLOYABLES))
            and self._bullet_slotmask
    then
        local ai_friends_mask = MASK.criminals_no_deployables + MASK.players + MASK.hostages
        self._bullet_slotmask = self._bullet_slotmask - ai_friends_mask
    end
end

if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
    if GroupAIStateBase then
        local is_server = Network:is_server()

        Hooks:PostHook(GroupAIStateBase, "init", "BB_GAISB_init_conc_preload", function(self, ...)
            if is_server and BB:get("conc", false) then
                if tweak_data.blackmarket and tweak_data.blackmarket.projectiles then
                    local conc_data = tweak_data.blackmarket.projectiles.concussion
                    if conc_data and conc_data.unit then
                        ensure_dyn_unit_loaded(conc_data.unit)
                    end
                end
            end
        end)

        local _bb_old_upd_team_AI_distance = GroupAIStateBase.upd_team_AI_distance
        function GroupAIStateBase:upd_team_AI_distance(...)
            if BB:get("keepstaying", false) then
                return
            end
            return _bb_old_upd_team_AI_distance(self, ...)
        end

        local _bb_old_chk_say_teamAI_combat_chatter = GroupAIStateBase.chk_say_teamAI_combat_chatter
        function GroupAIStateBase:chk_say_teamAI_combat_chatter(...)
            if BB:get("chat", false) then
                return
            end
            return _bb_old_chk_say_teamAI_combat_chatter(self, ...)
        end

        Hooks:PostHook(GroupAIStateBase, "on_tase_start", "BB_GAISB_on_tase_start_mark", function(self, cop_key, criminal_key, ...)
            if self._ai_criminals then
                local bot_record = self._ai_criminals[criminal_key]
                if bot_record and bot_record.unit then
                    local cop_data = self._police and self._police[cop_key]
                    local taser_unit = cop_data and cop_data.unit

                    if alive(taser_unit) then
                        local contour = taser_unit:contour()
                        if contour and managers.player then
                            local mark_id = managers.player:get_contour_for_marked_enemy()
                            if mark_id and (not contour._contour_list or not contour:has_id(mark_id)) then
                                if alive(bot_record.unit) then
                                    safe_say(bot_record.unit, "f32x_any", true, true)
                                end
                                safe_call(contour.add, contour, mark_id, true)
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
        end)

        function GroupAIStateBase:_get_balancing_multiplier(balance_multipliers, ...)
            local nr_crim = 0
            for _, u_data in pairs(self:all_char_criminals() or {}) do
                if not u_data.status then
                    nr_crim = nr_crim + 1
                end
            end

            nr_crim = clamp(nr_crim, 1, 4)
            return balance_multipliers and balance_multipliers[nr_crim] or 1
        end
    end
end

if RequiredScript == "lib/units/player_team/teamaibase" then
    if TeamAIBase then
        local is_server = Network:is_server()

        Hooks:PostHook(TeamAIBase, "post_init", "BB_TeamAIBase_post_init_upgrades", function(self, ...)
            self._upgrades = self._upgrades or {}
            self._upgrade_levels = self._upgrade_levels or {}

            if is_server then
                local upgrades = {
                    "intimidate_enemies",
                    "empowered_intimidation_mul",
                    "intimidation_multiplier",
                    "civ_calming_alerts",
                    "intimidate_aura",
                    "civ_intimidation_mul",
                }

                for _, upgrade in ipairs(upgrades) do
                    self:set_upgrade_value("player", upgrade, 1)
                end
            end
        end)

        function TeamAIBase:set_upgrade_value(category, upgrade, level)
            self._upgrades = self._upgrades or {}
            self._upgrades[category] = self._upgrades[category] or {}
            self._upgrades[category][upgrade] = level or 1

            self._upgrade_levels = self._upgrade_levels or {}
            self._upgrade_levels[category] = self._upgrade_levels[category] or {}
            self._upgrade_levels[category][upgrade] = level or 1

            if HuskPlayerBase and HuskPlayerBase.set_upgrade_value then
                safe_call(HuskPlayerBase.set_upgrade_value, self, category, upgrade, level)
            end
        end

        function TeamAIBase:upgrade_value(category, upgrade)
            return self._upgrades
                    and self._upgrades[category]
                    and self._upgrades[category][upgrade]
        end

        function TeamAIBase:upgrade_level(category, upgrade)
            return self._upgrade_levels
                    and self._upgrade_levels[category]
                    and self._upgrade_levels[category][upgrade]
        end
    end
end

if RequiredScript == "lib/units/player_team/teamaidamage" then
    if TeamAIDamage then
        Hooks:PostHook(TeamAIDamage, "_apply_damage", "BB_TeamAIDamage_apply_damage_say", function(self, ...)
            if not BB:get("doc", false) then
                return
            end

            if not self._unit then
                return
            end

            local brain = self._unit:brain()
            if not (brain and brain._logic_data) then
                return
            end

            local my_data = brain._logic_data.internal_data
            if my_data and not my_data.said_hurt then
                if self._health_ratio and self._health_ratio <= 0.2 and not self:need_revive() then
                    my_data.said_hurt = true
                    if self._unit:sound() then
                        safe_say(self._unit, "g80x_plu", true, true)
                    end
                end
            end
        end)

        Hooks:PostHook(TeamAIDamage, "_regenerated", "BB_TeamAIDamage_regenerated_reset", function(self)
            if not BB:get("doc", false) then
                return
            end

            if self._unit then
                local brain = self._unit:brain()
                if brain and brain._logic_data then
                    local my_data = brain._logic_data.internal_data
                    if my_data then
                        my_data.said_hurt = false
                    end
                end
            end
        end)

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
                        result = { type = "death" },
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
                if not (alive(revive_unit) and alive(rescuer)) then
                    return
                end

                local gstate = managers.groupai and managers.groupai:state()
                if not (gstate and gstate.all_AI_criminals) then
                    return
                end

                local revive_key = revive_unit:key()
                local rescuer_key = rescuer:key()

                for u_key, u_data in pairs(gstate:all_AI_criminals() or {}) do
                    if u_key ~= rescuer_key and u_data.unit and alive(u_data.unit) then
                        local brain = u_data.unit:brain()
                        if brain and brain._logic_data then
                            local obj = brain._logic_data.objective
                            if obj
                                    and obj.type == "revive"
                                    and obj.follow_unit
                                    and alive(obj.follow_unit)
                                    and obj.follow_unit:key() == revive_key
                            then
                                brain:set_objective(nil)
                            end
                        end
                    end
                end
            end

            Hooks:PostHook(
                    ReviveInteractionExt,
                    "_at_interact_start",
                    "BB_Revive_cancel_others",
                    function(self, player, ...)
                        if self.tweak_data == "revive" or self.tweak_data == "free" then
                            cancel_other_rescue_objectives(self._unit, player)
                        end
                    end
            )
        end
    end
end

if RequiredScript == "lib/tweak_data/weapontweakdata" then
    if WeaponTweakData and WeaponTweakData.init then
        if BB:get("combat", false) then
            Hooks:PostHook(WeaponTweakData, "init", "BB_WeaponTweak_bot_weapons", function(self, ...)
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
                    { name = "m95_crew", usage = "rifle", anim_usage = "is_bullpup" },
                }

                for _, config in ipairs(weapon_configs) do
                    if self[config.name] then
                        self[config.name].usage = config.usage
                        if config.anim_usage then
                            self[config.name].anim_usage = config.anim_usage
                        end
                    end
                end
            end)
        end
    end
end

if RequiredScript == "lib/managers/criminalsmanager" then
    if CriminalsManager then
        local is_offline = Global and Global.game_settings and Global.game_settings.single_player
        local is_server = Network:is_server()
        local total_chars = CriminalsManager.get_num_characters
                and CriminalsManager.get_num_characters()
                or 4

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

            local gang_weapon = char_preset.weapon
                    and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)

            if gang_weapon then
                local dodge_idx = BB:get("dodge", 4)
                local dodge_preset = dodge_options[dodge_idx]
                local damage_mul = BB:get("dmgmul", 5)

                for _, v in pairs(gang_weapon) do
                    v.focus_delay = 0
                    v.aim_delay = { 0, 0 }
                    v.RELOAD_SPEED = 1

                    if char_preset.weapon
                            and char_preset.weapon.sniper
                            and char_preset.weapon.sniper.is_rifle
                    then
                        v.range = deep_clone(char_preset.weapon.sniper.is_rifle.range)
                    end

                    if BB:get("combat", false) then
                        v.spread = 5
                        v.FALLOFF = {
                            {
                                r = 1500,
                                acc = { 1, 1 },
                                dmg_mul = damage_mul,
                                recoil = { 0.2, 0.2 },
                                mode = { 0, 0, 0, 1 },
                            },
                            {
                                r = 4500,
                                acc = { 1, 1 },
                                dmg_mul = 1,
                                recoil = { 2, 2 },
                                mode = { 0, 0, 0, 1 },
                            },
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
                        if move_choice == 2
                                and dodge_preset
                                and char_preset.dodge
                                and char_preset.dodge[dodge_preset]
                        then
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
                            if v.weapon.is_sniper
                                    and v.weapon.is_sniper.FALLOFF
                                    and v.weapon.is_sniper.FALLOFF[1]
                            then
                                v.weapon.is_sniper.FALLOFF[1].dmg_mul = damage_mul * 5
                                v.weapon.is_sniper.FALLOFF[1].recoil = { 1, 1 }
                            end

                            if v.weapon.is_shotgun_pump
                                    and v.weapon.is_shotgun_pump.FALLOFF
                                    and v.weapon.is_shotgun_pump.FALLOFF[1]
                            then
                                v.weapon.is_shotgun_pump.FALLOFF[1].dmg_mul = damage_mul * 2.5
                                v.weapon.is_shotgun_pump.FALLOFF[1].recoil = { 0.5, 0.5 }
                            end

                            if v.weapon.rifle
                                    and v.weapon.rifle.FALLOFF
                                    and v.weapon.rifle.FALLOFF[1]
                            then
                                v.weapon.rifle.FALLOFF[1].dmg_mul = damage_mul * 10
                                v.weapon.rifle.FALLOFF[1].recoil = { 2, 2 }
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
    Hooks:PostHook(NewNPCRaycastWeaponBase, "setup", "BB_NewNPCRaycastWeaponBase", remove_ai_and_players_from_bullet_mask)
end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
    Hooks:PostHook(NPCRaycastWeaponBase, "setup", "BB_NPCRaycastWeaponBase", remove_ai_and_players_from_bullet_mask)
end

if RequiredScript == "lib/units/player_team/teamaimovement" then
    if TeamAIMovement then
        local settings = Global and Global.game_settings
        local is_private = settings and settings.permission and settings.permission ~= "public"
        local is_offline = settings and settings.single_player

        if TeamAIMovement.on_SPOOCed then
            local old_spooc = TeamAIMovement.on_SPOOCed

            function TeamAIMovement:on_SPOOCed(...)
                if BB:get("clkarrest", false) and (is_private or is_offline) then
                    return self:on_cuffed()
                end

                return old_spooc(self, ...)
            end
        end

        if not BotWeapons then
            if HuskPlayerMovement then
                TeamAIMovement.set_visual_carry = HuskPlayerMovement.set_visual_carry
                TeamAIMovement._destroy_current_carry_unit = HuskPlayerMovement._destroy_current_carry_unit
                TeamAIMovement._create_carry_unit = HuskPlayerMovement._create_carry_unit
            end

            local orig_check_visual_equipment = TeamAIMovement.check_visual_equipment

            function TeamAIMovement:check_visual_equipment(...)
                if BB:get("equip", false) and orig_check_visual_equipment then
                    return orig_check_visual_equipment(self, ...)
                end

                if not (tweak_data.levels and managers.job) then
                    return
                end

                local lvl_td = tweak_data.levels[managers.job:current_level_id()]
                local bags = {
                    { g_medicbag = true },
                    { g_ammobag = true },
                }
                local bag = bags[math.random(#bags)]

                for k, v in pairs(bag) do
                    local mesh_obj = self._unit:get_object(Idstring(k))
                    if mesh_obj then
                        mesh_obj:set_visibility(v)
                    end
                end

                if lvl_td and not lvl_td.player_sequence then
                    local damage_ext = self._unit:damage()
                    if damage_ext then
                        safe_call(damage_ext.run_sequence_simple, damage_ext, "var_model_02")
                    end
                end
            end

            if TeamAIMovement.set_carrying_bag then
                Hooks:PostHook(
                        TeamAIMovement,
                        "set_carrying_bag",
                        "BB_TeamAIMovement_set_carrying_bag_label",
                        function(self, unit, ...)
                            if not managers.hud then
                                return
                            end

                            local bag_unit = unit or self._carry_unit

                            if unit and unit:carry_data() then
                                self:set_visual_carry(unit:carry_data():carry_id())
                            else
                                self:set_visual_carry(nil)
                            end

                            if alive(bag_unit) then
                                bag_unit:set_visible(not unit)
                            end

                            local name_label_id = self._unit
                                    and self._unit:unit_data()
                                    and self._unit:unit_data().name_label_id

                            local name_label = name_label_id
                                    and managers.hud:_get_name_label(name_label_id)

                            if name_label and name_label.panel then
                                local bag_panel = name_label.panel:child("bag")
                                if bag_panel then
                                    bag_panel:set_visible(unit and true or false)
                                end
                            end
                        end
                )
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
        local function get_bag_speed_modifier(ext_movement)
            if not (ext_movement and ext_movement:carrying_bag()) then
                return 1
            end

            local carry_id = ext_movement:carry_id()
            if not (carry_id and tweak_data.carry) then
                return 1
            end

            local carry_td = tweak_data.carry[carry_id]
            if not carry_td then
                return 1
            end

            local carry_type = carry_td.type
            if carry_type and tweak_data.carry.types and tweak_data.carry.types[carry_type] then
                local move_mod = tweak_data.carry.types[carry_type].move_speed_modifier or 1
                return math.min(1, move_mod * 1.5)
            end

            return 1
        end

        local old_get_max_walk_speed = CriminalActionWalk._get_max_walk_speed
        function CriminalActionWalk:_get_max_walk_speed(...)
            if not old_get_max_walk_speed then
                return { 150 }
            end

            local speed = deep_clone(old_get_max_walk_speed(self, ...))
            local mod = get_bag_speed_modifier(self._ext_movement)

            for i = 1, #speed do
                speed[i] = speed[i] * mod
            end

            return speed
        end

        local old_get_current_max_walk_speed = CriminalActionWalk._get_current_max_walk_speed
        function CriminalActionWalk:_get_current_max_walk_speed(move_dir, ...)
            if not old_get_current_max_walk_speed then
                return 150
            end

            local speed = old_get_current_max_walk_speed(self, move_dir, ...)
            return speed * get_bag_speed_modifier(self._ext_movement)
        end
    end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
    if TeamAILogicIdle then
        local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

        function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
            local unit = data.unit
            if not (alive(unit) and unit:movement()) then
                return
            end

            local t = data.t or game_time()
            local is_team_ai_unit = is_team_ai(unit)

            if BB:get("coop", false) and is_team_ai_unit then
                BB:update_teammate_status(unit)
                safe_call(BB.scan_and_update_priorities, BB, data)
            end

            local old_target_u_key = data._last_target_u_key
            local last_target_t = data._last_target_t or 0

            local potential_targets_map = {}
            for u_key, attention_data in pairs(attention_objects or {}) do
                if attention_data.identified
                        and alive(attention_data.unit)
                        and attention_data.reaction >= REACT_COMBAT
                then
                    local dist = attention_data.verified_dis
                    if dist and dist > 0 then
                        local dom_active = BB.cops_to_intimidate[u_key]
                                and (t - BB.cops_to_intimidate[u_key] < BB.grace_period)

                        if dom_active and IntimidationSystem.is_valid_target then
                            if not IntimidationSystem.is_valid_target(attention_data.unit, data, dist, false) then
                                dom_active = false
                            end
                        end

                        if not dom_active then
                            local threat = ThreatAssessment.calculate_threat_value(unit, attention_data, data)

                            if old_target_u_key
                                    and old_target_u_key == u_key
                                    and (t - last_target_t) <= CONSTANTS.TARGET_SWITCH_DELAY
                            then
                                threat = threat * 1.3
                            end

                            potential_targets_map[u_key] = {
                                data = attention_data,
                                score = threat,
                                reaction = attention_data.reaction,
                            }
                        end
                    end
                end
            end

            local lock_active = data._target_lock_until and (t < data._target_lock_until)

            if lock_active and old_target_u_key and potential_targets_map[old_target_u_key] then
                local locked = potential_targets_map[old_target_u_key]
                data._last_target_u_key = locked.data.u_key
                data._last_target_t = t
                return locked.data, 400 / math.max(locked.score or 1, 1), locked.reaction
            end

            if not BB:get("coop", false) then
                local best_local_target
                local max_score = 0

                for _, target in pairs(potential_targets_map) do
                    if target.score > max_score then
                        max_score = target.score
                        best_local_target = target
                    end
                end

                if best_local_target then
                    data._last_target_u_key = best_local_target.data.u_key
                    data._last_target_t = t

                    if old_target_u_key ~= data._last_target_u_key then
                        data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
                    end

                    return best_local_target.data, 500 / math.max(max_score, 1), best_local_target.reaction
                end

                return nil, nil, nil
            end

            local global_priority_targets = BB:get_priority_targets()
            local best_coop_target
            local best_coop_score = -1

            for u_key, global_target in pairs(global_priority_targets) do
                local local_target_info = potential_targets_map[u_key]
                if local_target_info then
                    local dynamic_prio = global_target.priority
                    if global_target.state == "tasing_teammate" then
                        dynamic_prio = dynamic_prio * 3
                    end

                    local target_unit = global_target.unit
                    local is_turret = EnemyClassifier.is_turret(target_unit)
                    local is_dozer = EnemyClassifier.is_dozer(target_unit)

                    if is_dozer and not is_turret then
                        local current_attackers = BB:count_dozer_attackers(u_key)
                        local attacker_limit = BB:get_dozer_attacker_limit(
                                global_target.unit,
                                local_target_info.data.verified_dis
                        )

                        if current_attackers >= attacker_limit then
                            local already_targeting = BB.coop_data.dozer_attackers[data.key] == u_key
                            if not already_targeting then
                                dynamic_prio = dynamic_prio * 0.3
                            end
                        end
                    end

                    local allow_target = true
                    if not is_dozer
                            and not is_turret
                            and global_target.targeted_by
                            and global_target.targeted_by ~= data.key
                    then
                        allow_target = false
                    end

                    if allow_target then
                        local suitability = ThreatAssessment.calculate_suitability(unit, local_target_info.data)

                        if not BB:is_direction_covered(local_target_info.data.m_head_pos, unit) then
                            suitability = suitability + THREAT_WEIGHTS.DIRECTION_BONUS
                        end

                        local final_score = dynamic_prio * suitability
                        if final_score > best_coop_score then
                            best_coop_target = global_target
                            best_coop_score = final_score
                        end
                    end
                end
            end

            if best_coop_target then
                best_coop_target.targeted_by = data.key
                best_coop_target.claimed_at = t

                local target_unit = best_coop_target.unit
                local is_turret = EnemyClassifier.is_turret(target_unit)
                local is_dozer = EnemyClassifier.is_dozer(target_unit)

                if is_dozer and not is_turret then
                    BB.coop_data.dozer_attackers[data.key] = best_coop_target.u_key
                else
                    BB.coop_data.dozer_attackers[data.key] = nil
                end

                local local_data = potential_targets_map[best_coop_target.u_key]
                data._last_target_u_key = best_coop_target.u_key
                data._last_target_t = t

                if old_target_u_key ~= data._last_target_u_key then
                    data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
                end

                return local_data.data, 300 / math.max(best_coop_score, 1), local_data.reaction
            end

            local best_local_target
            local max_score = 0

            for u_key, target in pairs(potential_targets_map) do
                local g = global_priority_targets[u_key]
                local target_unit = target.data.unit
                local is_turret = EnemyClassifier.is_turret(target_unit)
                local is_dozer = EnemyClassifier.is_dozer(target_unit)

                local penalty = 1
                if g and g.targeted_by and g.targeted_by ~= data.key then
                    if is_dozer and not is_turret then
                        local current_attackers = BB:count_dozer_attackers(u_key)
                        local attacker_limit = BB:get_dozer_attacker_limit(
                                target.data.unit,
                                target.data.verified_dis
                        )
                        if current_attackers >= attacker_limit then
                            penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
                        end
                    elseif not is_turret then
                        penalty = THREAT_WEIGHTS.SAME_TARGET_PENALTY
                    end
                end

                local effective = target.score * penalty
                if effective > max_score then
                    max_score = effective
                    best_local_target = target
                end
            end

            if best_local_target then
                local target_unit = best_local_target.data.unit
                local is_turret = EnemyClassifier.is_turret(target_unit)
                local is_dozer = EnemyClassifier.is_dozer(target_unit)

                if is_dozer and not is_turret then
                    BB.coop_data.dozer_attackers[data.key] = best_local_target.data.u_key
                else
                    BB.coop_data.dozer_attackers[data.key] = nil
                end

                data._last_target_u_key = best_local_target.data.u_key
                data._last_target_t = t

                if old_target_u_key ~= data._last_target_u_key then
                    data._target_lock_until = t + CONSTANTS.TARGET_LOCK_MIN
                end

                return best_local_target.data, 500 / math.max(max_score, 1), best_local_target.reaction
            end

            BB.coop_data.dozer_attackers[data.key] = nil
            return nil, nil, nil
        end

        Hooks:PreHook(
                TeamAILogicIdle,
                "on_alert",
                "BB_TeamAILogicIdle_on_alert_maskup",
                function(data, alert_data, ...)
                    if not BB:get("maskup", false) then
                        return
                    end

                    if data.cool then
                        local alert_type = alert_data[1]
                        if CopLogicBase
                                and CopLogicBase.is_alert_aggressive
                                and CopLogicBase.is_alert_aggressive(alert_type)
                        then
                            local unit = data.unit
                            if alive(unit) and unit:movement() then
                                unit:movement():set_cool(false)
                            end
                        end
                    end
                end
        )
    end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
    if TeamAILogicAssault then
        TeamAILogicAssault.find_enemy_to_mark = CombatBehavior.find_enemy_to_mark
        TeamAILogicAssault.mark_enemy = CombatBehavior.mark_enemy
        TeamAILogicAssault.check_smart_reload = CombatBehavior.check_smart_reload

        if Network:is_server() then
            Hooks:PostHook(
                    TeamAILogicAssault,
                    "update",
                    "BB_TeamAILogicAssault_extra_update",
                    function(data, ...)
                        local t = game_time()
                        local my_data = data.internal_data or {}
                        local unit = data.unit

                        if BB:get("coop", false) and is_team_ai(unit) then
                            BB:update_teammate_status(unit)
                        end

                        my_data._next_conc_eval_t = my_data._next_conc_eval_t or 0
                        if t >= my_data._next_conc_eval_t then
                            my_data._next_conc_eval_t = t + 1
                            if (not my_data._conc_cooldown_t) or t >= my_data._conc_cooldown_t then
                                local success, thrown = safe_call(CombatBehavior.throw_concussion_grenade, data, unit)
                                if success and thrown then
                                    my_data._conc_cooldown_t = t + CONSTANTS.CONC_COOLDOWN
                                end
                            end
                        end

                        if (not my_data.melee_t) or (my_data.melee_t + CONSTANTS.MELEE_CHECK_INTERVAL < t) then
                            my_data.melee_t = t
                            safe_call(CombatBehavior.execute_melee_attack, data, unit)
                        end

                        if (not my_data.reload_t) or (my_data.reload_t + CONSTANTS.RELOAD_CHECK_INTERVAL < t) then
                            my_data.reload_t = t
                            safe_call(CombatBehavior.check_smart_reload, data)
                        end

                        safe_call(BB.scan_and_update_priorities, BB, data)
                    end
            )

            Hooks:PostHook(
                    TeamAILogicAssault,
                    "update",
                    "BB_TeamAILogicAssault_cache_cleanup",
                    function(data, ...)
                        local t = game_time()
                        local my_data = data.internal_data or {}

                        my_data._next_cache_cleanup_t = my_data._next_cache_cleanup_t or 0
                        if t >= my_data._next_cache_cleanup_t then
                            my_data._next_cache_cleanup_t = t + 10
                            CoopCacheManager.cleanup_all()
                        end
                    end
            )
        end

        Hooks:PostHook(TeamAILogicAssault, "exit", "BB_TeamAILogicAssault_exit_reload", function(data, ...)
            safe_call(CombatBehavior.check_smart_reload, data)
        end)
    end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
    if TeamAILogicBase then
        local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

        Hooks:PostHook(
                TeamAILogicBase,
                "_set_attention_obj",
                "BB_TeamAILogicBase_post_set_attention",
                function(data, new_att_obj, new_reaction)
                    safe_call(IntimidationSystem.perform_interaction_check, data)
                end
        )

        function TeamAILogicBase._get_logic_state_from_reaction(data, reaction)
            return (not reaction or reaction < REACT_COMBAT) and "idle" or "assault"
        end
    end
end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
    if CopActionShoot and CopActionShoot._get_shoot_falloff then
        local old_shoot = CopActionShoot._get_shoot_falloff

        function CopActionShoot:_get_shoot_falloff(target_dis, falloff, ...)
            if not BB:get("combat", false)
                    or not (self and self._unit and alive(self._unit) and is_team_ai(self._unit))
            then
                return old_shoot(self, target_dis, falloff, ...)
            end

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
                    dmg_mul = math.lerp(prev_data.dmg_mul, data.dmg_mul, t),
                    r = target_dis,
                    acc = {
                        math.lerp(prev_data.acc[1], data.acc[1], t),
                        math.lerp(prev_data.acc[2], data.acc[2], t),
                    },
                    recoil = {
                        math.lerp(prev_data.recoil[1], data.recoil[1], t),
                        math.lerp(prev_data.recoil[2], data.recoil[2], t),
                    },
                    mode = data.mode,
                }

                return n_data, i
            end

            return data, i
        end
    end
end

if RequiredScript == "lib/units/enemies/cop/copbrain" then
    if CopBrain and CopBrain.convert_to_criminal then
        Hooks:PostHook(CopBrain, "convert_to_criminal", "BB_CopBrain_post_convert_tweak", function(self, ...)
            if self._logic_data and self._logic_data.char_tweak then
                local char_tweak = deep_clone(self._logic_data.char_tweak)
                char_tweak.access = "teamAI1"
                char_tweak.always_face_enemy = true
                self._logic_data.char_tweak = char_tweak
            end
        end)
    end
end

if RequiredScript == "lib/units/enemies/cop/copdamage" then
    if CopDamage then
        local function handle_taser_damage(self, variant)
            if variant == "taser_tased" or variant == 5 then
                if self._unit then
                    local flags = BB.classify_enemy(self._unit)
                    if not flags.taser then
                        BB:add_cop_to_intimidation_list(self._unit:key())
                    end
                end
            end
        end

        if CopDamage.damage_melee then
            Hooks:PostHook(
                    CopDamage,
                    "damage_melee",
                    "BB_CopDamage_PostDamageMelee_IntimList",
                    function(self, attack_data, ...)
                        if attack_data then
                            handle_taser_damage(self, attack_data.variant)
                        end
                    end
            )
        end

        if CopDamage.sync_damage_melee then
            Hooks:PostHook(
                    CopDamage,
                    "sync_damage_melee",
                    "BB_CopDamage_PostSyncDamageMelee_IntimList",
                    function(self, variant, ...)
                        handle_taser_damage(self, variant)
                    end
            )
        end

        if CopDamage.damage_bullet then
            Hooks:PreHook(
                    CopDamage,
                    "damage_bullet",
                    "BB_CopDamage_damage_bullet_combat",
                    function(self, attack_data, ...)
                        if BB:get("combat", false) and self._unit and alive(self._unit) then
                            if UnitOps.has_tag(self._unit, "sniper") then
                                if attack_data then
                                    local attacker_unit = attack_data.attacker_unit
                                    if alive(attacker_unit)
                                            and is_team_ai(attacker_unit)
                                            and self._HEALTH_INIT
                                    then
                                        attack_data.damage = self._HEALTH_INIT
                                    end
                                end
                            end
                        end
                    end
            )
        end

        if CopDamage.stun_hit then
            local old_stun = CopDamage.stun_hit

            CopDamage.stun_hit = function(self, ...)
                if self._unit and alive(self._unit) and not is_law_unit(self._unit) then
                    return
                end
                return old_stun(self, ...)
            end
        end

        Hooks:PreHook(
                CopDamage,
                "die",
                "BB_CopDamage_die_pre_pickup",
                function(self, attack_data, ...)
                    if BB:get("ammo", false) and attack_data then
                        local attacker_unit = attack_data.attacker_unit
                        if alive(attacker_unit)
                                and is_team_ai(attacker_unit)
                                and self._pickup == "ammo"
                        then
                            self:set_pickup(nil)
                        end
                    end
                end
        )

        Hooks:PostHook(
                CopDamage,
                "die",
                "BB_CopDamage_die_post_cleanup",
                function(self, attack_data, ...)
                    local unit = self._unit
                    local u_key = alive(unit) and unit:key()

                    if u_key then
                        local u_key_str = tostring(u_key)

                        BB:clear_cop_state(u_key)

                        if EnemyClassifier._cache_manager then
                            EnemyClassifier._cache_manager:clear(u_key_str)
                        end

                        CoopCacheManager.priority_target:clear(u_key_str)

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
                end
        )
    end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
    if CopLogicBase then
        local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

        Hooks:PreHook(
                CopLogicBase,
                "_upd_attention_obj_detection",
                "BB_CopLogicBase_pre_fast_detect",
                function(data, min_reaction, max_reaction, ...)
                    if not BB:get("reflex", false) then
                        return
                    end

                    local unit = data.unit
                    if alive(unit) and is_team_ai(unit) then
                        local t = data.t
                        local my_key = data.key
                        local detected_obj = data.detected_attention_objects or {}
                        data.detected_attention_objects = detected_obj

                        local unit_mov = unit:movement()
                        if not unit_mov then
                            return
                        end

                        local my_pos = unit_mov:m_head_pos()
                        local my_access = data.SO_access
                        local my_team = data.team
                        local slotmask = data.visibility_slotmask
                        local my_tracker = unit_mov:nav_tracker()
                        if not my_tracker then
                            return
                        end

                        local chk_vis_func = my_tracker.check_visibility
                        local gstate = managers.groupai and managers.groupai:state()
                        if not gstate then
                            return
                        end

                        local all_attention_objects = gstate:get_AI_attention_objects_by_filter(
                                data.SO_access_str,
                                my_team
                        )

                        for u_key, attention_info in pairs(all_attention_objects or {}) do
                            if u_key ~= my_key and not detected_obj[u_key] then
                                local att_tracker = attention_info.nav_tracker
                                if (not att_tracker) or chk_vis_func(my_tracker, att_tracker) then
                                    local att_handler = attention_info.handler
                                    if att_handler and att_handler.get_attention then
                                        local settings = att_handler:get_attention(
                                                my_access,
                                                min_reaction,
                                                max_reaction,
                                                my_team
                                        )
                                        if settings and att_handler.get_detection_m_pos then
                                            local attention_pos = att_handler:get_detection_m_pos()
                                            if attention_pos then
                                                local vis_ray = World:raycast(
                                                        "ray",
                                                        my_pos,
                                                        attention_pos,
                                                        "slot_mask",
                                                        slotmask,
                                                        "ray_type",
                                                        "ai_vision"
                                                )

                                                if not vis_ray or (vis_ray.unit and vis_ray.unit:key() == u_key) then
                                                    if CopLogicBase._create_detected_attention_object_data then
                                                        local att_obj = CopLogicBase._create_detected_attention_object_data(
                                                                t,
                                                                unit,
                                                                u_key,
                                                                attention_info,
                                                                settings
                                                        )

                                                        if att_obj then
                                                            local new_reaction = (settings and settings.reaction)
                                                                    or AIAttentionObject.REACT_IDLE

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
                end
        )
    end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then
    if CopLogicIdle then
        if Network:is_server() then
            Hooks:PostHook(CopLogicIdle, "enter", "BB_CopLogicIdle_enter_check_reload", function(data, ...)
                if data.is_converted then
                    safe_call(CombatBehavior.check_smart_reload, data)
                end
            end)

            if CopLogicIdle.on_intimidated then
                local old_intim = CopLogicIdle.on_intimidated

                CopLogicIdle.on_intimidated = function(data, ...)
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

                CopLogicIdle._get_priority_attention = function(data, attention_objects, reaction_func)
                    if data.is_converted and TeamAILogicIdle and TeamAILogicIdle._get_priority_attention then
                        return TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
                    end

                    return old_prio(data, attention_objects, reaction_func)
                end
            end
        end
    end
end

if RequiredScript == "lib/managers/mission/elementmissionend" then
    if ElementMissionEnd then
        local old_ElementMissionEnd_on_executed = ElementMissionEnd.on_executed

        ElementMissionEnd.on_executed = function(self, instigator)
            local is_offline = Global and Global.game_settings and Global.game_settings.single_player

            if is_offline
                    and self._values.enabled
                    and self._values.state == "success"
                    and managers.platform
                    and managers.platform:presence() == "Playing"
            then
                local num_winners = 0
                if managers.network and managers.network:session() then
                    num_winners = managers.network:session():amount_of_alive_players()
                end

                if managers.groupai and managers.groupai:state() then
                    num_winners = num_winners + managers.groupai:state():amount_of_winning_ai_criminals()
                end

                if managers.network and managers.network:session() then
                    managers.network:session():send_to_peers("mission_ended", true, num_winners)
                end

                if game_state_machine and managers.player and managers.player:player_unit() then
                    game_state_machine:change_state_by_name("victoryscreen", {
                        num_winners = num_winners,
                        personal_win = alive(managers.player:player_unit()),
                    })
                end

                if ElementMissionEnd.super and ElementMissionEnd.super.on_executed then
                    ElementMissionEnd.super.on_executed(self, instigator)
                end
            else
                return old_ElementMissionEnd_on_executed(self, instigator)
            end
        end
    end
end

if RequiredScript == "lib/units/player_team/teamaibrain" then
    Hooks:PostHook(TeamAIBrain, "_reset_logic_data", "BB_reset_logic_data", function(self)
        if self._logic_data and self._logic_data.enemy_slotmask and SLOTS and SLOTS.TURRETS then
            local turrets_mask = World:make_slot_mask(SLOTS.TURRETS)
            self._logic_data.enemy_slotmask = self._logic_data.enemy_slotmask + turrets_mask
        end
    end)
end
