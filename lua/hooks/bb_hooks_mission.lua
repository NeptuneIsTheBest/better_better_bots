local BB = _G.BB
local Utils = BB.Utils
local game_time = Utils.game_time

if RequiredScript == "lib/managers/mission/elementmissionend" then
    if Network:is_server() then
        local old_ElementMissionEnd_on_executed = ElementMissionEnd.on_executed

        ElementMissionEnd.on_executed = function(self, instigator)
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
                return old_ElementMissionEnd_on_executed(self, instigator)
            end
        end
    end
end
