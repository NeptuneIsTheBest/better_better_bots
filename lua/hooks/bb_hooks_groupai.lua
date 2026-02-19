local BB = _G.BB
local CombatHelper = BB.CombatHelper

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
