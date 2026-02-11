local BB = _G.BB

local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP

local Utils = {}

function Utils.log(msg, level)
    log(string.format("[Better Bots][%s] %s", level or "INFO", tostring(msg)))
end

function Utils.safe_call(func, ...)
    if type(func) ~= "function" then
        local err_msg = "Error: Attempted to call a non-function value (" .. type(func) .. ")"
        Utils.log(err_msg, "ERROR")
        return false, err_msg
    end

    return pcall(func, ...)
end

function Utils.clamp(x, a, b)
    return math.min(math.max(x, a), b)
end

function Utils.game_time()
    local tm = TimerManager
    if tm then
        local game_timer = tm:game()
        if game_timer then
            return game_timer:time()
        end
    end
    return 0
end

function Utils.as_bool_from_item(item)
    return item and item:value() == "on"
end

function Utils.as_number_from_item(item, fallback)
    return item and tonumber(item:value()) or fallback
end

function Utils.get_safe_mask(name, default_slots)
    if name and managers and managers.slot and managers.slot.get_mask then
        local ok, m = Utils.safe_call(managers.slot.get_mask, managers.slot, name)
        if ok and m then
            return m
        end
    end

    if default_slots == nil then
        return World:make_slot_mask()
    elseif type(default_slots) == "table" then
        return World:make_slot_mask(unpack(default_slots))
    elseif type(default_slots) == "number" then
        return World:make_slot_mask(default_slots)
    else
        return World:make_slot_mask()
    end
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

function UnitOps.is_law_unit(unit)
    local t = UnitOps.team(unit)
    return t and t.id == "law1"
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
        Utils.safe_call(snd.say, snd, tostring(line), important, skip_forced)
    end
end

function UnitOps.play_redirect(unit, variant)
    local mov = alive(unit) and unit:movement()
    if mov and mov.play_redirect then
        Utils.safe_call(mov.play_redirect, mov, variant)

        local sess = managers.network and managers.network:session()
        if sess and sess.send_to_peers_synched and Network:is_server() then
            Utils.safe_call(sess.send_to_peers_synched, sess, "play_distance_interact_redirect", unit, variant)
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
    if not (brain and brain.action_request) then
        return false
    end

    local success, ok = Utils.safe_call(
            brain.action_request,
            brain,
            { type = "act", variant = variant, body_part = 3, align_sync = true }
    )
    if not success then
        return false
    end

    if ok and data and data.internal_data then
        data.internal_data.gesture_arrest = true
    end

    return ok
end

BB.Utils = Utils
BB.UnitOps = UnitOps
