local BB = _G.BB
local SLOTS = BB.SLOTS
local MASK = BB.MASK
local UnitOps = BB.UnitOps

local is_unit_in_slot = UnitOps.is_in_slot

local function remove_ai_and_players_from_bullet_mask(self)
    local user_unit = self._setup and self._setup.user_unit
    if alive(user_unit)
            and (is_unit_in_slot(user_unit, SLOTS.PLAYERS)
            or is_unit_in_slot(user_unit, SLOTS.CRIMINALS_NO_DEPLOYABLES))
            and self._bullet_slotmask
    then
        local ai_friends_mask = MASK.criminals_no_deployables + MASK.players + MASK.hostages
        self._bullet_slotmask = self._bullet_slotmask - ai_friends_mask
    end
end

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then
    if Network:is_server() then
        Hooks:PostHook(NewNPCRaycastWeaponBase, "setup", "BB_NewNPCRaycastWeaponBase_setup_RemoveFriendlyMask", remove_ai_and_players_from_bullet_mask)
    end
end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
    if Network:is_server() then
        Hooks:PostHook(NPCRaycastWeaponBase, "setup", "BB_NPCRaycastWeaponBase_setup_RemoveFriendlyMask", remove_ai_and_players_from_bullet_mask)
    end
end
