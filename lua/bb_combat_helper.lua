_G.BB = _G.BB or {}
local BB = _G.BB

local Utils = BB.Utils
local UnitOps = BB.UnitOps

local CombatHelper = {}

function CombatHelper.shield_blocks(attacker, target_head_pos, mask)
    if not (attacker and target_head_pos and mask) then
        return false
    end

    local from = UnitOps.head_pos(attacker)
    if not from then
        return false
    end

    local ray = World:raycast(
            "ray",
            from,
            target_head_pos,
            "ignore_unit",
            { attacker },
            "slot_mask",
            mask
    )
    return ray and true or false
end

function CombatHelper.ensure_dyn_unit_loaded(unit_path)
    local dyn_res = managers.dyn_resource
    if not dyn_res or not unit_path then
        return
    end

    local unit_id = Idstring(unit_path)
    if not dyn_res:is_resource_ready(Idstring("unit"), unit_id, dyn_res.DYN_RESOURCES_PACKAGE) then
        Utils.safe_call(dyn_res.load, dyn_res, Idstring("unit"), unit_id, dyn_res.DYN_RESOURCES_PACKAGE, false)
    end
end

BB.CombatHelper = CombatHelper
