local BB = _G.BB

local UnitOps = BB.UnitOps

local CombatHelper = BB.CombatHelper or {}
local owned_dyn_units = BB._owned_dyn_units or {}
local enemy_shield_check_mask

BB._owned_dyn_units = owned_dyn_units

function CombatHelper.shield_blocks(attacker, target_head_pos, mask)
    if not (attacker and target_head_pos and mask) then
        return false
    end

    local from = UnitOps.head_pos(attacker)
    if not from then
        return false
    end

    local ray = World:raycast("ray", from, target_head_pos, "ignore_unit", { attacker }, "slot_mask", mask, "report")
    return ray and true or false
end

function CombatHelper.shield_blocks_default(attacker, target_head_pos)
    enemy_shield_check_mask = enemy_shield_check_mask
            or managers.slot:get_mask("enemy_shield_check")

    return CombatHelper.shield_blocks(attacker, target_head_pos, enemy_shield_check_mask)
end

function CombatHelper.has_ap_ammo(unit)
    local inventory = alive(unit) and unit:inventory()
    if inventory and inventory.has_ap_ammo and inventory:has_ap_ammo() then
        return true
    end

    return managers.player
        and managers.player:has_category_upgrade("team", "crew_ai_ap_ammo")
        or false
end

function CombatHelper.acquire_dyn_unit(unit_path)
    if type(unit_path) ~= "string" or unit_path == "" then
        return false
    end

    if owned_dyn_units[unit_path] then
        return true
    end

    local dyn_res = managers.dyn_resource
    local package_name = dyn_res and dyn_res.DYN_RESOURCES_PACKAGE
    if not (dyn_res and package_name) then
        return false
    end

    local resource_type = Idstring("unit")
    local resource_name = Idstring(unit_path)
    dyn_res:load(resource_type, resource_name, package_name, false)

    owned_dyn_units[unit_path] = {
        resource_type = resource_type,
        resource_name = resource_name,
        package_name = package_name,
    }

    return true
end

function CombatHelper.release_dyn_unit(unit_path)
    local resource = owned_dyn_units[unit_path]
    if not resource then
        return true
    end

    local dyn_res = managers.dyn_resource
    if not dyn_res then
        return false
    end

    dyn_res:unload(
            resource.resource_type,
            resource.resource_name,
            resource.package_name,
            false
    )
    owned_dyn_units[unit_path] = nil

    return true
end

function CombatHelper.release_all_dyn_units()
    local unit_paths = {}

    for unit_path in pairs(owned_dyn_units) do
        table.insert(unit_paths, unit_path)
    end

    local success = true

    for _, unit_path in ipairs(unit_paths) do
        if not CombatHelper.release_dyn_unit(unit_path) then
            success = false
        end
    end

    return success
end

BB.CombatHelper = CombatHelper
