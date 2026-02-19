local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils
local UnitOps = BB.UnitOps

local safe_call = Utils.safe_call
local is_team_ai = UnitOps.is_team_ai

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

                local orig_set_carrying_bag = TeamAIMovement.set_carrying_bag

                function TeamAIMovement:set_carrying_bag(unit, ...)
                    local old_carry_unit = self._carry_unit

                    orig_set_carrying_bag(self, unit, ...)

                    if not managers.hud then
                        return
                    end

                    local bag_unit = unit or old_carry_unit

                    if unit and unit:carry_data() then
                        if not self.set_visual_carry and HuskPlayerMovement then
                            TeamAIMovement.set_visual_carry = HuskPlayerMovement.set_visual_carry
                            TeamAIMovement._destroy_current_carry_unit = HuskPlayerMovement._destroy_current_carry_unit
                            TeamAIMovement._create_carry_unit = HuskPlayerMovement._create_carry_unit
                        end
                        if self.set_visual_carry then
                            self:set_visual_carry(unit:carry_data():carry_id())
                        end
                    else
                        if self.set_visual_carry then
                            self:set_visual_carry(nil)
                        end
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