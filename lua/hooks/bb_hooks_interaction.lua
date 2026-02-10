local BB = _G.BB
local Utils = BB.Utils
local safe_call = Utils.safe_call

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
