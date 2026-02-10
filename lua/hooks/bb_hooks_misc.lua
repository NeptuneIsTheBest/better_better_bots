local BB = _G.BB
local SLOTS = BB.SLOTS

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
