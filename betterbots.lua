_G.BB = _G.BB or {}
local BB = _G.BB

dofile(ModPath .. "lua/bb_constants.lua")
local SLOTS = BB.SLOTS

dofile(ModPath .. "lua/bb_utils.lua")

dofile(ModPath .. "lua/bb_cache.lua")
dofile(ModPath .. "lua/bb_enemy_classifier.lua")
dofile(ModPath .. "lua/bb_combat_helper.lua")
dofile(ModPath .. "lua/bb_clustering.lua")
dofile(ModPath .. "lua/bb_threat_assessment.lua")

local MASK = {
    AI_visibility = World:make_slot_mask(1, 11, 38, 39),
    enemy_shield_check = World:make_slot_mask(8),
    hostages = World:make_slot_mask(SLOTS.HOSTAGES),
    players = World:make_slot_mask(unpack(SLOTS.PLAYERS)),
    criminals_no_deployables = World:make_slot_mask(unpack(SLOTS.CRIMINALS_NO_DEPLOYABLES)),
}
BB.MASK = MASK

dofile(ModPath .. "lua/bb_state.lua")
dofile(ModPath .. "lua/bb_hold_position.lua")
dofile(ModPath .. "lua/bb_runtime_settings.lua")
dofile(ModPath .. "lua/bb_hungarian.lua")
dofile(ModPath .. "lua/bb_coop.lua")
dofile(ModPath .. "lua/bb_rescue_coordination.lua")
dofile(ModPath .. "lua/bb_combat_behavior.lua")
dofile(ModPath .. "lua/bb_concussion.lua")
dofile(ModPath .. "lua/bb_intimidation_system.lua")

dofile(ModPath .. "lua/bb_menu.lua")
dofile(ModPath .. "lua/bb_hooks.lua")
