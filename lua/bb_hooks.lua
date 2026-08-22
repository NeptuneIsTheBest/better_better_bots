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
local RuntimeSettings = BB.RuntimeSettings

local bb_log = Utils.log
local safe_call = Utils.safe_call
local install_method_patch = Utils.install_method_patch
local game_time = Utils.game_time
local is_team_ai = UnitOps.is_team_ai
local is_unit_in_slot = UnitOps.is_in_slot
local unit_head_pos = UnitOps.head_pos
local safe_say = UnitOps.say
local move_shoot_path_vec = Vector3()
local move_shoot_enemy_vec = Vector3()
local move_shoot_watch_vec = Vector3()
local move_shoot_walk_vec = Vector3()
local DEFAULT_TEAM_AI_FIRE_RANGE = 500

local function is_bot_weapons_active()
    return rawget(_G, "BotWeapons") ~= nil
end

local function is_team_ai_move_shoot_unit(unit)
    return alive(unit) and is_team_ai(unit)
end

local function get_valid_weapon_range(value)
    return type(value) == "number" and value > 0 and value or nil
end

local function get_team_ai_weapon_ranges(weapon_range)
    if type(weapon_range) == "number" then
        local range = get_valid_weapon_range(weapon_range) or DEFAULT_TEAM_AI_FIRE_RANGE

        return range, range, range
    end

    if type(weapon_range) ~= "table" then
        return DEFAULT_TEAM_AI_FIRE_RANGE, DEFAULT_TEAM_AI_FIRE_RANGE, DEFAULT_TEAM_AI_FIRE_RANGE
    end

    local close_range = get_valid_weapon_range(weapon_range.close)
    local optimal_range = get_valid_weapon_range(weapon_range.optimal)
    local far_range = get_valid_weapon_range(weapon_range.far)

    close_range = close_range or optimal_range or far_range or DEFAULT_TEAM_AI_FIRE_RANGE
    optimal_range = math.max(optimal_range or close_range, close_range)
    far_range = math.max(far_range or optimal_range, optimal_range)

    return close_range, optimal_range, far_range
end

local function get_team_ai_running_fire_range(weapon_range)
    local close_range, optimal_range, far_range = get_team_ai_weapon_ranges(weapon_range)

    if type(weapon_range) == "table" then
        local range_key = CONSTANTS.MOVE_SHOOT_RUNNING_RANGE or "optimal"
        local configured_range = get_valid_weapon_range(weapon_range[range_key])

        if configured_range then
            return math.min(configured_range, far_range)
        end
    end

    return optimal_range or close_range
end

local function is_team_ai_running(unit, my_data)
    local advancing = my_data and my_data.advancing

    if advancing and advancing.stopping and advancing.haste then
        return not advancing:stopping() and advancing:haste() == "run"
    end

    local anim_data = unit and unit:anim_data()

    return anim_data and anim_data.run or false
end

local function get_team_ai_attention_distance(data, focus_enemy)
    local distance = focus_enemy and (focus_enemy.verified_dis or focus_enemy.dis)

    if type(distance) == "number" and distance >= 0 then
        return distance
    end

    if data and data.m_pos and focus_enemy and focus_enemy.m_pos then
        return mvector3.distance(data.m_pos, focus_enemy.m_pos)
    end

    return math.huge
end

local function is_team_ai_move_direction_allowed(data, movement, target_pos, target_dis, running_range)
    if target_dis <= running_range then
        return true
    end

    local walk_to_pos = movement and movement:get_walk_to_pos()

    if not (data and data.m_pos and walk_to_pos and target_pos) then
        return true
    end

    local path_dis = mvector3.direction(move_shoot_path_vec, data.m_pos, walk_to_pos)
    local enemy_dis = mvector3.direction(move_shoot_enemy_vec, data.m_pos, target_pos)

    if path_dis <= 0 or enemy_dis <= 0 then
        return true
    end

    return mvector3.dot(move_shoot_path_vec, move_shoot_enemy_vec) >= CONSTANTS.MOVE_SHOOT_BACKWARD_DOT
end

local function can_team_ai_watch_position_while_running(data, movement, watch_pos)
    local walk_to_pos = movement and movement:get_walk_to_pos()

    if not (data and data.m_pos and walk_to_pos and watch_pos) then
        return false
    end

    mvector3.set(move_shoot_watch_vec, watch_pos)
    mvector3.subtract(move_shoot_watch_vec, data.m_pos)
    mvector3.set_z(move_shoot_watch_vec, 0)

    local watch_pos_dis = mvector3.normalize(move_shoot_watch_vec)

    mvector3.set(move_shoot_walk_vec, walk_to_pos)
    mvector3.subtract(move_shoot_walk_vec, data.m_pos)
    mvector3.set_z(move_shoot_walk_vec, 0)

    local walk_dis = mvector3.normalize(move_shoot_walk_vec)

    if watch_pos_dis <= 0 then
        return true
    elseif walk_dis <= 0 then
        return false
    end

    local watch_walk_dot = mvector3.dot(move_shoot_watch_vec, move_shoot_walk_vec)

    return watch_pos_dis < 500 or (watch_pos_dis < 1000 and watch_walk_dot > 0.85)
end

local function get_team_ai_attention_key(focus_enemy)
    if focus_enemy.u_key then
        return focus_enemy.u_key
    end

    local focus_unit = focus_enemy.unit

    return alive(focus_unit) and focus_unit:key() or nil
end

local function set_team_ai_attention_on_unit(data, my_data, focus_enemy)
    local attention_key = get_team_ai_attention_key(focus_enemy)

    if my_data._bb_aim_attention_kind ~= "unit"
            or my_data._bb_aim_attention_key ~= attention_key
            or my_data.attention_unit ~= attention_key
    then
        CopLogicBase._set_attention(data, focus_enemy)
    end

    my_data.attention_unit = attention_key
    my_data._bb_aim_attention_kind = "unit"
    my_data._bb_aim_attention_key = attention_key
    my_data._bb_aim_attention_pos = nil
end

local function set_team_ai_attention_on_pos(data, my_data, focus_enemy, attention_pos)
    local attention_key = get_team_ai_attention_key(focus_enemy)
    local cached_pos = my_data._bb_aim_attention_pos
    local epsilon = CONSTANTS.AIM_ATTENTION_POS_EPSILON or 25
    local needs_update = my_data._bb_aim_attention_kind ~= "pos"
            or my_data._bb_aim_attention_key ~= attention_key
            or not cached_pos
            or mvector3.distance_sq(cached_pos, attention_pos) >= epsilon * epsilon

    if needs_update then
        cached_pos = mvector3.copy(attention_pos)
        CopLogicBase._set_attention_on_pos(data, cached_pos)
    end

    my_data.attention_unit = cached_pos
    my_data._bb_aim_attention_kind = "pos"
    my_data._bb_aim_attention_key = attention_key
    my_data._bb_aim_attention_pos = cached_pos
end

local function reset_team_ai_attention(data, my_data)
    if my_data.attention_unit or my_data._bb_aim_attention_kind then
        CopLogicBase._reset_attention(data)
    end

    my_data.attention_unit = nil
    my_data._bb_aim_attention_kind = nil
    my_data._bb_aim_attention_key = nil
    my_data._bb_aim_attention_pos = nil
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
    Hooks:PostHook(GroupAIStateBase, "init", "BB_GroupAIStateBase_init_ApplyRuntimeSettings", function(self, ...)
        if RuntimeSettings then
            RuntimeSettings:apply_all()
        end
    end)

    if Network:is_server() then
        Hooks:PostHook(GroupAIStateBase, "init", "BB_GroupAIStateBase_init_PreloadConcussion", function(self, ...)
            if RuntimeSettings and RuntimeSettings.apply_concussion then
                RuntimeSettings:apply_concussion(true)
            end
        end)

        install_method_patch(
                "BB_GroupAIStateBase_updTeamAIDistance",
                GroupAIStateBase,
                "upd_team_AI_distance",
                function(original, self, ...)
            if BB:get("keepstaying", false) then
                return
            end
            return original(self, ...)
        end)

        install_method_patch(
                "BB_GroupAIStateBase_chkSayTeamAICombatChatter",
                GroupAIStateBase,
                "chk_say_teamAI_combat_chatter",
                function(original, self, ...)
            if BB:get("chat", false) then
                return
            end
            return original(self, ...)
        end)

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
            install_method_patch(
                    "BB_TeamAIDamage_checkBleedOut",
                    TeamAIDamage,
                    "_check_bleed_out",
                    function(original, self)
                local was_bleed_out = self._bleed_out
                local result = original(self)

                if not was_bleed_out
                and self._bleed_out
                and self._to_dead_clbk_id
                and BB:get("instadwn", false)
                then
                    -- Finish the current damage flow before the native custody transition runs.
                    self._to_dead_t = TimerManager:game():time()
                    self._revive_reminder_line_t = nil

                    managers.enemy:reschedule_delayed_clbk(self._to_dead_clbk_id, self._to_dead_t)
                end

                return result
            end)
        end

        function TeamAIDamage:friendly_fire_hit()
            return
        end

        if TeamAIDamage.accuracy_multiplier then
            install_method_patch(
                    "BB_TeamAIDamage_accuracyMultiplier",
                    TeamAIDamage,
                    "accuracy_multiplier",
                    function(original, self, ...)
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
                     return original(self, ...) * acc_mul
                end
                return original(self, ...)
            end)
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
    if CriminalsManager.character_color_id_by_unit then
        install_method_patch(
                "BB_CriminalsManager_characterColorIdByUnit",
                CriminalsManager,
                "character_color_id_by_unit",
                function(original, self, unit, ...)
            local team_ai_color_id = get_team_ai_player_color_id(self, unit)
            if team_ai_color_id then
                return team_ai_color_id
            end

            return original(self, unit, ...)
        end)
    end

    if Network:is_server() then
        if tweak_data and tweak_data.character and tweak_data.character.presets then
            local char_preset = tweak_data.character.presets
            local gang_weapon = char_preset.weapon and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)

            if gang_weapon then
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
                    end
                end
            end
        end

        if RuntimeSettings then
            RuntimeSettings:apply_all()
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
            if TeamAIMovement.on_SPOOCed then
                install_method_patch(
                        "BB_TeamAIMovement_onSPOOCed",
                        TeamAIMovement,
                        "on_SPOOCed",
                        function(original, self, ...)
                    local settings = Global and Global.game_settings
                    local is_non_public = settings
                            and settings.permission
                            and settings.permission ~= "public"
                    local is_offline = settings and settings.single_player

                    if BB:get("clkarrest", false) and (is_non_public or is_offline) then
                        return self:on_cuffed()
                    end

                    return original(self, ...)
                end)
            end

            install_method_patch(
                    "BB_TeamAIMovement_checkVisualEquipment",
                    TeamAIMovement,
                    "check_visual_equipment",
                    function(original, self, ...)
                if is_bot_weapons_active() or BB:get("equip", false) then
                    return original(self, ...)
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
            end)

            if TeamAIMovement.set_carrying_bag then
                install_method_patch(
                        "BB_TeamAIMovement_setCarryingBag",
                        TeamAIMovement,
                        "set_carrying_bag",
                        function(original, self, unit, ...)
                    original(self, unit, ...)

                    if is_bot_weapons_active() or not managers.hud then
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
                end)
            end

            if TeamAIMovement.set_carry_speed_modifier then
                install_method_patch(
                        "BB_TeamAIMovement_setCarrySpeedModifier",
                        TeamAIMovement,
                        "set_carry_speed_modifier",
                        function(original, self, ...)
                    original(self, ...)

                    if self._carry_speed_modifier then
                        local modifier = math.min(1, self._carry_speed_modifier * CONSTANTS.BAG_SPEED_MUL)
                        self._carry_speed_modifier = modifier < 1 and modifier or nil
                    end
                end)
            end

            if TeamAIMovement.get_reload_speed_multiplier then
                install_method_patch(
                        "BB_TeamAIMovement_getReloadSpeedMultiplier",
                        TeamAIMovement,
                        "get_reload_speed_multiplier",
                        function(original, self, ...)
                    local multiplier = original(self, ...)
                    if BB:get("combat", false)
                            and not is_bot_weapons_active()
                            and self._unit
                            and is_team_ai(self._unit)
                    then
                        return (multiplier or 1) * CONSTANTS.RELOAD_SPEED_MUL
                    end
                    return multiplier
                end)
            end

            if TeamAIMovement.throw_bag then
                install_method_patch(
                        "BB_TeamAIMovement_throwBag",
                        TeamAIMovement,
                        "throw_bag",
                        function(original, self, ...)
                    if self:carrying_bag() then
                        local carry_type_tweak = self:carry_type_tweak()
                        if carry_type_tweak and managers.player then
                            local data = self._ext_brain and self._ext_brain._logic_data
                            local objective = data and data.objective

                            if objective and objective.type == "revive" then
                                local no_cooldown = managers.player.is_custom_cooldown_not_active
                                        and managers.player:is_custom_cooldown_not_active("team", "crew_inspire")

                                if no_cooldown or carry_type_tweak.can_run then
                                    return
                                end
                            end
                        end
                    end

                    return original(self, ...)
                end)
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
            install_method_patch(
                    "BB_CopLogicAttack_updAim",
                    CopLogicAttack,
                    "_upd_aim",
                    function(original, data, my_data)
                local unit = data and data.unit

                if not is_team_ai_move_shoot_unit(unit) then
                    return original(data, my_data)
                end

                local focus_enemy = data.attention_obj
                local reaction = focus_enemy and focus_enemy.reaction
                local focus_unit = focus_enemy and focus_enemy.unit
                local focus_alive = alive(focus_unit)
                local movement = unit:movement()
                local brain = unit:brain()
                local anim_data = unit:anim_data()
                local shoot = false
                local aim = false
                local attention_pos
                local movement_blocked = false

                if focus_alive and type(reaction) == "number" then
                    local weapon_range = my_data.weapon_range
                    local _, _, far_range = get_team_ai_weapon_ranges(weapon_range)
                    local running_range = get_team_ai_running_fire_range(weapon_range)
                    local running = is_team_ai_running(unit, my_data)
                    local target_dis = get_team_ai_attention_distance(data, focus_enemy)
                    local verified = focus_enemy.verified == true
                    local target_pos = focus_enemy.m_pos or focus_enemy.verified_pos or focus_enemy.last_verified_pos
                    local look_pos = focus_enemy.last_verified_pos or focus_enemy.verified_pos

                    far_range = math.max(far_range, running_range)

                    if verified and running then
                        movement_blocked = not is_team_ai_move_direction_allowed(
                                data,
                                movement,
                                target_pos,
                                target_dis,
                                running_range
                        )
                    end

                    if reaction >= AIAttentionObject.REACT_AIM then
                        if verified then
                            if not movement_blocked then
                                aim = true

                                if reaction >= AIAttentionObject.REACT_SHOOT then
                                    local firing_range = running and running_range or far_range
                                    local t = data.t or game_time()
                                    local damage_ext = unit:character_damage()
                                    local last_sup_t = damage_ext
                                            and damage_ext.last_suppression_t
                                            and damage_ext:last_suppression_t()
                                    local suppression_window = running and 2.1 or 7
                                    local recently_suppressed = last_sup_t
                                            and t - last_sup_t < suppression_window
                                    local criminal_record = focus_enemy.criminal_record
                                    local assault_t = criminal_record and criminal_record.assault_t
                                    local recently_assaulted = assault_t and t - assault_t < 2

                                    if running and (recently_suppressed or recently_assaulted) then
                                        firing_range = far_range
                                    end

                                    shoot = target_dis <= firing_range
                                end
                            end
                        else
                            local t = data.t or game_time()
                            local time_since_verification = focus_enemy.verified_t
                                    and t - focus_enemy.verified_t

                            if running then
                                local distance_lerp = math.min(
                                        math.max((target_dis - 500) / 600, 0),
                                        1
                                )
                                local tracking_window = math.lerp(5, 1, distance_lerp)
                                local recently_visible = focus_enemy.nearly_visible
                                        or time_since_verification
                                        and time_since_verification < tracking_window

                                if recently_visible and look_pos then
                                    local direction_allowed = is_team_ai_move_direction_allowed(
                                            data,
                                            movement,
                                            look_pos,
                                            target_dis,
                                            running_range
                                    )

                                    movement_blocked = not direction_allowed

                                    if direction_allowed then
                                        aim = true
                                        attention_pos = look_pos
                                    end
                                else
                                    local expected_pos = CopLogicAttack._get_expected_attention_position(data, my_data)

                                    if expected_pos then
                                        local watch_allowed = can_team_ai_watch_position_while_running(
                                                data,
                                                movement,
                                                expected_pos
                                        )

                                        movement_blocked = not watch_allowed

                                        if watch_allowed then
                                            aim = true
                                            attention_pos = expected_pos
                                        end
                                    end
                                end
                            else
                                attention_pos = look_pos

                                if not attention_pos then
                                    attention_pos = CopLogicAttack._get_expected_attention_position(data, my_data)
                                end

                                aim = attention_pos and true or false
                            end
                        end
                    end

                    if not aim
                            and not movement_blocked
                            and data.char_tweak
                            and data.char_tweak.always_face_enemy
                            and reaction >= AIAttentionObject.REACT_COMBAT
                    then
                        if verified then
                            aim = true
                        else
                            attention_pos = attention_pos or look_pos

                            if attention_pos and running then
                                local direction_allowed = is_team_ai_move_direction_allowed(
                                        data,
                                        movement,
                                        attention_pos,
                                        target_dis,
                                        running_range
                                )

                                movement_blocked = not direction_allowed
                                aim = direction_allowed
                            else
                                aim = attention_pos and true or false
                            end
                        end
                    end

                    if aim and not verified and not attention_pos then
                        aim = false
                    end

                    if aim and data.logic.chk_should_turn(data, my_data) then
                        local turn_pos = verified and target_pos or attention_pos

                        if turn_pos then
                            CopLogicAttack._chk_request_action_turn_to_enemy(
                                    data,
                                    my_data,
                                    data.m_pos,
                                    turn_pos
                            )
                        end
                    end

                    if aim then
                        if verified then
                            set_team_ai_attention_on_unit(data, my_data, focus_enemy)
                        else
                            set_team_ai_attention_on_pos(data, my_data, focus_enemy, attention_pos)
                        end
                    end
                end

                if aim then
                    my_data._bb_aim_stop_requested = nil

                    if not my_data.shooting
                            and not my_data.spooc_attack
                            and not anim_data.reload
                            and not movement:chk_action_forbidden("action")
                    then
                        local shoot_action = {
                            body_part = 3,
                            type = "shoot",
                        }

                        if brain:action_request(shoot_action) then
                            my_data.shooting = true
                        end
                    end
                else
                    shoot = false

                    if my_data.shooting and not my_data._bb_aim_stop_requested then
                        local new_action = anim_data.reload and {
                            body_part = 3,
                            type = "reload",
                        } or {
                            body_part = 3,
                            type = "idle",
                        }

                        if brain:action_request(new_action) then
                            my_data._bb_aim_stop_requested = true
                        end
                    elseif not my_data.shooting then
                        my_data._bb_aim_stop_requested = nil
                    end

                    reset_team_ai_attention(data, my_data)
                end

                CopLogicAttack.aim_allow_fire(shoot, aim, data, my_data)
            end)
        end
    end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
        if Network:is_server() then
            TeamAILogicAssault.mark_enemy = CombatBehavior.mark_enemy
            TeamAILogicAssault.check_smart_reload = CombatBehavior.check_smart_reload
            TeamAILogicAssault._get_priority_attention = CombatBehavior.find_priority_attention

            install_method_patch(
                    "BB_TeamAILogicAssault_update",
                    TeamAILogicAssault,
                    "update",
                    function(original, data, ...)
                local my_data = data and data.internal_data
                local result = original(data, ...)

                if not my_data
                        or my_data ~= data.internal_data
                        or data.name ~= "assault"
                then
                    return result
                end

                local t = game_time()
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

                return result
            end)

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
            install_method_patch(
                    "BB_CopActionShoot_update",
                    CopActionShoot,
                    "update",
                    function(original, self, t)
                if not is_team_ai_move_shoot_unit(self._unit) then
                    return original(self, t)
                end

                local forced_lod = CONSTANTS.TEAMAI_SHOOT_LOD_FORCE
                local ext_base = self._ext_base

                if not forced_lod or not ext_base or type(ext_base.lod_stage) ~= "function" then
                    return original(self, t)
                end

                local original_lod_stage = ext_base.lod_stage

                ext_base.lod_stage = function()
                    return forced_lod
                end

                local ok, err = pcall(function()
                    return original(self, t)
                end)

                ext_base.lod_stage = original_lod_stage

                if not ok then
                    error(err)
                end
            end)

            install_method_patch(
                    "BB_CopActionShoot_getTargetPos",
                    CopActionShoot,
                    "_get_target_pos",
                    function(original, self, shoot_from_pos, attention, ...)
                local target_pos, target_vec, target_dis, autotarget = original(self, shoot_from_pos, attention, ...)

                if not BB:get("combat", false) or not (self._unit and alive(self._unit) and is_team_ai(self._unit)) then
                    return target_pos, target_vec, target_dis, autotarget
                end

                local new_target_pos, new_target_vec, new_target_dis = get_head_target_pos(shoot_from_pos, attention)
                if new_target_pos then
                    return new_target_pos, new_target_vec, new_target_dis, autotarget
                end

                return target_pos, target_vec, target_dis, autotarget
            end)

            install_method_patch(
                    "BB_CopActionShoot_getTransitionTargetPos",
                    CopActionShoot,
                    "_get_transition_target_pos",
                    function(original, self, shoot_from_pos, attention, t, ...)
                local target_pos, target_vec, target_dis, autotarget = original(self, shoot_from_pos, attention, t, ...)

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
            end)
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
                        function(self, attacker_unit, damage_percent, damage_effect_percent, i_body, hit_offset_height, variant, death)
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
                                        local new_reaction = settings.reaction or AIAttentionObject.REACT_IDLE
                                        if new_reaction < REACT_COMBAT then
                                            local their_team = attention_info.team
                                            local foes = my_team and my_team.foes
                                            if their_team and foes and foes[their_team.id] then
                                                new_reaction = REACT_COMBAT
                                            end
                                        end

                                        local detected_settings = settings
                                        if new_reaction ~= settings.reaction then
                                            detected_settings = clone(settings)
                                            detected_settings.reaction = new_reaction
                                        end

                                        local ok, att_obj = safe_call(CopLogicBase._create_detected_attention_object_data, t, unit, u_key, attention_info, detected_settings)
                                        if not ok then att_obj = nil end

                                        if att_obj then
                                            att_obj.identified = true
                                            att_obj.identified_t = t
                                            att_obj.reaction = new_reaction
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
                install_method_patch(
                        "BB_CopLogicIdle_onIntimidated",
                        CopLogicIdle,
                        "on_intimidated",
                        function(original, data, amount, aggressor_unit, ...)
                    local aggressor_key = alive(aggressor_unit) and aggressor_unit:key()
                    local surrender = original(data, amount, aggressor_unit, ...)
                    local unit = data.unit
                    if alive(unit) then
                        local u_key = unit:key()

                        BB:on_intimidation_result(u_key, surrender and true or false, aggressor_key)

                        BB:add_cop_to_intimidation_list(u_key)

                        if surrender then
                            BB:clear_cop_state(u_key)
                        end
                    end
                    return surrender
                end)
            end

            if CopLogicIdle._get_priority_attention then
                install_method_patch(
                        "BB_CopLogicIdle_getPriorityAttention",
                        CopLogicIdle,
                        "_get_priority_attention",
                        function(original, data, attention_objects, reaction_func)
                    if data.is_converted and TeamAILogicIdle and TeamAILogicIdle._get_priority_attention then
                        return TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
                    end

                    return original(data, attention_objects, reaction_func)
                end)
            end
        end
    end

if RequiredScript == "lib/setups/gamesetup" then
    Hooks:PreHook(
            GameSetup,
            "gather_packages_to_unload",
            "BB_GameSetup_gatherPackagesToUnload_ReleaseResources",
            function(self, ...)
                if RuntimeSettings and RuntimeSettings.release_concussion_resource then
                    RuntimeSettings:release_concussion_resource()
                elseif CombatHelper and CombatHelper.release_all_dyn_units then
                    CombatHelper.release_all_dyn_units()
                end
            end
    )
end

if RequiredScript == "lib/managers/mission/elementmissionend" then
        if Network:is_server() then
            install_method_patch(
                    "BB_ElementMissionEnd_onExecuted",
                    ElementMissionEnd,
                    "on_executed",
                    function(original, self, instigator)
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
                    return original(self, instigator)
                end
            end)
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
