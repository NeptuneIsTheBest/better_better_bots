local BB = _G.BB
local Utils = BB.Utils
local safe_call = Utils.safe_call

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
