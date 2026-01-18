local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local SLOTS = BB.SLOTS

local Utils = BB.Utils
local UnitOps = BB.UnitOps
local CacheManager = BB.CacheManager
local CoopCacheManager = BB.CoopCacheManager
local EnemyClassifier = BB.EnemyClassifier
local CombatHelper = BB.CombatHelper
local ThreatAssessment = BB.ThreatAssessment
local CombatBehavior = BB.CombatBehavior
local IntimidationSystem = BB.IntimidationSystem

local MASK = BB.MASK

local bb_log = Utils.log
local safe_call = Utils.safe_call
local clamp = Utils.clamp
local game_time = Utils.game_time
local is_team_ai = UnitOps.is_team_ai
local is_unit_in_slot = UnitOps.is_in_slot
local is_law_unit = UnitOps.is_law_unit
local safe_say = UnitOps.say

local function ensure_dyn_unit_loaded(unit_path)
    return CombatHelper.ensure_dyn_unit_loaded(unit_path)
end

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

Hooks:Add("LocalizationManagerPostInit", "BB_LocalizationManager_PostInit", function(loc)
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

Hooks:Add("MenuManagerInitialize", "BB_MenuManager_Initialize", function(menu_manager)
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

if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
    local is_server = Network:is_server()

    Hooks:PostHook(GroupAIStateBase, "init", "BB_GroupAIStateBase_init_PreloadConcussion", function(self, ...)
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

if RequiredScript == "lib/units/player_team/teamaibase" then
    local is_server = Network:is_server()

    Hooks:PostHook(TeamAIBase, "post_init", "BB_TeamAIBase_postInit_SetupUpgrades", function(self, ...)
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

if RequiredScript == "lib/units/player_team/teamaidamage" then
    Hooks:PostHook(TeamAIDamage, "_apply_damage", "BB_TeamAIDamage_applyDamage_SayHurt", function(self, ...)
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

    Hooks:PostHook(TeamAIDamage, "_regenerated", "BB_TeamAIDamage_regenerated_ResetSaidHurt", function(self)
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

if RequiredScript == "lib/units/interactions/interactionext" then
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
                "BB_ReviveInteractionExt_atInteractStart_CancelOthers",
                function(self, player, ...)
                    if self.tweak_data == "revive" or self.tweak_data == "free" then
                        cancel_other_rescue_objectives(self._unit, player)
                    end
                end
        )
    end
end

if RequiredScript == "lib/tweak_data/weapontweakdata" then
    if BB:get("combat", false) then
        Hooks:PostHook(WeaponTweakData, "init", "BB_WeaponTweakData_init_SetBotWeapons", function(self, ...)
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

if RequiredScript == "lib/managers/criminalsmanager" then
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

if RequiredScript == "lib/tweak_data/playertweakdata" then
    function PlayerTweakData:_set_singleplayer(...)
        return
    end
end

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then
    Hooks:PostHook(NewNPCRaycastWeaponBase, "setup", "BB_NewNPCRaycastWeaponBase_setup_RemoveFriendlyMask", remove_ai_and_players_from_bullet_mask)
end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
    Hooks:PostHook(NPCRaycastWeaponBase, "setup", "BB_NPCRaycastWeaponBase_setup_RemoveFriendlyMask", remove_ai_and_players_from_bullet_mask)
end

if RequiredScript == "lib/units/player_team/teamaimovement" then
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
                    "BB_TeamAIMovement_setCarryingBag_UpdateLabel",
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

if RequiredScript == "lib/units/player_team/actions/lower_body/criminalactionwalk" then
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

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
    local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

    function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
        local unit = data.unit
        if not (alive(unit) and unit:movement()) then
            return
        end

        local t = data.t or game_time()
        local is_team_ai_unit = is_team_ai(unit)

        if BB:get("coop", false) and is_team_ai_unit then
            BB.CoopSystem.update_teammate_status(unit)
            safe_call(BB.CoopSystem.scan_and_update_priorities, data)
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

                        local flags = BB.classify_enemy(attention_data.unit, attention_data)
                        if flags.tasing then
                            threat = threat + THREAT_WEIGHTS.TASING_BONUS
                            BB.CoopSystem.mark_dangerous_special(attention_data.unit, unit)
                        end
                        if flags.spooc_attack then
                            threat = threat + THREAT_WEIGHTS.SPOOC_ATTACK_BONUS
                            BB.CoopSystem.mark_dangerous_special(attention_data.unit, unit)
                        end

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

        local global_priority_targets = BB.CoopSystem.get_priority_targets()
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
                    local current_attackers = BB.CoopSystem.count_dozer_attackers(u_key)
                    local attacker_limit = BB.CoopSystem.get_dozer_attacker_limit(
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

                    if not BB.CoopSystem.is_direction_covered(local_target_info.data.m_head_pos, unit) then
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
                    local current_attackers = BB.CoopSystem.count_dozer_attackers(u_key)
                    local attacker_limit = BB.CoopSystem.get_dozer_attacker_limit(
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
            "BB_TeamAILogicIdle_onAlert_MaskUp",
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

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
    TeamAILogicAssault.find_enemy_to_mark = CombatBehavior.find_enemy_to_mark
    TeamAILogicAssault.mark_enemy = CombatBehavior.mark_enemy
    TeamAILogicAssault.check_smart_reload = CombatBehavior.check_smart_reload

    if Network:is_server() then
        Hooks:PostHook(
                TeamAILogicAssault,
                "update",
                "BB_TeamAILogicAssault_update_CombatActions",
                function(data, ...)
                    local t = game_time()
                    local my_data = data.internal_data or {}
                    local unit = data.unit

                    if BB:get("coop", false) and is_team_ai(unit) then
                        BB.CoopSystem.update_teammate_status(unit)
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
                "BB_TeamAILogicAssault_update_CacheCleanup",
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

    Hooks:PostHook(TeamAILogicAssault, "exit", "BB_TeamAILogicAssault_exit_SmartReload", function(data, ...)
        safe_call(CombatBehavior.check_smart_reload, data)
    end)
end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
    local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

    Hooks:PostHook(
            TeamAILogicBase,
            "_set_attention_obj",
            "BB_TeamAILogicBase_setAttentionObj_CheckIntimidation",
            function(data, new_att_obj, new_reaction)
                safe_call(IntimidationSystem.perform_interaction_check, data)
            end
    )

    function TeamAILogicBase._get_logic_state_from_reaction(data, reaction)
        return (not reaction or reaction < REACT_COMBAT) and "idle" or "assault"
    end
end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
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

if RequiredScript == "lib/units/enemies/cop/copbrain" then
    Hooks:PostHook(CopBrain, "convert_to_criminal", "BB_CopBrain_convertToCriminal_SetCharTweak", function(self, ...)
        if self._logic_data and self._logic_data.char_tweak then
            local char_tweak = deep_clone(self._logic_data.char_tweak)
            char_tweak.access = "teamAI1"
            char_tweak.always_face_enemy = true
            self._logic_data.char_tweak = char_tweak
        end
    end)
end

if RequiredScript == "lib/units/enemies/cop/copdamage" then
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
                "BB_CopDamage_damageMelee_AddToIntimList",
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
                "BB_CopDamage_syncDamageMelee_AddToIntimList",
                function(self, variant, ...)
                    handle_taser_damage(self, variant)
                end
        )
    end

    if CopDamage.damage_bullet then
        Hooks:PreHook(
                CopDamage,
                "damage_bullet",
                "BB_CopDamage_damageBullet_SniperInstakill",
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
            "BB_CopDamage_die_PreClearPickup",
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
            "BB_CopDamage_die_PostCleanupState",
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

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
    local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

    Hooks:PreHook(
            CopLogicBase,
            "_upd_attention_obj_detection",
            "BB_CopLogicBase_updAttentionObjDetection_FastDetect",
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

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then
    if Network:is_server() then
        Hooks:PostHook(CopLogicIdle, "enter", "BB_CopLogicIdle_enter_CheckSmartReload", function(data, ...)
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

if RequiredScript == "lib/managers/mission/elementmissionend" then
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

if RequiredScript == "lib/units/player_team/teamaibrain" then
    Hooks:PostHook(TeamAIBrain, "_reset_logic_data", "BB_TeamAIBrain_resetLogicData_AddTurretMask", function(self)
        if self._logic_data and self._logic_data.enemy_slotmask and SLOTS and SLOTS.TURRETS then
            local turrets_mask = World:make_slot_mask(SLOTS.TURRETS)
            self._logic_data.enemy_slotmask = self._logic_data.enemy_slotmask + turrets_mask
        end
    end)
end

if RequiredScript == "lib/units/equipment/sentry_gun/sentrygunbase" then
    Hooks:PostHook(SentryGunBase, "activate_as_module", "BB_SentryGunBase_FixTurretTargeting", function(self)
        self._unit:movement():set_team(self._unit:movement():team())
    end)
end