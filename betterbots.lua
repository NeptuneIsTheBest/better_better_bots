_G.BB = _G.BB or {}
local BB = _G.BB

dofile(ModPath .. "lua/bb_constants.lua")
local SLOTS = BB.SLOTS

dofile(ModPath .. "lua/bb_utils.lua")
local Utils = BB.Utils

dofile(ModPath .. "lua/bb_cache.lua")
dofile(ModPath .. "lua/bb_enemy_classifier.lua")
dofile(ModPath .. "lua/bb_combat_helper.lua")
dofile(ModPath .. "lua/bb_clustering.lua")
dofile(ModPath .. "lua/bb_threat_assessment.lua")

local MASK = {
    AI_visibility = Utils.get_safe_mask("AI_visibility", { 1, 11, 38, 39 }),
    enemy_shield_check = Utils.get_safe_mask("enemy_shield_check", 8),
    hostages = Utils.get_safe_mask("hostages", 22),
    players = Utils.get_safe_mask("players", SLOTS.PLAYERS),
    criminals_no_deployables = Utils.get_safe_mask("criminals_no_deployables", SLOTS.CRIMINALS_NO_DEPLOYABLES),
}
BB.MASK = MASK

dofile(ModPath .. "lua/bb_state.lua")
dofile(ModPath .. "lua/bb_hungarian.lua")
dofile(ModPath .. "lua/bb_coop.lua")
dofile(ModPath .. "lua/bb_combat_behavior.lua")
dofile(ModPath .. "lua/bb_concussion.lua")
dofile(ModPath .. "lua/bb_intimidation_system.lua")

dofile(ModPath .. "lua/bb_menu.lua")
dofile(ModPath .. "lua/bb_hooks.lua")
