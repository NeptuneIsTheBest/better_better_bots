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

    local weapon_unit = inventory and inventory.equipped_unit and inventory:equipped_unit()
    local weapon_base = alive(weapon_unit) and weapon_unit:base()

    return weapon_base
            and weapon_base._is_team_ai
            and weapon_base._has_ap_rounds
            and true
            or false
end

function CombatHelper.target_context(unit, attention, position)
    local flags = BB.classify_enemy(attention.unit, attention)
    local shield_blocked = flags.shield
            and not CombatHelper.has_ap_ammo(unit)
            and CombatHelper.shield_blocks_default(unit, position)
            or false

    return { flags = flags, shield_blocked = shield_blocked }
end

function CombatHelper.can_fire_at(data, attention)
    local internal = data.internal_data or {}
    local cover = internal._bb_cover_tactics
    local key = attention.u_key or attention.unit:key()
    if cover and tostring(cover.target_key) == tostring(key) and cover.lane == "blocked" then
        return false
    end

    local movement = data.unit:movement()
    local walk = movement:get_action(2)
    local advancing = internal.advancing
    local anim = data.unit:anim_data() or {}
    if data.char_tweak and data.char_tweak.no_move_and_shoot and (anim.move or anim.act) then
        return false
    end

    local running
    if walk then
        running = walk:type() == "walk" and not walk:stopping() and walk:haste() == "run"
    elseif advancing then
        running = not advancing:stopping() and advancing:haste() == "run"
    else
        running = anim.run
    end
    if not running then
        return true
    end

    local function positive(value)
        return type(value) == "number" and value > 0 and value or nil
    end
    local range = internal.weapon_range
    local limit = positive(range)
    if type(range) == "table" then
        limit = positive(range[BB.CONSTANTS.MOVE_SHOOT_RUNNING_RANGE])
                or positive(range.optimal) or positive(range.close) or positive(range.far)
    end
    local distance = attention.verified_dis or attention.dis
    return type(distance) == "number" and distance <= (limit or 500)
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
