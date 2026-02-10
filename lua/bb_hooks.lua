local BB = _G.BB
local hooks_path = BB._path .. "lua/hooks/"

local hook_files = {
    "bb_hooks_init",
    "bb_hooks_groupai",
    "bb_hooks_teamai_base",
    "bb_hooks_teamai_damage",
    "bb_hooks_interaction",
    "bb_hooks_criminals",
    "bb_hooks_weapons",
    "bb_hooks_teamai_movement",
    "bb_hooks_teamai_logic",
    "bb_hooks_cop",
    "bb_hooks_mission",
    "bb_hooks_misc",
}

for _, name in ipairs(hook_files) do
    dofile(hooks_path .. name .. ".lua")
end
