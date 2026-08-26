local BB = _G.BB

local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP
local METHOD_PATCHES = BB._method_patches or {}
BB._method_patches = METHOD_PATCHES

local Utils = {}

function Utils.log(msg, level)
    log(string.format("[Better Bots][%s] %s", level or "INFO", tostring(msg)))
end

function Utils.install_method_patch(patch_id, target, method_name, handler)
    if type(patch_id) ~= "string"
            or type(target) ~= "table"
            or type(method_name) ~= "string"
            or type(handler) ~= "function"
    then
        error(string.format("Invalid method patch registration: %s", tostring(patch_id)), 2)
    end

    local current = target[method_name]
    if type(current) ~= "function" then
        error(string.format("Method patch %s could not find %s", patch_id, method_name), 2)
    end

    local existing = METHOD_PATCHES[patch_id]
    if existing then
        if existing.target ~= target or existing.method_name ~= method_name then
            error(string.format("Method patch id %s was reused for a different target", patch_id), 2)
        end

        existing.handler = handler
        return true
    end

    local patch = {
        target = target,
        method_name = method_name,
        original = current,
        handler = handler,
    }

    patch.wrapper = function(...)
        return patch.handler(patch.original, ...)
    end

    target[method_name] = patch.wrapper
    METHOD_PATCHES[patch_id] = patch

    return true
end

function Utils.clamp(x, a, b)
    return math.min(math.max(x, a), b)
end

function Utils.game_time()
    return TimerManager:game():time()
end

function Utils.as_bool_from_item(item)
    return item and item:value() == "on"
end

function Utils.as_number_from_item(item, fallback)
    return item and tonumber(item:value()) or fallback
end

local UnitOps = {}

function UnitOps.head_pos(unit)
    local m = alive(unit) and unit:movement()
    return m and m:m_head_pos() or nil
end

function UnitOps.team(unit)
    if not alive(unit) then
        return nil
    end

    local mov = unit:movement()
    return mov and mov.team and mov:team()
end

function UnitOps.is_team_ai(unit)
    if not alive(unit) then
        return false
    end

    local groupai = managers.groupai
    if not groupai then
        return false
    end

    local state = groupai:state()
    return (state and state:is_unit_team_AI(unit)) or false
end

function UnitOps.has_tag(unit, tag)
    if not alive(unit) then
        return false
    end

    local base = unit:base()
    return (base and base.has_tag and base:has_tag(tag)) or false
end

function UnitOps.are_foes(a, b)
    local ta, tb = UnitOps.team(a), UnitOps.team(b)
    if not (ta and tb) then
        return false
    end

    return (ta.foes and ta.foes[tb.id]) or false
end

function UnitOps.health_ratio(unit)
    if not alive(unit) then
        return 0
    end

    local damage = unit:character_damage()
    if not damage then
        return 0
    end

    return damage.health_ratio and damage:health_ratio() or 0
end

function UnitOps.combat_status(unit)
    local result = {
        can_fight = false,
        is_alive = false,
        is_dead = false,
        is_downed = false,
        is_arrested = false,
        is_tased = false,
    }

    if not alive(unit) then
        return result
    end

    result.is_alive = true

    local damage = unit:character_damage()
    local movement = unit:movement()
    result.is_dead = damage
            and damage.dead
            and damage:dead()
            or false
    result.is_downed = damage
            and damage.need_revive
            and damage:need_revive()
            or false
    result.is_arrested = damage
            and damage.arrested
            and damage:arrested()
            or false
    result.is_tased = movement
            and movement.tased
            and movement:tased()
            or false
    result.can_fight = not result.is_dead
            and not result.is_downed
            and not result.is_arrested
            and not result.is_tased

    return result
end

function UnitOps.is_in_slot(unit, slots_table)
    if not unit or not slots_table then
        return false
    end

    for _, slot in ipairs(slots_table) do
        if unit:in_slot(slot) then
            return true
        end
    end

    return false
end

function UnitOps.say(unit, line, important, skip_forced)
    if not alive(unit) then
        return
    end

    local snd = unit.sound and unit:sound()
    if snd and snd.say then
        snd:say(tostring(line), important, skip_forced)
    end
end

function UnitOps.play_redirect(unit, variant)
    local mov = alive(unit) and unit:movement()
    if mov and mov.play_redirect then
        mov:play_redirect(variant)

        local sess = managers.network and managers.network:session()
        if sess and Network:is_server() then
            sess:send_to_peers_synched("play_distance_interact_redirect", unit, variant)
        end
    end
end

function UnitOps.is_surrendering(unit)
    if not alive(unit) then
        return false
    end

    local anim = unit:anim_data()
    if anim and (anim.hands_back or anim.surrender or anim.hands_tied) then
        return true
    end

    local brain = unit:brain()
    if brain and brain.surrendered and brain:surrendered() then
        return true
    end

    return false
end

function UnitOps.request_act(unit, variant, data)
    local mov = alive(unit) and unit:movement()
    if not (mov and not mov:chk_action_forbidden("action")) then
        return false
    end

    local brain = alive(unit) and unit:brain()
    if not brain then
        return false
    end

    local ok = brain:action_request({
        type = "act",
        variant = variant,
        body_part = 3,
        align_sync = true,
    })

    if ok and data and data.internal_data then
        data.internal_data.gesture_arrest = true
    end

    return ok
end

BB.Utils = Utils
BB.UnitOps = UnitOps
