_G.BB = _G.BB or {}
local BB = _G.BB

dofile(ModPath .. "lua/bb_constants.lua")

dofile(ModPath .. "lua/bb_utils.lua")

dofile(ModPath .. "lua/bb_cache.lua")
dofile(ModPath .. "lua/bb_enemy_classifier.lua")
dofile(ModPath .. "lua/bb_combat_helper.lua")
dofile(ModPath .. "lua/bb_clustering.lua")
dofile(ModPath .. "lua/bb_threat_assessment.lua")
dofile(ModPath .. "lua/bb_marking_system.lua")

dofile(ModPath .. "lua/bb_state.lua")
dofile(ModPath .. "lua/bb_hold_position.lua")
dofile(ModPath .. "lua/bb_runtime_settings.lua")
dofile(ModPath .. "lua/bb_hungarian.lua")
dofile(ModPath .. "lua/bb_assignment_planner.lua")
dofile(ModPath .. "lua/bb_coop.lua")
dofile(ModPath .. "lua/bb_rescue_coordination.lua")
dofile(ModPath .. "lua/bb_proactive_attack.lua")
dofile(ModPath .. "lua/bb_status_icons.lua")
dofile(ModPath .. "lua/bb_combat_behavior.lua")
dofile(ModPath .. "lua/bb_concussion.lua")
dofile(ModPath .. "lua/bb_intimidation_system.lua")

dofile(ModPath .. "lua/bb_menu.lua")
dofile(ModPath .. "lua/bb_hooks.lua")
