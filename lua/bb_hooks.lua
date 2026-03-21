local BB = _G.BB
local Utils = BB.Utils
local CONSTANTS = BB.CONSTANTS
local SLOTS = BB.SLOTS
local MASK = BB.MASK
local UnitOps = BB.UnitOps
local CombatHelper = BB.CombatHelper
local CombatBehavior = BB.CombatBehavior
local IntimidationSystem = BB.IntimidationSystem
local CoopCacheManager = BB.CoopCacheManager
local EnemyClassifier = BB.EnemyClassifier

local bb_log = Utils.log
local safe_call = Utils.safe_call
local game_time = Utils.game_time
local is_team_ai = UnitOps.is_team_ai
local is_law_unit = UnitOps.is_law_unit
local is_unit_in_slot = UnitOps.is_in_slot
local unit_head_pos = UnitOps.head_pos
local safe_say = UnitOps.say
local move_shoot_path_vec = Vector3()
local move_shoot_enemy_vec = Vector3()
local move_shoot_watch_vec = Vector3()
local move_shoot_walk_vec = Vector3()
local function is_team_ai_move_shoot_unit(unit)
    return alive(unit) and is_team_ai(unit)
end

local function get_team_ai_running_fire_range(weapon_range)
    if type(weapon_range) ~= "table" then
        return 500
    end

    local range_key = CONSTANTS.MOVE_SHOOT_RUNNING_RANGE or "optimal"
    return weapon_range[range_key] or weapon_range.close or 500
end

local function apply_team_ai_weapon_responsiveness(char_tweak)
    if not (char_tweak and type(char_tweak.weapon) == "table") then
        return
    end

    for _, usage_tweak in pairs(char_tweak.weapon) do
        if type(usage_tweak) == "table" then
            if type(usage_tweak.aim_delay) == "table" then
                usage_tweak.aim_delay = {
                    0,
                    CONSTANTS.TEAMAI_AIM_DELAY_MAX,
                }
            end

            if type(usage_tweak.focus_delay) == "number" then
                usage_tweak.focus_delay = math.min(usage_tweak.focus_delay, CONSTANTS.TEAMAI_FOCUS_DELAY)
            end
        end
    end
end

local function get_team_ai_player_color_limit()
    local chat_colors = tweak_data and tweak_data.chat_colors
    local max_players = tweak_data and tweak_data.max_players or 4
    local chat_color_count = type(chat_colors) == "table" and #chat_colors or 0

    return math.max(math.min(max_players, chat_color_count - 1), 0)
end

local function get_team_ai_player_color_id(manager, unit)
    if not (manager and alive(unit)) then
        return nil
    end

    local target_character = manager.character_by_unit and manager:character_by_unit(unit)
    if not (target_character and target_character.taken and target_character.data and target_character.data.ai) then
        return nil
    end

    local chat_colors = tweak_data and tweak_data.chat_colors
    local fallback_color_id = type(chat_colors) == "table" and #chat_colors or nil
    local player_color_limit = get_team_ai_player_color_limit()
    if player_color_limit < 1 then
        return fallback_color_id
    end

    local characters = manager.characters and manager:characters() or manager._characters or {}
    local used_human_color_ids = {}

    for _, character in ipairs(characters) do
        if character and character.taken and character.data and not character.data.ai then
            local peer_id = character.peer_id
            if type(peer_id) == "number" and peer_id >= 1 and peer_id <= player_color_limit then
                used_human_color_ids[peer_id] = true
            end
        end
    end

    local next_color_id = 1

    for _, character in ipairs(characters) do
        if character and character.taken and character.data and character.data.ai and alive(character.unit) then
            while next_color_id <= player_color_limit and used_human_color_ids[next_color_id] do
                next_color_id = next_color_id + 1
            end

            local resolved_color_id = next_color_id <= player_color_limit and next_color_id or fallback_color_id
            if character == target_character then
                return resolved_color_id
            end

            if resolved_color_id and resolved_color_id <= player_color_limit then
                used_human_color_ids[resolved_color_id] = true
                next_color_id = next_color_id + 1
            end
        end
    end

    return fallback_color_id
end

local function get_head_target_pos(shoot_from_pos, attention)
    if not (attention and attention.unit and alive(attention.unit)) then
        return nil
    end
    local head_pos = unit_head_pos(attention.unit)
    if not head_pos then
        return nil
    end
    local new_target_pos = Vector3()
    mvector3.set(new_target_pos, head_pos)
    local new_target_vec = Vector3()
    local new_target_dis = mvector3.direction(new_target_vec, shoot_from_pos, new_target_pos)
    return new_target_pos, new_target_vec, new_target_dis
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
if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
    if Network:is_server() then
        Hooks:PostHook(GroupAIStateBase, "init", "BB_GroupAIStateBase_init_PreloadConcussion", function(self, ...)
            if BB:get("conc", false) then
                if tweak_data.blackmarket and tweak_data.blackmarket.projectiles then
                    local conc_data = tweak_data.blackmarket.projectiles.concussion
                    if conc_data and conc_data.unit then
                        CombatHelper.ensure_dyn_unit_loaded(conc_data.unit)
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
            if not balance_multipliers then return 1 end
            local nr_crim = 0
            for _, u_data in pairs(self:all_char_criminals() or {}) do
                if not u_data.status then
                    nr_crim = nr_crim + 1
                end
            end

            nr_crim = math.clamp(nr_crim, 1, #balance_multipliers)
            return balance_multipliers[nr_crim]
        end
    end
end

if RequiredScript == "lib/units/player_team/teamaibase" then
    if Network:is_server() then
        Hooks:PostHook(TeamAIBase, "post_init", "BB_TeamAIBase_postInit_SetupUpgrades", function(self, ...)
            self._upgrades = self._upgrades or {}
            self._upgrade_levels = self._upgrade_levels or {}

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
        end)

        function TeamAIBase:set_upgrade_value(category, upgrade, level)
            if not managers.player then return end
            self._upgrades = self._upgrades or {}
            self._upgrades[category] = self._upgrades[category] or {}

            local value = managers.player:upgrade_value_by_level(category, upgrade, level)
            self._upgrades[category][upgrade] = value

            self._upgrade_levels = self._upgrade_levels or {}
            self._upgrade_levels[category] = self._upgrade_levels[category] or {}
            self._upgrade_levels[category][upgrade] = level or 1
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
    if Network:is_server() then
        local health_multipliers = { nil, 2, 3 }

        Hooks:PostHook(TeamAIDamage, "init", "BB_TeamAIDamage_init_HealthBoost", function(self, unit)
            if not BB.FEATURE_FLAGS.HEALTH_MULTIPLIER then
                return
            end

            local health_idx = BB:get("health", 1)
            local multiplier = health_multipliers[health_idx]
            if multiplier then
                self._HEALTH_INIT = self._HEALTH_INIT * multiplier
                self._health = self._HEALTH_INIT
                self._HEALTH_TOTAL = self._HEALTH_INIT + self._HEALTH_BLEEDOUT_INIT
                self._HEALTH_TOTAL_PERCENT = self._HEALTH_TOTAL / 100
                self._health_ratio = self._health / self._HEALTH_INIT
            end
        end)

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
                    managers.groupai:state():report_criminal_downed(self._unit)

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

        if TeamAIDamage.accuracy_multiplier then
            local old_accuracy_multiplier = TeamAIDamage.accuracy_multiplier
            function TeamAIDamage:accuracy_multiplier(...)
                if BB:get("combat", false)
                and self._unit and alive(self._unit)
                and is_team_ai(self._unit)
                then
                     local ThreatAssessment = BB.ThreatAssessment
                     local archetype = ThreatAssessment and ThreatAssessment.get_weapon_archetype(self._unit) or "unknown"
                     local acc_mul = CONSTANTS.ACC_MUL_DEFAULT
                     if archetype == "sniper" then
                         acc_mul = CONSTANTS.ACC_MUL_SNIPER
                     elseif archetype == "assault_rifle" then
                         acc_mul = CONSTANTS.ACC_MUL_ASSAULT_RIFLE
                     elseif archetype == "lmg" then
                         acc_mul = CONSTANTS.ACC_MUL_LMG
                     end
                     return old_accuracy_multiplier(self, ...) * acc_mul
                end
                return old_accuracy_multiplier(self, ...)
            end
        end
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

if RequiredScript == "lib/managers/criminalsmanager" then
    if CriminalsManager.character_color_id_by_unit and not BB._team_ai_player_colors_hooked then
        BB._team_ai_player_colors_hooked = true

        local old_character_color_id_by_unit = CriminalsManager.character_color_id_by_unit

        function CriminalsManager:character_color_id_by_unit(unit, ...)
            local team_ai_color_id = get_team_ai_player_color_id(self, unit)
            if team_ai_color_id then
                return team_ai_color_id
            end

            return old_character_color_id_by_unit(self, unit, ...)
        end
    end

    if Network:is_server() then
        local total_chars = CriminalsManager.get_num_characters and CriminalsManager.get_num_characters() or 4

        if BB:get("biglob", false) then
            CriminalsManager.MAX_NR_TEAM_AI = total_chars
        end

        if tweak_data and tweak_data.character and tweak_data.character.presets then
            local char_preset = tweak_data.character.presets
            local dodge_options = { "poor", "average", "heavy", "athletic", "ninja" }

            local gang_weapon = char_preset.weapon and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)

            if gang_weapon then
                local dodge_idx = BB:get("dodge", 4)
                local dodge_preset = dodge_options[dodge_idx]

                for _, v in pairs(tweak_data.character) do
                    if type(v) == "table" and v.access == "teamAI1" then
                        v.no_run_start = true
                        v.no_run_stop = true
                        v.always_face_enemy = true
                        v.crouch_move = true
                        apply_team_ai_weapon_responsiveness(v)

                        if char_preset.hurt_severities and char_preset.hurt_severities.no_hurts then
                            v.damage.hurt_severity = char_preset.hurt_severities.no_hurts
                        end

                        if char_preset.move_speed and char_preset.move_speed.lightning then
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
                    end
                end
            end
        end
    end
end

if RequiredScript == "lib/tweak_data/playertweakdata" then
        if Network:is_server() then
            function PlayerTweakData:_set_singleplayer(...)
                return
            end
        end
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

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then
        if Network:is_server() then
            Hooks:PostHook(NewNPCRaycastWeaponBase, "setup", "BB_NewNPCRaycastWeaponBase_setup_RemoveFriendlyMask", remove_ai_and_players_from_bullet_mask)
        end
    end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
        if Network:is_server() then
            Hooks:PostHook(NPCRaycastWeaponBase, "setup", "BB_NPCRaycastWeaponBase_setup_RemoveFriendlyMask", remove_ai_and_players_from_bullet_mask)
        end
    end

if RequiredScript == "lib/units/player_team/teamaimovement" then
        if Network:is_server() then
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
                    local orig_set_carrying_bag = TeamAIMovement.set_carrying_bag

                    function TeamAIMovement:set_carrying_bag(unit, ...)
                        orig_set_carrying_bag(self, unit, ...)

                        if not managers.hud then
                            return
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
                end
            end

            if TeamAIMovement.get_reload_speed_multiplier then
                local old_get_reload_speed_multiplier = TeamAIMovement.get_reload_speed_multiplier

                function TeamAIMovement:get_reload_speed_multiplier(...)
                    local multiplier = old_get_reload_speed_multiplier(self, ...)
                    if BB:get("combat", false) and not BotWeapons and self._unit and is_team_ai(self._unit) then
                        return (multiplier or 1) * CONSTANTS.RELOAD_SPEED_MUL
                    end
                    return multiplier
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
        if Network:is_server() then
            local function get_bag_speed_modifier(ext_movement)
                if not ext_movement or not ext_movement:carrying_bag() then
                    return 1
                end

                local carry_id = ext_movement:carry_id()
                local carry_data = carry_id and tweak_data.carry and tweak_data.carry[carry_id]
                local carry_type = carry_data and carry_data.type
                local type_data = carry_type and tweak_data.carry.types and tweak_data.carry.types[carry_type]

                if type_data then
                    return math.min(1, (type_data.move_speed_modifier or 1) * CONSTANTS.BAG_SPEED_MUL)
                end

                return 1
            end

            local old_get_max_walk_speed = CriminalActionWalk._get_max_walk_speed
            function CriminalActionWalk:_get_max_walk_speed(...)
                if not old_get_max_walk_speed then
                    return { 150 }
                end

                local speeds = old_get_max_walk_speed(self, ...)
                local mod = get_bag_speed_modifier(self._ext_movement)

                if mod == 1 then
                    return speeds
                end

                if not self._ext_movement:speed_modifier() then
                    speeds = deep_clone(speeds)
                end

                for k, v in pairs(speeds) do
                    speeds[k] = v * mod
                end

                return speeds
            end

            local old_get_current_max_walk_speed = CriminalActionWalk._get_current_max_walk_speed
            function CriminalActionWalk:_get_current_max_walk_speed(move_dir, ...)
                if not old_get_current_max_walk_speed then
                    return 150
                end

                return old_get_current_max_walk_speed(self, move_dir, ...) * get_bag_speed_modifier(self._ext_movement)
            end
        end
    end

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
        if Network:is_server() then
            function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
                return CombatBehavior.find_priority_attention(data, attention_objects, reaction_func)
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
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicattack" then
        if Network:is_server() then
            local _bb_orig_upd_aim = CopLogicAttack._upd_aim

            function CopLogicAttack._upd_aim(data, my_data)
                local unit = data and data.unit

                if not is_team_ai_move_shoot_unit(unit) then
                    return _bb_orig_upd_aim(data, my_data)
                end

                local shoot, aim, expected_pos = nil
                local focus_enemy = data.attention_obj

                if focus_enemy and AIAttentionObject.REACT_AIM <= focus_enemy.reaction then
                    local last_sup_t = unit:character_damage():last_suppression_t()

                    if focus_enemy.verified or focus_enemy.nearly_visible then
                        local running_fire_range = get_team_ai_running_fire_range(my_data.weapon_range)
                        local focus_enemy_dis = focus_enemy.dis or focus_enemy.verified_dis or 0

                        if unit:anim_data().run and running_fire_range < focus_enemy_dis then
                            local walk_to_pos = unit:movement():get_walk_to_pos()

                            if walk_to_pos then
                                mvector3.direction(move_shoot_path_vec, data.m_pos, walk_to_pos)
                                mvector3.direction(move_shoot_enemy_vec, data.m_pos, focus_enemy.m_pos)

                                local dot = mvector3.dot(move_shoot_path_vec, move_shoot_enemy_vec)

                                if dot < CONSTANTS.MOVE_SHOOT_BACKWARD_DOT then
                                    shoot = false
                                    aim = false
                                end
                            end
                        end

                        if aim == nil and AIAttentionObject.REACT_AIM <= focus_enemy.reaction then
                            if AIAttentionObject.REACT_SHOOT <= focus_enemy.reaction then
                                local running = my_data.advancing and not my_data.advancing:stopping() and my_data.advancing:haste() == "run"
                                local weapon_range = data.internal_data and data.internal_data.weapon_range or my_data.weapon_range
                                local running_range = get_team_ai_running_fire_range(weapon_range)
                                local far_range = weapon_range and weapon_range.far or running_range
                                local firing_range = running and running_range or far_range

                                if last_sup_t and data.t - last_sup_t < 7 * (running and 0.3 or 1) * (focus_enemy.verified and 1 or focus_enemy.vis_ray and firing_range < focus_enemy.vis_ray.distance and 0.5 or 0.2) then
                                    shoot = true
                                elseif focus_enemy.verified and focus_enemy.verified_dis and focus_enemy.verified_dis < firing_range then
                                    shoot = true
                                elseif focus_enemy.verified and focus_enemy.criminal_record and focus_enemy.criminal_record.assault_t and data.t - focus_enemy.criminal_record.assault_t < 2 then
                                    shoot = true
                                end

                                if not shoot and my_data.attitude == "engage" then
                                    if focus_enemy.verified then
                                        local in_range = focus_enemy.verified_dis and focus_enemy.verified_dis < firing_range

                                        if in_range or focus_enemy.reaction == AIAttentionObject.REACT_SHOOT then
                                            shoot = true
                                        end
                                    else
                                        local time_since_verification = focus_enemy.verified_t and data.t - focus_enemy.verified_t

                                        if my_data.firing and time_since_verification and time_since_verification < 3.5 then
                                            shoot = true
                                        else
                                            data.brain:search_for_path_to_unit("hunt" .. tostring(data.key), focus_enemy.unit)
                                        end
                                    end
                                end

                                aim = aim or shoot

                                if not aim and focus_enemy.verified_dis and focus_enemy.verified_dis < firing_range then
                                    aim = true
                                end
                            else
                                aim = true
                            end
                        end
                    elseif AIAttentionObject.REACT_AIM <= focus_enemy.reaction then
                        local time_since_verification = focus_enemy.verified_t and data.t - focus_enemy.verified_t
                        local running = my_data.advancing and not my_data.advancing:stopping() and my_data.advancing:haste() == "run"

                        if running then
                            if time_since_verification and time_since_verification < math.lerp(5, 1, math.max(0, (focus_enemy.verified_dis or 0) - 500) / 600) then
                                aim = true
                            end
                        else
                            aim = true
                        end

                        if aim and my_data.shooting and AIAttentionObject.REACT_SHOOT <= focus_enemy.reaction and time_since_verification and time_since_verification < (running and 2 or 3) then
                            shoot = true
                        end

                        if not aim then
                            expected_pos = CopLogicAttack._get_expected_attention_position(data, my_data)

                            if expected_pos then
                                if running then
                                    local walk_to_pos = unit:movement():get_walk_to_pos()

                                    if walk_to_pos then
                                        mvector3.set(move_shoot_watch_vec, expected_pos)
                                        mvector3.subtract(move_shoot_watch_vec, data.m_pos)
                                        mvector3.set_z(move_shoot_watch_vec, 0)

                                        local watch_pos_dis = mvector3.normalize(move_shoot_watch_vec)

                                        mvector3.set(move_shoot_walk_vec, walk_to_pos)
                                        mvector3.subtract(move_shoot_walk_vec, data.m_pos)
                                        mvector3.set_z(move_shoot_walk_vec, 0)
                                        mvector3.normalize(move_shoot_walk_vec)

                                        local watch_walk_dot = mvector3.dot(move_shoot_watch_vec, move_shoot_walk_vec)

                                        if watch_pos_dis < 500 or (watch_pos_dis < 1000 and watch_walk_dot > 0.85) then
                                            aim = true
                                        end
                                    end
                                else
                                    aim = true
                                end
                            end
                        end
                    else
                        expected_pos = CopLogicAttack._get_expected_attention_position(data, my_data)

                        if expected_pos then
                            aim = true
                        end
                    end
                end

                if not aim and data.char_tweak.always_face_enemy and focus_enemy and AIAttentionObject.REACT_COMBAT <= focus_enemy.reaction then
                    aim = true
                end

                if data.logic.chk_should_turn(data, my_data) and (focus_enemy or expected_pos) then
                    local enemy_pos = expected_pos or (focus_enemy.verified or focus_enemy.nearly_visible) and focus_enemy.m_pos or focus_enemy.verified_pos

                    CopLogicAttack._chk_request_action_turn_to_enemy(data, my_data, data.m_pos, enemy_pos)
                end

                if aim or shoot then
                    if expected_pos then
                        if my_data.attention_unit ~= expected_pos then
                            CopLogicBase._set_attention_on_pos(data, mvector3.copy(expected_pos))

                            my_data.attention_unit = mvector3.copy(expected_pos)
                        end
                    elseif focus_enemy.verified or focus_enemy.nearly_visible then
                        if my_data.attention_unit ~= focus_enemy.u_key then
                            CopLogicBase._set_attention(data, focus_enemy)

                            my_data.attention_unit = focus_enemy.u_key
                        end
                    else
                        local look_pos = focus_enemy.last_verified_pos or focus_enemy.verified_pos

                        if my_data.attention_unit ~= look_pos then
                            CopLogicBase._set_attention_on_pos(data, mvector3.copy(look_pos))

                            my_data.attention_unit = mvector3.copy(look_pos)
                        end
                    end

                    if not my_data.shooting and not my_data.spooc_attack and not unit:anim_data().reload and not unit:movement():chk_action_forbidden("action") then
                        local shoot_action = {
                            body_part = 3,
                            type = "shoot",
                        }

                        if unit:brain():action_request(shoot_action) then
                            my_data.shooting = true
                        end
                    end
                else
                    if my_data.shooting then
                        local new_action = unit:anim_data().reload and {
                            body_part = 3,
                            type = "reload",
                        } or {
                            body_part = 3,
                            type = "idle",
                        }

                        unit:brain():action_request(new_action)
                    end

                    if my_data.attention_unit then
                        CopLogicBase._reset_attention(data)

                        my_data.attention_unit = nil
                    end
                end

                CopLogicAttack.aim_allow_fire(shoot, aim, data, my_data)
            end
        end
    end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
        if Network:is_server() then
            TeamAILogicAssault.find_enemy_to_mark = CombatBehavior.find_enemy_to_mark
            TeamAILogicAssault.mark_enemy = CombatBehavior.mark_enemy
            TeamAILogicAssault.check_smart_reload = CombatBehavior.check_smart_reload
            TeamAILogicAssault._get_priority_attention = CombatBehavior.find_priority_attention

            Hooks:PostHook(
                    TeamAILogicAssault,
                    "update",
                    "BB_TeamAILogicAssault_update_CombatActions",
                    function(data, ...)
                        local t = game_time()
                        local my_data = data.internal_data or {}
                        local unit = data.unit

                        my_data._next_conc_eval_t = my_data._next_conc_eval_t or 0
                        if t >= my_data._next_conc_eval_t then
                            my_data._next_conc_eval_t = t + CONSTANTS.CONC_EVAL_INTERVAL
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
                    end
            )

            Hooks:PostHook(
                    TeamAILogicAssault,
                    "update",
                    "BB_TeamAILogicAssault_update_CacheCleanup",
                    function(data, ...)
                        local t = game_time()
                        local next_cleanup_t = CoopCacheManager._next_cleanup_t or 0

                        if t >= next_cleanup_t then
                            CoopCacheManager._next_cleanup_t = t + CONSTANTS.CACHE_CLEANUP_INTERVAL
                            CoopCacheManager.cleanup_all(false)
                        end
                    end
            )

            Hooks:PostHook(TeamAILogicAssault, "exit", "BB_TeamAILogicAssault_exit_SmartReload", function(data, ...)
                safe_call(CombatBehavior.check_smart_reload, data)
            end)
        end
    end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
        if Network:is_server() then
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
    end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
        if Network:is_server() then
            local _bb_orig_update = CopActionShoot.update
            local _bb_orig_get_target_pos = CopActionShoot._get_target_pos

            function CopActionShoot:update(t)
                if not is_team_ai_move_shoot_unit(self._unit) then
                    return _bb_orig_update(self, t)
                end

                local forced_lod = CONSTANTS.TEAMAI_SHOOT_LOD_FORCE
                local ext_base = self._ext_base

                if not forced_lod or not ext_base or type(ext_base.lod_stage) ~= "function" then
                    return _bb_orig_update(self, t)
                end

                local original_lod_stage = ext_base.lod_stage

                ext_base.lod_stage = function()
                    return forced_lod
                end

                local ok, err = pcall(function()
                    return _bb_orig_update(self, t)
                end)

                ext_base.lod_stage = original_lod_stage

                if not ok then
                    error(err)
                end
            end

            function CopActionShoot:_get_target_pos(shoot_from_pos, attention, ...)
                local target_pos, target_vec, target_dis, autotarget = _bb_orig_get_target_pos(self, shoot_from_pos, attention, ...)

                if not BB:get("combat", false) or not (self._unit and alive(self._unit) and is_team_ai(self._unit)) then
                    return target_pos, target_vec, target_dis, autotarget
                end

                local new_target_pos, new_target_vec, new_target_dis = get_head_target_pos(shoot_from_pos, attention)
                if new_target_pos then
                    return new_target_pos, new_target_vec, new_target_dis, autotarget
                end

                return target_pos, target_vec, target_dis, autotarget
            end

            local _bb_orig_get_transition_target_pos = CopActionShoot._get_transition_target_pos

            function CopActionShoot:_get_transition_target_pos(shoot_from_pos, attention, t, ...)
                local target_pos, target_vec, target_dis, autotarget = _bb_orig_get_transition_target_pos(self, shoot_from_pos, attention, t, ...)

                if not BB:get("combat", false) or not (self._unit and alive(self._unit) and is_team_ai(self._unit)) then
                    return target_pos, target_vec, target_dis, autotarget
                end

                local new_target_pos, new_target_vec, new_target_dis = get_head_target_pos(shoot_from_pos, attention)
                if new_target_pos then
                    if self._aim_transition then
                        local transition = self._aim_transition
                        local prog = (t - transition.start_t) / transition.duration
                        if prog < 1 then
                            prog = math.bezier({0, 0, 1, 1}, prog)
                            mvector3.lerp(new_target_vec, transition.start_vec, new_target_vec, prog)
                        end
                    end
                    return new_target_pos, new_target_vec, new_target_dis, autotarget
                end

                return target_pos, target_vec, target_dis, autotarget
            end
        end
    end

if RequiredScript == "lib/units/enemies/cop/copbrain" then
        if Network:is_server() then
            Hooks:PostHook(CopBrain, "convert_to_criminal", "BB_CopBrain_convertToCriminal_SetCharTweak", function(self, ...)
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
        if Network:is_server() then
            local function handle_taser_damage(self, variant)
                if variant == "taser_tased" or variant == 5 then
                    if self._unit and not EnemyClassifier.is_special(self._unit) then
                        BB:add_cop_to_intimidation_list(self._unit:key())
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
                    "BB_CopDamage_damageBullet_SimpleDamage",
                    function(self, attack_data, ...)
                        if self._unit and alive(self._unit)
                        and attack_data.attacker_unit
                        and alive(attack_data.attacker_unit)
                        and is_team_ai(attack_data.attacker_unit)
                        and attack_data.damage
                        then
                            local dmg_mul = BB.ThreatAssessment.get_archetype_damage_multiplier(attack_data.attacker_unit)
                            attack_data.damage = attack_data.damage * dmg_mul
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
                                BB.coop_data.priority_targets[u_key_str] = nil
                            end

                            if BB.coop_data and BB.coop_data.bot_observations then
                                for _, snapshot in pairs(BB.coop_data.bot_observations) do
                                    if snapshot and snapshot.targets then
                                        snapshot.targets[u_key_str] = nil
                                    end
                                end
                            end

                            if BB.coop_data and BB.coop_data.dozer_attackers then
                                for bot_key, target_key in pairs(BB.coop_data.dozer_attackers) do
                                    if tostring(target_key) == u_key_str then
                                        BB.coop_data.dozer_attackers[bot_key] = nil
                                    end
                                end
                            end

                            if BB.coop_data and BB.coop_data.assignment_snapshot then
                                local snapshot = BB.coop_data.assignment_snapshot
                                if snapshot.by_target then
                                    local owner = snapshot.by_target[u_key_str]
                                    snapshot.by_target[u_key_str] = nil
                                    if owner and snapshot.by_bot then
                                        snapshot.by_bot[owner] = nil
                                    end
                                end
                            end
                        end
                    end
            )
        end
    end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
        if Network:is_server() then
            local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

            Hooks:PreHook(CopLogicBase, "_upd_attention_obj_detection", "BB_CopLogicBase_updAttentionObjDetection_FastDetect", function(data, min_reaction, max_reaction, ...)
                if not BB:get("reflex", false) then
                    return
                end

                local unit = data.unit
                if not alive(unit) or not is_team_ai(unit) then
                    return
                end

                local unit_mov = unit:movement()
                local my_tracker = unit_mov and unit_mov:nav_tracker()
                local gstate = managers.groupai and managers.groupai:state()
                if not my_tracker or not gstate then
                    return
                end

                local t = data.t
                local my_key = data.key
                local detected_obj = data.detected_attention_objects or {}
                data.detected_attention_objects = detected_obj

                local my_pos = unit_mov:m_head_pos()
                local my_access = data.SO_access
                local my_team = data.team
                local slotmask = data.visibility_slotmask
                local chk_vis_func = my_tracker.check_visibility

                local all_attention_objects = gstate:get_AI_attention_objects_by_filter(data.SO_access_str, my_team)

                for u_key, attention_info in pairs(all_attention_objects or {}) do
                    if u_key ~= my_key and not detected_obj[u_key] then
                        local att_tracker = attention_info.nav_tracker
                        if not att_tracker or chk_vis_func(my_tracker, att_tracker) then
                            local att_handler = attention_info.handler
                            if att_handler and att_handler.get_attention and att_handler.get_detection_m_pos then
                                local settings = att_handler:get_attention(my_access, min_reaction, max_reaction, my_team)
                                local attention_pos = settings and att_handler:get_detection_m_pos()

                                if attention_pos then
                                    local vis_ray = World:raycast("ray", my_pos, attention_pos, "slot_mask", slotmask, "ray_type", "ai_vision")
                                    if not vis_ray or (vis_ray.unit and vis_ray.unit:key() == u_key) then
                                        local ok, att_obj = safe_call(CopLogicBase._create_detected_attention_object_data, t, unit, u_key, attention_info, settings)
                                        if not ok then att_obj = nil end

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
            end)
        end
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

                        if BB.dom_pending and BB.dom_pending[tostring(u_key)] then
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
        if Network:is_server() then
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

                    if game_state_machine then
                        game_state_machine:change_state_by_name("victoryscreen", {
                            num_winners = num_winners,
                            personal_win = managers.player
                                and managers.player:player_unit()
                                and alive(managers.player:player_unit()) or false,
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
        if Network:is_server() then
            Hooks:PostHook(TeamAIBrain, "_reset_logic_data", "BB_TeamAIBrain_resetLogicData_AddTurretMask", function(self)
                if self._logic_data and self._logic_data.enemy_slotmask and SLOTS and SLOTS.TURRETS then
                    local turrets_mask = World:make_slot_mask(SLOTS.TURRETS)
                    self._logic_data.enemy_slotmask = self._logic_data.enemy_slotmask + turrets_mask
                end
            end)
        end
    end

if RequiredScript == "lib/units/equipment/sentry_gun/sentrygunbase" then
        if Network:is_server() then
            Hooks:PostHook(SentryGunBase, "activate_as_module", "BB_SentryGunBase_FixTurretTargeting", function(self)
                self._unit:movement():set_team(self._unit:movement():team())
            end)
        end
    end
