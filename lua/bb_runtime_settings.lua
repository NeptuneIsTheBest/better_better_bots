local BB = _G.BB

local RuntimeSettings = BB.RuntimeSettings or {}
local CombatHelper = BB.CombatHelper
local HoldPosition = BB.HoldPosition
BB.RuntimeSettings = RuntimeSettings

local DODGE_OPTIONS = {
    "poor",
    "average",
    "heavy",
    "athletic",
    "ninja",
}

local function is_server()
    return Network:is_server()
end

local function restore_movement_entry(entry, original)
    entry.dodge = original.dodge
    entry.allowed_poses = original.allowed_poses
end

local function ensure_loadout_slots(limit)
    local criminal_manager = managers.criminals
    local loadout_slots = criminal_manager and criminal_manager._loadout_slots

    if type(loadout_slots) ~= "table" or type(limit) ~= "number" then
        return
    end

    for i = 1, limit do
        if loadout_slots[i] == nil then
            loadout_slots[i] = {}
        end
    end
end

local function get_concussion_unit_paths()
    local concussion = tweak_data.blackmarket.projectiles.concussion
    return concussion.unit, concussion.sprint_unit
end

function RuntimeSettings:apply_team_ai_movement()
    if not is_server() then
        return false
    end

    local character_tweaks = tweak_data.character
    local presets = character_tweaks.presets

    if self._movement_character_tweaks ~= character_tweaks then
        self._movement_character_tweaks = character_tweaks
        self._movement_originals = {}
        self._movement_override_active = false
    end

    local move_choice = tonumber(BB:get("move", 1)) or 1
    local override_active = move_choice == 2 or move_choice == 3
    local originals = self._movement_originals

    if not override_active then
        if self._movement_override_active then
            for entry, original in pairs(originals) do
                restore_movement_entry(entry, original)
            end
        end

        self._movement_originals = {}
        self._movement_override_active = false

        return true
    end

    local dodge_idx = tonumber(BB:get("dodge", 4)) or 4
    local dodge_name = DODGE_OPTIONS[dodge_idx] or DODGE_OPTIONS[4]
    local dodge_preset = presets.dodge[dodge_name]

    for _, entry in pairs(character_tweaks) do
        if type(entry) == "table" and entry.access == "teamAI1" then
            local original = originals[entry]

            if not original then
                original = {
                    dodge = entry.dodge,
                    allowed_poses = entry.allowed_poses,
                }
                originals[entry] = original
            end

            restore_movement_entry(entry, original)

            if move_choice == 2 and dodge_preset then
                entry.dodge = dodge_preset
            elseif move_choice == 3 then
                entry.allowed_poses = { stand = true }
            end
        end
    end

    self._movement_override_active = true

    return true
end

function RuntimeSettings:apply_big_lobby()
    if not is_server() then
        return false
    end

    if self._big_lobby_class ~= CriminalsManager then
        self._big_lobby_class = CriminalsManager
        self._big_lobby_original_max = nil
        self._big_lobby_override_active = false
    end

    local enabled = BB:get("biglob", false)

    if enabled then
        if not self._big_lobby_override_active then
            self._big_lobby_original_max = CriminalsManager.MAX_NR_TEAM_AI
        end

        local total_characters = CriminalsManager.get_num_characters()

        CriminalsManager.MAX_NR_TEAM_AI = total_characters
        self._big_lobby_override_active = true
        ensure_loadout_slots(total_characters)
    elseif self._big_lobby_override_active then
        CriminalsManager.MAX_NR_TEAM_AI = self._big_lobby_original_max
        ensure_loadout_slots(self._big_lobby_original_max)

        self._big_lobby_original_max = nil
        self._big_lobby_override_active = false
    end

    return true
end

function RuntimeSettings:release_concussion_resource()
    local unit_path, sprint_unit_path = get_concussion_unit_paths()
    unit_path = self._concussion_resource_path or unit_path
    sprint_unit_path = self._concussion_sprint_resource_path or sprint_unit_path

    local unit_released = CombatHelper.release_dyn_unit(unit_path)
    local sprint_unit_released = CombatHelper.release_dyn_unit(sprint_unit_path)

    if unit_released then
        self._concussion_resource_path = nil
    end
    if sprint_unit_released then
        self._concussion_sprint_resource_path = nil
    end

    return unit_released and sprint_unit_released
end

function RuntimeSettings:apply_concussion(allow_acquire)
    if not BB:get("conc", false) or not is_server() then
        return self:release_concussion_resource()
    end

    if not allow_acquire and not managers.groupai then
        return false
    end

    local unit_path, sprint_unit_path = get_concussion_unit_paths()

    if (self._concussion_resource_path and self._concussion_resource_path ~= unit_path)
            or (self._concussion_sprint_resource_path
                and self._concussion_sprint_resource_path ~= sprint_unit_path)
    then
        if not self:release_concussion_resource() then
            return false
        end
    end

    local unit_acquired = CombatHelper.acquire_dyn_unit(unit_path)
    local sprint_unit_acquired = CombatHelper.acquire_dyn_unit(sprint_unit_path)

    if unit_acquired then
        self._concussion_resource_path = unit_path
    end
    if sprint_unit_acquired then
        self._concussion_sprint_resource_path = sprint_unit_path
    end

    return unit_acquired and sprint_unit_acquired
end

function RuntimeSettings:apply_hold_position()
    if not is_server() then
        return false
    end

    local group_ai = managers.groupai
    local group_state = group_ai and group_ai:state() or nil

    return HoldPosition:apply_setting(group_state)
end

function RuntimeSettings:apply_coop()
    if not is_server() then
        return false
    end

    local coop_system = BB.CoopSystem
    coop_system.reset_level_state()
    return true
end

function RuntimeSettings:apply_proactive()
    if not is_server() then
        return false
    end

    local proactive_attack = BB.ProactiveAttack
    local group_ai = managers.groupai
    local group_state = group_ai and group_ai:state() or nil

    return proactive_attack:apply_setting(group_state)
end

function RuntimeSettings:apply(key)
    if key == "move" or key == "dodge" then
        return self:apply_team_ai_movement()
    elseif key == "biglob" then
        return self:apply_big_lobby()
    elseif key == "conc" then
        return self:apply_concussion(false)
    elseif key == "keepstaying" then
        return self:apply_hold_position()
    elseif key == "coop" then
        return self:apply_coop()
    elseif key == "proactive" then
        return self:apply_proactive()
    elseif key == "debug" then
        return BB.DebugOverlay:apply_setting()
    end

    return false
end

function RuntimeSettings:apply_all()
    local movement_applied = self:apply_team_ai_movement()
    local big_lobby_applied = self:apply_big_lobby()
    local hold_position_applied = self:apply_hold_position()
    local proactive_applied = self:apply_proactive()

    return movement_applied
            or big_lobby_applied
            or hold_position_applied
            or proactive_applied
end
