local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local UnitOps = BB.UnitOps

local is_team_ai = UnitOps.is_team_ai
local safe_say = UnitOps.say

if RequiredScript == "lib/units/player_team/teamaidamage" then
    if Network:is_server() then
        local health_multipliers = { nil, 2, 3 }

        Hooks:PostHook(TeamAIDamage, "init", "BB_TeamAIDamage_init_HealthBoost", function(self, unit)
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
