local BB = _G.BB
local SLOTS = BB.SLOTS
local UnitOps = BB.UnitOps
local EnemyClassifier = BB.EnemyClassifier
local CombatBehavior = BB.CombatBehavior
local CoopCacheManager = BB.CoopCacheManager

local Utils = BB.Utils
local safe_call = Utils.safe_call
local is_team_ai = UnitOps.is_team_ai
local is_law_unit = UnitOps.is_law_unit

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
    if Network:is_server() then
        local _bb_orig_get_target_pos = CopActionShoot._get_target_pos

        function CopActionShoot:_get_target_pos(shoot_from_pos, attention, ...)
            local target_pos, target_vec, target_dis, autotarget = _bb_orig_get_target_pos(self, shoot_from_pos, attention, ...)

            if not BB:get("combat", false) or not (self._unit and alive(self._unit) and is_team_ai(self._unit)) then
                return target_pos, target_vec, target_dis, autotarget
            end

            if attention and attention.unit and alive(attention.unit) then
                local target_unit = attention.unit
                local target_movement = target_unit:movement()

                if target_movement and target_movement.m_head_pos then
                    local head_pos = target_movement:m_head_pos()

                    if head_pos then
                        local new_target_pos = Vector3()
                        mvector3.set(new_target_pos, head_pos)

                        local new_target_vec = Vector3()
                        local new_target_dis = mvector3.direction(new_target_vec, shoot_from_pos, new_target_pos)

                        return new_target_pos, new_target_vec, new_target_dis, autotarget
                    end
                end
            end

            return target_pos, target_vec, target_dis, autotarget
        end

        local _bb_orig_get_transition_target_pos = CopActionShoot._get_transition_target_pos

        function CopActionShoot:_get_transition_target_pos(shoot_from_pos, attention, t, ...)
            local target_pos, target_vec, target_dis, autotarget = _bb_orig_get_transition_target_pos(self, shoot_from_pos, attention, t, ...)

            if not BB:get("combat", false) or not (self._unit and alive(self._unit) and is_team_ai(self._unit)) then
                return target_pos, target_vec, target_dis, autotarget
            end

            if attention and attention.unit and alive(attention.unit) then
                local target_unit = attention.unit
                local target_movement = target_unit:movement()

                if target_movement and target_movement.m_head_pos then
                    local head_pos = target_movement:m_head_pos()

                    if head_pos then
                        local new_target_pos = Vector3()
                        mvector3.set(new_target_pos, head_pos)

                        local new_target_vec = Vector3()
                        local new_target_dis = mvector3.direction(new_target_vec, shoot_from_pos, new_target_pos)

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
                end
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
                if self._unit then
                    local flags = BB.classify_enemy(self._unit)
                    if not flags.special then
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

                        if BB.coop_data and BB.coop_data.dozer_attackers then
                            for bot_key, target_key in pairs(BB.coop_data.dozer_attackers) do
                                if tostring(target_key) == u_key_str then
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
