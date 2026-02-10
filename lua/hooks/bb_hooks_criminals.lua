local BB = _G.BB

if RequiredScript == "lib/managers/criminalsmanager" then
    if Network:is_server() then
        local total_chars = CriminalsManager.get_num_characters and CriminalsManager.get_num_characters() or 4

        if BB:get("biglob", false) then
            CriminalsManager.MAX_NR_TEAM_AI = total_chars
        end

        if tweak_data and tweak_data.character and tweak_data.character.presets then
            local char_preset = tweak_data.character.presets
            local dodge_options = { "poor", "average", "heavy", "athletic", "ninja" }

            local gang_weapon = char_preset.weapon and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)

            if gang_weapon then
                local dodge_idx = BB:get("dodge", 4)
                local dodge_preset = dodge_options[dodge_idx]

                for _, v in pairs(tweak_data.character) do
                    if type(v) == "table" and v.access == "teamAI1" then
                        v.no_run_start = true
                        v.no_run_stop = true
                        v.always_face_enemy = true
                        v.crouch_move = true

                        if char_preset.hurt_severities and char_preset.hurt_severities.no_hurts then
                            v.damage.hurt_severity = char_preset.hurt_severities.no_hurts
                        end

                        if char_preset.move_speed and char_preset.move_speed.lightning then
                            v.move_speed = char_preset.move_speed.lightning
                        end

                        local move_choice = BB:get("move", 1)
                        if move_choice == 2
                                and dodge_preset
                                and char_preset.dodge
                                and char_preset.dodge[dodge_preset]
                        then
                            v.dodge = char_preset.dodge[dodge_preset]
                        elseif move_choice == 3 then
                            v.allowed_poses = { stand = true }
                        end
                    end
                end
            end
        end
    end
end

if RequiredScript == "lib/tweak_data/playertweakdata" then
    if Network:is_server() then
        function PlayerTweakData:_set_singleplayer(...)
            return
        end
    end
end
