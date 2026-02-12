local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils
local CombatBehavior = BB.CombatBehavior
local IntimidationSystem = BB.IntimidationSystem
local CoopCacheManager = BB.CoopCacheManager

local safe_call = Utils.safe_call
local game_time = Utils.game_time

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
                    local my_data = data.internal_data or {}

                    my_data._next_cache_cleanup_t = my_data._next_cache_cleanup_t or 0
                    if t >= my_data._next_cache_cleanup_t then
                        my_data._next_cache_cleanup_t = t + CONSTANTS.CACHE_CLEANUP_INTERVAL
                        CoopCacheManager.cleanup_all()
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
