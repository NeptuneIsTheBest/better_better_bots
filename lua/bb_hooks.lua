local BB = _G.BB
local Utils = BB.Utils
local CONSTANTS = BB.CONSTANTS
local UnitOps = BB.UnitOps
local CombatBehavior = BB.CombatBehavior
local IntimidationSystem = BB.IntimidationSystem
local CoopCacheManager = BB.CoopCacheManager
local EnemyClassifier = BB.EnemyClassifier
local RuntimeSettings = BB.RuntimeSettings
local HoldPosition = BB.HoldPosition
local MarkingSystem = BB.MarkingSystem
local RescueCoordinator = BB.RescueCoordinator
local ProactiveAttack = BB.ProactiveAttack
local StatusIcons = BB.StatusIcons

local install_method_patch = Utils.install_method_patch
local game_time = Utils.game_time
local is_team_ai = UnitOps.is_team_ai
local unit_head_pos = UnitOps.head_pos
local safe_say = UnitOps.say
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

local function get_team_ai_running_fire_range(weapon_range)
    local numeric_range = get_valid_weapon_range(weapon_range)
    if numeric_range then
        return numeric_range
    end

    if type(weapon_range) == "table" then
        local range_key = CONSTANTS.MOVE_SHOOT_RUNNING_RANGE or "optimal"
        local configured_range = get_valid_weapon_range(weapon_range[range_key])

        if configured_range then
            return configured_range
        end

        return get_valid_weapon_range(weapon_range.optimal)
                or get_valid_weapon_range(weapon_range.close)
                or get_valid_weapon_range(weapon_range.far)
                or DEFAULT_TEAM_AI_FIRE_RANGE
    end

    return DEFAULT_TEAM_AI_FIRE_RANGE
end

local function is_team_ai_running(unit, my_data)
    local lower_body_action = unit:movement():get_action(2)

    if lower_body_action then
        if lower_body_action:type() ~= "walk" then
            return false
        end

        return not lower_body_action:stopping()
                and lower_body_action:haste() == "run"
    end

    local advancing = my_data and my_data.advancing

    if advancing then
        return not advancing:stopping() and advancing:haste() == "run"
    end

    local anim_data = unit:anim_data()

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

local function clear_team_ai_attention_cache(my_data)
    my_data._bb_aim_attention_kind = nil
    my_data._bb_aim_attention_key = nil
    my_data._bb_aim_attention_pos = nil
    my_data._bb_aim_stop_requested = nil
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
    local chat_color_count = #tweak_data.chat_colors

    return math.max(math.min(tweak_data.max_players, chat_color_count - 1), 0)
end

local function get_team_ai_player_color_id(manager, unit)
    if not alive(unit) then
        return nil
    end

    local target_character = manager:character_by_unit(unit)
    if not (target_character and target_character.taken and target_character.data and target_character.data.ai) then
        return nil
    end

    local fallback_color_id = #tweak_data.chat_colors
    local player_color_limit = get_team_ai_player_color_limit()
    if player_color_limit < 1 then
        return fallback_color_id
    end

    local characters = manager:characters()
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
    local loc_dir = BB._path .. "loc/"
    local files = file.GetFiles(loc_dir)

    local lang_key = SystemInfo:language():key()
    for _, filename in pairs(files) do
        local lang = filename:match("^(.*)%.txt$")
        if lang and Idstring(lang):key() == lang_key then
            loc:load_localization_file(loc_dir .. filename)
            break
        end
    end

    loc:load_localization_file(BB._path .. "loc/english.txt", false)
end)
if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
    Hooks:PostHook(GroupAIStateBase, "init", "BB_GroupAIStateBase_init_ApplyRuntimeSettings", function(self, ...)
        RuntimeSettings:apply_all()
    end)

    Hooks:PostHook(
            GroupAIStateBase,
            "on_simulation_ended",
            "BB_GroupAIStateBase_onSimulationEnded_ResetLevelState",
            function(self, ...)
                BB:reset_level_state()
            end)

    if Network:is_server() then
        Hooks:PostHook(GroupAIStateBase, "init", "BB_GroupAIStateBase_init_PreloadConcussion", function(self, ...)
            RuntimeSettings:apply_concussion(true)
        end)

        install_method_patch(
                GroupAIStateBase,
                "add_special_objective",
                function(original, self, so_id, objective_data, ...)
            local is_rescue = RescueCoordinator.prepare_rescue_special_objective(
                    self,
                    so_id,
                    objective_data
            )
            local result = original(self, so_id, objective_data, ...)

            if is_rescue then
                RescueCoordinator.on_rescue_special_objective_added(self, so_id)
            end

            return result
        end)

        install_method_patch(
                GroupAIStateBase,
                "upd_team_AI_distance",
                function(original, self, ...)
            RescueCoordinator.update(self)
            ProactiveAttack:update(self)

            if BB:get("keepstaying", false) then
                HoldPosition:apply_setting(self)
                HoldPosition:update_all(self)
                return
            end

            HoldPosition:apply_setting(self)

            return original(self, ...)
        end)

        install_method_patch(
                GroupAIStateBase,
                "on_criminal_objective_complete",
                function(original, self, unit, objective, ...)
            HoldPosition:prepare_objective_completion(unit, objective)

            return original(self, unit, objective, ...)
        end)

        install_method_patch(
                GroupAIStateBase,
                "chk_say_teamAI_combat_chatter",
                function(original, self, ...)
            if BB:get("chat", false) then
                return
            end
            return original(self, ...)
        end)

        Hooks:OverrideFunction(GroupAIStateBase, "_get_balancing_multiplier", function(self, balance_multipliers, ...)
            if not balance_multipliers then return 1 end
            local nr_crim = 0
            for _, u_data in pairs(self:all_char_criminals()) do
                if not u_data.status then
                    nr_crim = nr_crim + 1
                end
            end

            nr_crim = math.clamp(nr_crim, 1, #balance_multipliers)
            return balance_multipliers[nr_crim]
        end)
    end
end

if RequiredScript == "lib/managers/hudmanagerpd2" then
    Hooks:PostHook(
            HUDManager,
            "set_ai_stopped",
            "BB_HUDManager_setAIStopped_StatusIcon",
            function(self, ai_id, stopped, ...)
                StatusIcons:on_native_ai_stopped(ai_id, stopped)
            end)
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

            local brain = self._unit:brain()
            if not (brain and brain._logic_data) then
                return
            end

            local my_data = brain._logic_data.internal_data
            if my_data and not my_data.said_hurt then
                if self._health_ratio and self._health_ratio <= 0.2 and not self:need_revive() then
                    my_data.said_hurt = true
                    safe_say(self._unit, "g80x_plu", true, true)
                end
            end
        end)

        Hooks:PostHook(TeamAIDamage, "_regenerated", "BB_TeamAIDamage_regenerated_ResetSaidHurt", function(self)
            if not BB:get("doc", false) then
                return
            end

            local brain = self._unit:brain()
            if brain and brain._logic_data then
                local my_data = brain._logic_data.internal_data
                if my_data then
                    my_data.said_hurt = false
                end
            end
        end)

        install_method_patch(
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
                    self._to_dead_t = TimerManager:game():time()
                    self._revive_reminder_line_t = nil

                    managers.enemy:reschedule_delayed_clbk(self._to_dead_clbk_id, self._to_dead_t)
                end

                return result
        end)

        Hooks:OverrideFunction(TeamAIDamage, "friendly_fire_hit", function(self)
            return
        end)

        install_method_patch(
                TeamAIDamage,
                "accuracy_multiplier",
                function(original, self, ...)
                if BB:get("combat", false) then
                     local ThreatAssessment = BB.ThreatAssessment
                     local archetype = ThreatAssessment.get_weapon_archetype(self._unit)
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

if RequiredScript == "lib/units/interactions/interactionext" then
    if Network:is_server() then
        local function pack_results(...)
            local results = { ... }
            results.n = select("#", ...)

            return results
        end

        local function cancel_other_rescue_objectives(revive_unit, rescuer)
            if not (alive(revive_unit) and alive(rescuer)) then
                return
            end

            local gstate = managers.groupai:state()

            local revive_key = revive_unit:key()
            local rescuer_key = rescuer:key()

            for u_key, u_data in pairs(gstate:all_AI_criminals()) do
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

                        RescueCoordinator.on_rescue_interaction(self._unit, player, false)
                    end
                end
        )

        Hooks:PostHook(
                ReviveInteractionExt,
                "_at_interact_interupt",
                "BB_ReviveInteractionExt_atInteractInterrupt_RescueGuard",
                function(self, player, complete, ...)
                    if (self.tweak_data == "revive" or self.tweak_data == "free")
                            and complete ~= true
                    then
                        RescueCoordinator.on_rescue_interaction(
                                self._unit,
                                player,
                                false
                        )
                    end
                end
        )

        install_method_patch(
                ReviveInteractionExt,
                "remove_interact",
                function(original, self, ...)
            local results = pack_results(original(self, ...))
            local attempt = self._bb_rescue_interact_attempt

            if attempt then
                attempt.completed = true
            end

            return unpack(results, 1, results.n)
        end)

        install_method_patch(
                ReviveInteractionExt,
                "interact",
                function(original, self, player, ...)
            local is_rescue = self.tweak_data == "revive" or self.tweak_data == "free"
            if not is_rescue then
                return original(self, player, ...)
            end

            local previous_attempt = self._bb_rescue_interact_attempt
            local attempt = {}
            self._bb_rescue_interact_attempt = attempt

            local results = pack_results(pcall(original, self, player, ...))

            self._bb_rescue_interact_attempt = previous_attempt

            if not results[1] then
                error(results[2], 0)
            end

            if attempt.completed then
                self._tweak_data_at_interact_start = nil
                RescueCoordinator.on_rescue_interaction(
                        self._unit,
                        player,
                        true
                )
            end

            return unpack(results, 2, results.n)
        end)
    end
end

if RequiredScript == "lib/managers/criminalsmanager" then
    install_method_patch(
            CriminalsManager,
            "character_color_id_by_unit",
            function(original, self, unit, ...)
            local team_ai_color_id = get_team_ai_player_color_id(self, unit)
            if team_ai_color_id then
                return team_ai_color_id
            end

            return original(self, unit, ...)
    end)

    local char_preset = tweak_data.character.presets
    local gang_weapon = char_preset.weapon
            and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)

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

    if Network:is_server() then
        RuntimeSettings:apply_all()
    end
end

if RequiredScript == "lib/tweak_data/playertweakdata" then
    Hooks:OverrideFunction(PlayerTweakData, "_set_singleplayer", function(self, ...)
        return
    end)
end

local friendly_weapon_user_mask
local friendly_bullet_collision_mask

local function get_friendly_weapon_masks()
    if not friendly_weapon_user_mask then
        friendly_weapon_user_mask = managers.slot:get_mask(
                "criminals_no_deployables",
                "harmless_criminals"
        )
        friendly_bullet_collision_mask = managers.slot:get_mask(
                "criminals_no_deployables",
                "harmless_criminals",
                "hostages"
        )
    end

    return friendly_weapon_user_mask, friendly_bullet_collision_mask
end

local function remove_friendly_characters_from_bullet_mask(self)
    local user_unit = self._setup and self._setup.user_unit
    if not (alive(user_unit) and self._bullet_slotmask) then
        return
    end

    local weapon_user_mask, collision_mask = get_friendly_weapon_masks()
    if user_unit:in_slot(weapon_user_mask) then
        self._bullet_slotmask = self._bullet_slotmask - collision_mask
    end
end

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then
    Hooks:PostHook(
            NewNPCRaycastWeaponBase,
            "setup",
            "BB_NewNPCRaycastWeaponBase_setup_RemoveFriendlyMask",
            remove_friendly_characters_from_bullet_mask
    )
end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
    Hooks:PostHook(
            NPCRaycastWeaponBase,
            "setup",
            "BB_NPCRaycastWeaponBase_setup_RemoveFriendlyMask",
            remove_friendly_characters_from_bullet_mask
    )
end

if RequiredScript == "lib/units/player_team/teamaimovement" then
    if Network:is_server() then
        install_method_patch(
                TeamAIMovement,
                "set_should_stay",
                function(original, self, should_stay, ...)
            if not should_stay and HoldPosition:should_preserve_temporary_release(self._unit) then
                return
            end

            if should_stay then
                HoldPosition:capture(self._unit, true)
            end

            local result = original(self, should_stay, ...)

            if not should_stay then
                HoldPosition:clear(self._unit, true)
            end

            return result
        end)

        install_method_patch(
                TeamAIMovement,
                "on_SPOOCed",
                function(original, self, ...)
            local settings = Global.game_settings
            local is_non_public = settings.permission and settings.permission ~= "public"
            local is_offline = settings.single_player

            if BB:get("clkarrest", false) and (is_non_public or is_offline) then
                return self:on_cuffed()
            end

            return original(self, ...)
        end)
    end

    install_method_patch(
            TeamAIMovement,
            "check_visual_equipment",
            function(original, self, ...)
                if is_bot_weapons_active() or BB:get("equip", false) then
                    return original(self, ...)
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
                        damage_ext:run_sequence_simple("var_model_02")
                    end
                end
            end)

    install_method_patch(
            TeamAIMovement,
            "set_carrying_bag",
            function(original, self, unit, ...)
                original(self, unit, ...)

                if is_bot_weapons_active() or not managers.hud then
                    return
                end

                local unit_data = self._unit and self._unit:unit_data()
                local name_label_id = unit_data and unit_data.name_label_id
                local name_label = name_label_id and managers.hud:_get_name_label(name_label_id)

                if name_label and name_label.panel then
                    local bag_panel = name_label.panel:child("bag")
                    if bag_panel then
                        bag_panel:set_visible(unit and true or false)
                    end
                end
            end)

    install_method_patch(
            TeamAIMovement,
            "set_carry_speed_modifier",
            function(original, self, ...)
                original(self, ...)

                if self._carry_speed_modifier then
                    local modifier = math.min(1, self._carry_speed_modifier * CONSTANTS.BAG_SPEED_MUL)
                    self._carry_speed_modifier = modifier < 1 and modifier or nil
                end
            end)

    install_method_patch(
            TeamAIMovement,
            "get_reload_speed_multiplier",
            function(original, self, ...)
                local multiplier = original(self, ...)
                if BB:get("combat", false)
                        and not is_bot_weapons_active()
                then
                    return (multiplier or 1) * CONSTANTS.RELOAD_SPEED_MUL
                end
                return multiplier
            end)

    if Network:is_server() then
        install_method_patch(
                TeamAIMovement,
                "throw_bag",
                function(original, self, ...)
            if self:carrying_bag() then
                local carry_type_tweak = self:carry_type_tweak()
                if carry_type_tweak and managers.player then
                    local data = self._ext_brain and self._ext_brain._logic_data
                    local objective = data and data.objective

                    if objective and objective.type == "revive" then
                        local no_cooldown = managers.player:is_custom_cooldown_not_active(
                                "team",
                                "crew_inspire"
                        )

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

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
        if Network:is_server() then
            local native_priority_attention = Hooks:GetFunction(
                    TeamAILogicIdle,
                    "_get_priority_attention"
            )

            Hooks:OverrideFunction(
                    TeamAILogicIdle,
                    "_get_priority_attention",
                    function(data, attention_objects, reaction_func)
                return CombatBehavior.find_priority_attention(
                        data,
                        attention_objects,
                        reaction_func,
                        native_priority_attention
                )
            end)

            install_method_patch(
                    TeamAILogicIdle,
                    "enter",
                    function(original, data, ...)
                local result = original(data, ...)

                RescueCoordinator.maybe_interrupt_rescue(data)

                return result
            end)

            install_method_patch(
                    TeamAILogicIdle,
                    "_upd_enemy_detection",
                    function(original, data, ...)
                local result = original(data, ...)

                RescueCoordinator.maybe_interrupt_rescue(data)

                return result
            end)

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
                            if CopLogicBase.is_alert_aggressive(alert_type) then
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

if RequiredScript == "lib/units/player_team/logics/teamailogictravel" then
        if Network:is_server() then
            install_method_patch(
                    TeamAILogicTravel,
                    "_determine_destination_occupation",
                    function(original, data, objective, ...)
                local occupation = RescueCoordinator.get_guard_destination_occupation(
                        data,
                        objective
                )
                if occupation then
                    return occupation
                end

                return original(data, objective, ...)
            end)
    end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicattack" then
        if Network:is_server() then
            install_method_patch(
                    CopLogicAttack,
                    "_upd_aim",
                    function(original, data, my_data)
                local unit = data and data.unit

                if not is_team_ai_move_shoot_unit(unit) then
                    return original(data, my_data)
                end

                if not is_team_ai_running(unit, my_data) then
                    clear_team_ai_attention_cache(my_data)

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

                if focus_alive and type(reaction) == "number" then
                    local running_range = get_team_ai_running_fire_range(my_data.weapon_range)
                    local target_dis = get_team_ai_attention_distance(data, focus_enemy)
                    local verified = focus_enemy.verified == true
                    local look_pos = focus_enemy.last_verified_pos or focus_enemy.verified_pos

                    if reaction >= AIAttentionObject.REACT_AIM then
                        if verified then
                            aim = true

                            if reaction >= AIAttentionObject.REACT_SHOOT then
                                shoot = target_dis <= running_range
                            end
                        else
                            local t = data.t or game_time()
                            local time_since_verification = focus_enemy.verified_t
                                    and t - focus_enemy.verified_t
                            local distance_lerp = math.min(
                                    math.max((target_dis - 500) / 600, 0),
                                    1
                            )
                            local tracking_window = math.lerp(5, 1, distance_lerp)
                            local recently_visible = focus_enemy.nearly_visible
                                    or time_since_verification
                                    and time_since_verification < tracking_window

                            if recently_visible and look_pos then
                                aim = true
                                attention_pos = look_pos
                            else
                                local expected_pos = CopLogicAttack._get_expected_attention_position(data, my_data)

                                if expected_pos
                                        and can_team_ai_watch_position_while_running(
                                                data,
                                                movement,
                                                expected_pos
                                        )
                                then
                                    aim = true
                                    attention_pos = expected_pos
                                end
                            end
                        end
                    end

                    if not aim
                            and data.char_tweak
                            and data.char_tweak.always_face_enemy
                            and reaction >= AIAttentionObject.REACT_COMBAT
                    then
                        if verified then
                            aim = true
                        elseif look_pos
                                and can_team_ai_watch_position_while_running(
                                        data,
                                        movement,
                                        look_pos
                                )
                        then
                            aim = true
                            attention_pos = look_pos
                        end
                    end

                    if aim and not verified and not attention_pos then
                        aim = false
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

                if shoot and not my_data.shooting then
                    shoot = false
                end

                CopLogicAttack.aim_allow_fire(shoot, aim, data, my_data)
            end)
        end
    end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
        if Network:is_server() then
            TeamAILogicAssault.check_smart_reload = CombatBehavior.check_smart_reload

            Hooks:OverrideFunction(TeamAILogicAssault, "find_enemy_to_mark", function()
                return nil
            end)

            Hooks:PostHook(
                    TeamAILogicAssault,
                    "_upd_enemy_detection",
                    "BB_TeamAILogicAssault_updEnemyDetection_Marking",
                    function(data, ...)
                        MarkingSystem.on_detection_updated(data)
                    end
            )

            install_method_patch(
                    TeamAILogicAssault,
                    "chk_should_turn",
                    function(original, data, my_data, ...)
                if HoldPosition:can_turn_in_place(data, my_data) then
                    return true
                end

                return original(data, my_data, ...)
            end)

            install_method_patch(
                    TeamAILogicAssault,
                    "update",
                    function(original, data, ...)
                if RescueCoordinator.update_solo_fallback(data) then
                    return
                end

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
                        if CombatBehavior.throw_concussion_grenade(data, unit) then
                            my_data._conc_cooldown_t = t + CONSTANTS.CONC_COOLDOWN
                        end
                    end
                end

                if (not my_data.melee_t) or (my_data.melee_t + CONSTANTS.MELEE_CHECK_INTERVAL < t) then
                    my_data.melee_t = t

                    if (not data._bb_melee_cooldown_t) or t >= data._bb_melee_cooldown_t then
                        local retry_delay = CombatBehavior.execute_melee_attack(data, unit)

                        if retry_delay then
                            data._bb_melee_cooldown_t = t + retry_delay
                        end
                    end
                end

                if (not my_data.reload_t) or (my_data.reload_t + CONSTANTS.RELOAD_CHECK_INTERVAL < t) then
                    my_data.reload_t = t
                    CombatBehavior.check_smart_reload(data)
                end

                HoldPosition:update_combat_pose(data)

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
                CombatBehavior.check_smart_reload(data)
            end)
        end
    end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
        if Network:is_server() then
            Hooks:PostHook(
                    TeamAILogicBase,
                    "_set_attention_obj",
                    "BB_TeamAILogicBase_setAttentionObj_CheckIntimidation",
                    function(data, new_att_obj, new_reaction)
                        IntimidationSystem.perform_interaction_check(data)
                    end
            )
        end
    end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
    install_method_patch(
            CopActionShoot,
            "on_attention",
            function(original, self, attention, ...)
                local result = original(self, attention, ...)

                if attention
                        and BB:get("reflex", false)
                        and is_team_ai_move_shoot_unit(self._unit)
                then
                    self._mod_enable_t = 0
                    self._aim_transition = nil
                    self._get_target_pos = nil
                end

                return result
            end)

    install_method_patch(
            CopActionShoot,
            "update",
            function(original, self, t)
                if not is_team_ai_move_shoot_unit(self._unit)
                        or not is_team_ai_running(self._unit)
                then
                    return original(self, t)
                end

                local forced_lod = CONSTANTS.TEAMAI_SHOOT_LOD_FORCE
                if not forced_lod then
                    return original(self, t)
                end

                local ext_base = self._ext_base
                local original_lod_stage = rawget(ext_base, "lod_stage")

                rawset(ext_base, "lod_stage", function()
                    return forced_lod
                end)

                local ok, err = pcall(function()
                    return original(self, t)
                end)

                rawset(ext_base, "lod_stage", original_lod_stage)

                if not ok then
                    error(err, 0)
                end
            end)

    install_method_patch(
            CopActionShoot,
            "_get_target_pos",
            function(original, self, shoot_from_pos, attention, ...)
                local target_pos, target_vec, target_dis, autotarget = original(self, shoot_from_pos, attention, ...)

                if not BB:get("combat", false) or not is_team_ai(self._unit) then
                    return target_pos, target_vec, target_dis, autotarget
                end

                local new_target_pos, new_target_vec, new_target_dis = get_head_target_pos(shoot_from_pos, attention)
                if new_target_pos then
                    return new_target_pos, new_target_vec, new_target_dis, autotarget
                end

                return target_pos, target_vec, target_dis, autotarget
            end
    )

    install_method_patch(
            CopActionShoot,
            "_get_transition_target_pos",
            function(original, self, shoot_from_pos, attention, t, ...)
                local target_pos, target_vec, target_dis, autotarget = original(self, shoot_from_pos, attention, t, ...)

                if not BB:get("combat", false) or not is_team_ai(self._unit) then
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
    )
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
                    if not EnemyClassifier.is_special(self._unit) then
                        BB:add_cop_to_intimidation_list(self._unit:key())
                    end
                end
            end

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

            Hooks:PostHook(
                    CopDamage,
                    "sync_damage_melee",
                    "BB_CopDamage_syncDamageMelee_AddToIntimList",
                    function(self, attacker_unit, damage_percent, damage_effect_percent, i_body, hit_offset_height, variant, death)
                        handle_taser_damage(self, variant)
                    end
            )

            Hooks:PreHook(
                    CopDamage,
                    "damage_bullet",
                    "BB_CopDamage_damageBullet_SimpleDamage",
                    function(self, attack_data, ...)
                        if attack_data.attacker_unit
                        and alive(attack_data.attacker_unit)
                        and is_team_ai(attack_data.attacker_unit)
                        and attack_data.damage
                        then
                            local dmg_mul = BB.ThreatAssessment.get_archetype_damage_multiplier(attack_data.attacker_unit)
                            attack_data.damage = attack_data.damage * dmg_mul
                        end
                    end
            )

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

                            BB.CoopSystem.remove_target(u_key_str)
                        end
                    end
            )
        end
    end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
        if Network:is_server() then
            local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
            local REACT_IDLE = AIAttentionObject.REACT_IDLE
            local REFLEX_DETECTION_DELAY = CONSTANTS.REFLEX_DETECTION_DELAY
            local mvec3_copy = mvector3.copy
            local mvec3_dis = mvector3.distance
            local mvec3_dis_sq = mvector3.distance_sq
            local mvec3_set = mvector3.set

            local function get_reflex_reaction(settings, attention_info, my_team)
                local reaction = settings.reaction or REACT_IDLE

                if reaction < REACT_COMBAT then
                    local their_team = attention_info.team
                    local foes = my_team and my_team.foes

                    if their_team and foes and foes[their_team.id] then
                        reaction = REACT_COMBAT
                    end
                end

                return reaction
            end

            local function get_reflex_settings(att_obj, settings, reaction)
                if reaction == settings.reaction then
                    return settings
                end

                local current_settings = att_obj and att_obj.settings
                if current_settings
                        and current_settings.reaction == reaction
                        and att_obj._bb_reflex_settings_source == settings
                        and att_obj._bb_reflex_settings_override == current_settings
                then
                    return current_settings
                end

                local detected_settings = clone(settings)
                detected_settings.reaction = reaction

                return detected_settings
            end

            local function clear_reflex_state(data)
                data._bb_reflex_active = nil
                data._bb_reflex_next_scan_t = nil

                for _, att_obj in pairs(data.detected_attention_objects or {}) do
                    local source_settings = att_obj._bb_reflex_settings_source
                    local override_settings = att_obj._bb_reflex_settings_override

                    if source_settings
                            and override_settings
                            and att_obj.settings == override_settings
                    then
                        att_obj.settings = source_settings
                        att_obj.reaction = source_settings.reaction or REACT_IDLE
                    end

                    att_obj._bb_reflex_settings_source = nil
                    att_obj._bb_reflex_settings_override = nil
                    att_obj._bb_reflex_next_focus_verify_t = nil
                end
            end

            local function is_reflex_observer(data, unit)
                local cached = data._bb_reflex_is_team_ai

                if cached == nil then
                    cached = is_team_ai(unit) and true or false
                    data._bb_reflex_is_team_ai = cached
                end

                return cached
            end

            local function is_reflex_candidate(att_obj, u_key, focus_key, t)
                if not att_obj or not att_obj.identified or not att_obj.verified then
                    return true
                end

                return u_key == focus_key
                        and t >= (att_obj._bb_reflex_next_focus_verify_t or 0)
            end

            local function is_reflex_in_range(my_data, settings, my_pos, attention_pos)
                local detection = my_data and my_data.detection
                local max_dis = detection and detection.dis_max

                if type(max_dis) ~= "number" or max_dis <= 0 then
                    return false
                end

                local settings_max_dis = settings.max_range
                if type(settings_max_dis) == "number" then
                    max_dis = math.min(max_dis, settings_max_dis)
                end

                local settings_detection = settings.detection
                local range_mul = settings_detection and settings_detection.range_mul
                if type(range_mul) == "number" then
                    max_dis = max_dis * range_mul
                end

                return max_dis > 0
                        and mvec3_dis_sq(my_pos, attention_pos) < max_dis * max_dis
            end

            local function set_reflex_unverified(att_obj, vis_ray, t, is_focus)
                if not att_obj then
                    return
                end

                att_obj.verified = false
                att_obj.vis_ray = vis_ray and (vis_ray.dis or vis_ray.distance) or nil

                if is_focus then
                    att_obj._bb_reflex_next_focus_verify_t = t + REFLEX_DETECTION_DELAY
                end
            end

            local function set_reflex_verified(
                    data,
                    detected_obj,
                    u_key,
                    attention_info,
                    settings,
                    reaction,
                    attention_pos,
                    my_pos,
                    t,
                    is_focus
            )
                local att_obj = detected_obj[u_key]
                local detected_settings = get_reflex_settings(att_obj, settings, reaction)

                if not att_obj then
                    att_obj = CopLogicBase._create_detected_attention_object_data(
                            t,
                            data.unit,
                            u_key,
                            attention_info,
                            detected_settings
                    )

                    if not att_obj then
                        return
                    end

                    detected_obj[u_key] = att_obj
                else
                    att_obj.settings = detected_settings
                    att_obj.reaction = reaction
                end

                if detected_settings ~= settings then
                    att_obj._bb_reflex_settings_source = settings
                    att_obj._bb_reflex_settings_override = detected_settings
                else
                    att_obj._bb_reflex_settings_source = nil
                    att_obj._bb_reflex_settings_override = nil
                end

                local was_identified = att_obj.identified
                local target_pos = att_obj.m_pos
                local distance = data.m_pos and target_pos
                        and mvec3_dis(data.m_pos, target_pos)
                        or mvec3_dis(my_pos, attention_pos)

                att_obj.notice_progress = nil
                att_obj.prev_notice_chk_t = nil
                att_obj.identified = true
                att_obj.identified_t = was_identified and att_obj.identified_t or t
                att_obj.reaction = reaction
                att_obj.verified = true
                att_obj.verified_t = t
                att_obj.release_t = nil
                att_obj.nearly_visible = nil
                att_obj.vis_ray = nil
                att_obj.dis = distance
                att_obj.verified_dis = distance
                att_obj.next_verify_t = t + (settings.verification_interval or REFLEX_DETECTION_DELAY)

                if att_obj.m_head_pos then
                    mvec3_set(att_obj.m_head_pos, attention_pos)
                else
                    att_obj.m_head_pos = mvec3_copy(attention_pos)
                end

                if att_obj.verified_pos then
                    mvec3_set(att_obj.verified_pos, attention_pos)
                else
                    att_obj.verified_pos = mvec3_copy(attention_pos)
                end

                if att_obj.last_verified_pos then
                    mvec3_set(att_obj.last_verified_pos, attention_pos)
                else
                    att_obj.last_verified_pos = mvec3_copy(attention_pos)
                end

                if is_focus then
                    att_obj._bb_reflex_next_focus_verify_t = t + REFLEX_DETECTION_DELAY
                end

                if not was_identified then
                    local logic = data.logic
                    if logic and logic.on_attention_obj_identified then
                        logic.on_attention_obj_identified(data, u_key, att_obj)
                    end

                    local notice_clbk = detected_settings.notice_clbk
                    if notice_clbk then
                        notice_clbk(data.unit, true)
                    end
                end
            end

            local function update_reflex_detection(data, min_reaction, max_reaction)
                local unit = data and data.unit

                if not BB:get("reflex", false) then
                    if data and data._bb_reflex_active then
                        clear_reflex_state(data)
                    end

                    return false
                end

                if not alive(unit) or not is_reflex_observer(data, unit) then
                    return false
                end

                local t = data.t or game_time()
                local next_scan_t = data._bb_reflex_next_scan_t

                if next_scan_t and t < next_scan_t then
                    return true
                end

                local unit_mov = unit:movement()
                local my_tracker = unit_mov:nav_tracker()
                local gstate = managers.groupai:state()
                if not my_tracker then
                    return false
                end

                data._bb_reflex_active = true
                data._bb_reflex_next_scan_t = t + REFLEX_DETECTION_DELAY

                local my_key = data.key
                local detected_obj = data.detected_attention_objects or {}
                data.detected_attention_objects = detected_obj

                local my_pos = unit_mov:m_head_pos()
                local my_data = data.internal_data
                local my_access = data.SO_access
                local my_team = data.team
                local slotmask = data.visibility_slotmask
                local focus_key = data.attention_obj and data.attention_obj.u_key
                local chk_vis_func = my_tracker.check_visibility
                local all_attention_objects = gstate:get_AI_attention_objects_by_filter(
                        data.SO_access_str,
                        my_team
                )

                if not all_attention_objects then
                    return true
                end

                for u_key, attention_info in pairs(all_attention_objects) do
                    if u_key ~= my_key then
                        local att_obj = detected_obj[u_key]
                        local is_focus = u_key == focus_key

                        if is_reflex_candidate(att_obj, u_key, focus_key, t) then
                            local att_tracker = attention_info.nav_tracker
                            local nav_visible = not att_tracker
                                    or chk_vis_func(my_tracker, att_tracker)

                            if nav_visible then
                                local att_handler = attention_info.handler
                                if att_handler
                                        and att_handler.get_attention
                                        and att_handler.get_detection_m_pos
                                then
                                    local settings = att_handler:get_attention(
                                            my_access,
                                            min_reaction,
                                            max_reaction,
                                            my_team
                                    )
                                    local reaction = settings
                                            and get_reflex_reaction(settings, attention_info, my_team)

                                    if reaction and reaction >= REACT_COMBAT then
                                        local attention_pos = att_handler:get_detection_m_pos()

                                        if attention_pos
                                                and is_reflex_in_range(
                                                        my_data,
                                                        settings,
                                                        my_pos,
                                                        attention_pos
                                                )
                                        then
                                            local vis_ray = World:raycast(
                                                    "ray",
                                                    my_pos,
                                                    attention_pos,
                                                    "slot_mask",
                                                    slotmask,
                                                    "ray_type",
                                                    "ai_vision"
                                            )
                                            local visible = not vis_ray
                                                    or vis_ray.unit and vis_ray.unit:key() == u_key

                                            if visible then
                                                set_reflex_verified(
                                                        data,
                                                        detected_obj,
                                                        u_key,
                                                        attention_info,
                                                        settings,
                                                        reaction,
                                                        attention_pos,
                                                        my_pos,
                                                        t,
                                                        is_focus
                                                )
                                            else
                                                set_reflex_unverified(
                                                        att_obj,
                                                        vis_ray,
                                                        t,
                                                        is_focus
                                                )
                                            end
                                        elseif att_obj then
                                            set_reflex_unverified(att_obj, nil, t, is_focus)
                                        end
                                    end
                                end
                            elseif att_obj
                                    and type(att_obj.reaction) == "number"
                                    and att_obj.reaction >= REACT_COMBAT
                            then
                                set_reflex_unverified(att_obj, nil, t, is_focus)
                            end
                        end
                    end
                end

                return true
            end

            install_method_patch(
                    CopLogicBase,
                    "_upd_attention_obj_detection",
                    function(original, data, min_reaction, max_reaction, ...)
                local reflex_active = update_reflex_detection(data, min_reaction, max_reaction)
                local delay = original(data, min_reaction, max_reaction, ...)

                if reflex_active
                        and (type(delay) ~= "number" or delay > REFLEX_DETECTION_DELAY)
                then
                    return REFLEX_DETECTION_DELAY
                end

                return delay
            end)
        end
    end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then
        if Network:is_server() then
            Hooks:PostHook(CopLogicIdle, "enter", "BB_CopLogicIdle_enter_CheckSmartReload", function(data, ...)
                if data.is_converted then
                    CombatBehavior.check_smart_reload(data)
                end
            end)

            install_method_patch(
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

            install_method_patch(
                    CopLogicIdle,
                    "_get_priority_attention",
                    function(original, data, attention_objects, reaction_func)
                if data.is_converted then
                    return TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
                end

                return original(data, attention_objects, reaction_func)
            end)
        end
    end

if RequiredScript == "lib/setups/gamesetup" then
    Hooks:PostHook(
            GameSetup,
            "update",
            "BB_GameSetup_update_StatusIcons",
            function(self, t, dt, ...)
                StatusIcons:update(t, dt)
            end
    )

    Hooks:PreHook(
            GameSetup,
            "gather_packages_to_unload",
            "BB_GameSetup_gatherPackagesToUnload_ReleaseResources",
            function(self, ...)
                BB:reset_level_state()
                RuntimeSettings:release_concussion_resource()
            end
    )
end

if RequiredScript == "lib/managers/mission/elementmissionend" then
        if Network:is_server() then
            install_method_patch(
                    ElementMissionEnd,
                    "on_executed",
                    function(original, self, instigator)
                local is_offline = Global.game_settings.single_player

                if is_offline
                        and self._values.enabled
                        and self._values.state == "success"
                        and managers.platform:presence() == "Playing"
                then
                    local session = managers.network:session()
                    local num_winners = session:amount_of_alive_players()
                            + managers.groupai:state():amount_of_winning_ai_criminals()

                    session:send_to_peers("mission_ended", true, num_winners)
                    game_state_machine:change_state_by_name("victoryscreen", {
                        num_winners = num_winners,
                        personal_win = alive(managers.player:player_unit()),
                    })

                    ElementMissionEnd.super.on_executed(self, instigator)
                else
                    return original(self, instigator)
                end
            end)
        end
    end

if RequiredScript == "lib/units/player_team/teamaibrain" then
        if Network:is_server() then
            Hooks:PostHook(
                    TeamAIBrain,
                    "on_cop_neutralized",
                    "BB_TeamAIBrain_onCopNeutralized_RefreshDetection",
                    function(self, cop_key)
                        if not BB:get("coop", false)
                                or not alive(self._unit)
                                or not BB.CoopSystem.is_teammate_combat_ready(self._unit)
                        then
                            return
                        end

                        local data = self._logic_data
                        local my_data = data and data.internal_data
                        local task_key = my_data and my_data.detection_task_key
                        if not (task_key
                                and my_data.queued_tasks
                                and my_data.queued_tasks[task_key])
                        then
                            return
                        end

                        local enemy_manager = managers.enemy
                        if enemy_manager and enemy_manager.update_queue_task then
                            enemy_manager:update_queue_task(
                                    task_key,
                                    nil,
                                    nil,
                                    game_time(),
                                    nil,
                                    true
                            )
                        end
                    end
            )

            install_method_patch(
                    TeamAILogicDisabled,
                    "_register_revive_SO",
                    function(original, data, my_data, rescue_type, ...)
                if data and data.name == "surrender" then
                    rescue_type = "untie"
                end

                return original(data, my_data, rescue_type, ...)
            end)

            install_method_patch(
                    TeamAIBrain,
                    "on_long_dis_interacted",
                    function(original, self, amount, other_unit, secondary, ...)
                local previous_objective = self:objective()
                HoldPosition:begin_long_distance_interaction(self._unit, other_unit, secondary)

                local results = {
                    pcall(original, self, amount, other_unit, secondary, ...)
                }

                HoldPosition:end_long_distance_interaction(self._unit)

                local ok = table.remove(results, 1)
                if not ok then
                    error(results[1], 0)
                end

                ProactiveAttack:on_long_distance_interacted(
                        self._unit,
                        other_unit,
                        secondary,
                        previous_objective
                )

                return unpack(results)
            end)

            Hooks:PostHook(TeamAIBrain, "_reset_logic_data", "BB_TeamAIBrain_resetLogicData_AddTurretMask", function(self)
                if self._logic_data and self._logic_data.enemy_slotmask then
                    local turrets_mask = managers.slot:get_mask("sentry_gun")
                    self._logic_data.enemy_slotmask = self._logic_data.enemy_slotmask + turrets_mask
                end
            end)
        end
    end

if RequiredScript == "lib/units/equipment/sentry_gun/sentrygunbase" then
    Hooks:PostHook(
            SentryGunBase,
            "activate_as_module",
            "BB_SentryGunBase_FixTurretTargeting",
            function(self)
                self._unit:movement():set_team(self._unit:movement():team())
            end)
end
