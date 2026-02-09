local BB = _G.BB
local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local CombatBehavior = BB.CombatBehavior

local safe_call = Utils.safe_call
local game_time = Utils.game_time
local are_units_foes = UnitOps.are_foes
local safe_say = UnitOps.say
local request_act = UnitOps.request_act

local IntimidationSystem = {}

function IntimidationSystem.get_intimidate_range()
    local ldi = tweak_data and tweak_data.player and tweak_data.player.long_dis_interaction
    return (ldi and ldi.intimidate_range_enemies) or CONSTANTS.INTIMIDATE_DISTANCE
end

function IntimidationSystem.get_char_tweak(unit)
    if not alive(unit) then
        return nil
    end

    local base = unit:base()
    if base and base.char_tweak and base:char_tweak() then
        return base:char_tweak()
    end

    local tbl = base and base._tweak_table
    return tweak_data and tweak_data.character and tbl and tweak_data.character[tbl]
end

function IntimidationSystem.is_valid_target(target_unit, data, distance, allow_new_attempts)
    if not (alive(target_unit) and data) then
        return false
    end

    local u_key = target_unit:key()
    if BB:is_blacklisted_cop(u_key) then
        return false
    end

    local ud = type(target_unit.unit_data) == "function" and target_unit:unit_data() or nil
    if ud and ud.disable_shout then
        return false
    end

    local anim = target_unit:anim_data() or {}
    local char_tweak = IntimidationSystem.get_char_tweak(target_unit)
    local surrender = char_tweak and char_tweak.surrender

    local flags = BB.classify_enemy(target_unit)
    if flags and flags.special then
        return false
    end

    if not surrender or anim.hands_tied then
        return false
    end

    local t = data.t or game_time()
    local brain = target_unit:brain()
    local ldata = brain and brain._logic_data
    local sw = ldata and ldata.surrender_window

    if sw and t > sw.window_expire_t then
        return false
    end

    local intimidate_range = IntimidationSystem.get_intimidate_range()
    if distance and distance > intimidate_range then
        return false
    end

    if anim.hands_back or anim.surrender then
        return true
    end

    local gstate = managers.groupai and managers.groupai:state()
    if not (gstate and gstate:has_room_for_police_hostage()) then
        return false
    end

    if sw and t > (sw.window_expire_t - sw.window_duration + 0.75) then
        return true
    end

    if not allow_new_attempts then
        return false
    end

    if distance and distance > intimidate_range * 0.75 then
        return false
    end

    local health_max = 0
    local surrender_health = (surrender and surrender.reasons and surrender.reasons.health)
            or (surrender and surrender.factors and surrender.factors.health)
            or {}

    for k, _ in pairs(surrender_health) do
        if k > health_max then
            health_max = k
        end
    end

    local dmg = target_unit:character_damage()
    local hr = (dmg and dmg.health_ratio and dmg:health_ratio()) or 1

    if health_max > 0 and hr > (health_max / 2) then
        return false
    end

    local num = 0
    local max = 2

    if gstate then
        for _, u_data in pairs(gstate:all_char_criminals() or {}) do
            if u_data and u_data.status == "dead" then
                max = max + 2
            end
        end
    end

    local dis_th = intimidate_range * 1.5
    for _, v in pairs(data.detected_attention_objects or {}) do
        if v and v.verified and v.unit ~= target_unit then
            local vunit = v.unit
            local vdamage = vunit and vunit.character_damage and vunit:character_damage()
            local vdis = v.verified_dis or v.dis
            if vdis and vdis < dis_th and vdamage and not vdamage:dead() then
                num = num + 1
                if num > max then
                    return false
                end
            end
        end
    end

    return true
end

function IntimidationSystem.find_enemy_to_intimidate(data)
    if not (alive(data.unit) and data.unit:movement()) then
        return nil
    end

    local unit = data.unit
    local my_mov = unit:movement()
    local my_pos = data.m_pos or (my_mov and (my_mov:m_pos() or my_mov:m_head_pos()))
    local look_vec = my_mov and my_mov:m_rot():y()
    if not (my_pos and look_vec) then
        return nil
    end

    local consider_all = BB:get("dom", false)
    local intimidate_range = IntimidationSystem.get_intimidate_range()

    local candidates = {}
    if consider_all then
        candidates = data.detected_attention_objects or {}
    else
        local detected = data.detected_attention_objects or {}
        local detected_by_str = {}
        for att_key, att_obj in pairs(detected) do
            detected_by_str[tostring(att_key)] = att_obj
        end

        for u_key, t0 in pairs(BB.cops_to_intimidate or {}) do
            if data.t - t0 < BB.grace_period then
                local att_obj = detected_by_str[u_key]
                if att_obj then
                    candidates[u_key] = att_obj
                end
            end
        end
    end

    local best_unit
    local best_score = math.huge

    for _, u_char in pairs(candidates) do
        if u_char and u_char.identified and alive(u_char.unit) then
            local cop = u_char.unit
            if not BB:is_blacklisted_cop(cop:key()) then
                local anim_data = cop:anim_data() or {}
                local is_surrender_state = anim_data.hands_back or anim_data.surrender

                if are_units_foes(unit, cop) or is_surrender_state then
                    local dis = u_char.verified_dis
                            or (u_char.m_head_pos and my_pos and mvector3.distance(my_pos, u_char.m_head_pos))

                    if dis and dis <= intimidate_range and u_char.m_pos then
                        local vec = u_char.m_pos - my_pos
                        if mvector3.angle(vec, look_vec) <= CONSTANTS.INTIMIDATE_ANGLE then
                            local valid = IntimidationSystem.is_valid_target(cop, data, dis, consider_all)
                            if valid then
                                local health_ratio = UnitOps.health_ratio(cop)
                                local is_hurt = health_ratio < 1

                                local priority = anim_data.hands_back and 3
                                        or anim_data.surrender and 2
                                        or (is_hurt and 1)
                                        or 0.5

                                local score = dis / priority
                                if score < best_score then
                                    best_score = score
                                    best_unit = cop
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best_unit
end

function IntimidationSystem.intimidate_law_enforcement(data, intim_unit, play_action)
    if not alive(intim_unit) or BB:is_blacklisted_cop(intim_unit:key()) then
        return
    end

    local my_pos = data.m_pos
            or (data.unit:movement()
            and (data.unit:movement():m_pos() or data.unit:movement():m_head_pos()))

    local tgt_pos = intim_unit:movement() and intim_unit:movement():m_head_pos()
    local dis = (my_pos and tgt_pos) and mvector3.distance(my_pos, tgt_pos) or nil
    local allow_new = BB:get("dom", false)

    if not IntimidationSystem.is_valid_target(intim_unit, data, dis, allow_new) then
        return
    end

    local anim_data = intim_unit:anim_data()
    if not anim_data then
        return
    end

    local actions = {
        hands_back = { act = "arrest", sound = "l03x_sin" },
        surrender = { act = "arrest", sound = "l02x_sin" },
        default = { act = "gesture_stop", sound = "l01x_sin" },
    }

    local action = anim_data.hands_back and actions.hands_back
            or anim_data.surrender and actions.surrender
            or actions.default

    local unit = data.unit
    if not alive(unit) then
        return
    end

    safe_say(unit, action.sound, true, true)

    if play_action then
        request_act(unit, action.act, data)
    end

    BB:on_intimidation_attempt(intim_unit:key())

    local intim_brain = intim_unit:brain()
    if intim_brain and intim_brain.on_intimidated then
        intim_brain:on_intimidated(1, unit)
    end
end

function IntimidationSystem.perform_interaction_check(data)
    local unit = data.unit
    if not alive(unit) then
        return
    end

    local unit_damage = unit:character_damage()
    if unit_damage and unit_damage:need_revive() then
        return
    end

    local anim_data = unit:anim_data()
    if not anim_data or anim_data.tased then
        return
    end

    local my_data = data.internal_data or {}
    if my_data.acting then
        return
    end

    local t = data.t
    local unit_sound = unit:sound()
    if unit_sound and unit_sound:speaking() then
        return
    end

    if my_data._intimidate_t and my_data._intimidate_t + CONSTANTS.INTIMIDATE_COOLDOWN >= t then
        return
    end

    my_data._intimidate_t = t

    local carrying = unit:movement() and unit:movement():carrying_bag()
    local allow_actions = (not anim_data.reload) and (not carrying)

    local civ = TeamAILogicIdle
            and TeamAILogicIdle.find_civilian_to_intimidate
            and TeamAILogicIdle.find_civilian_to_intimidate(
            unit,
            CONSTANTS.INTIMIDATE_ANGLE,
            IntimidationSystem.get_intimidate_range()
    )

    local dom = IntimidationSystem.find_enemy_to_intimidate(data)
    local nmy = CombatBehavior.find_enemy_to_mark(data.detected_attention_objects, unit)

    if alive(civ) and TeamAILogicIdle and TeamAILogicIdle.intimidate_civilians then
        safe_call(TeamAILogicIdle.intimidate_civilians, data, unit, true, allow_actions)
    elseif alive(dom) then
        safe_call(IntimidationSystem.intimidate_law_enforcement, data, dom, allow_actions)
    elseif alive(nmy) then
        data._last_mark_t = data._last_mark_t or 0
        if data._last_mark_t + CONSTANTS.MARK_COOLDOWN < t then
            safe_call(CombatBehavior.mark_enemy, data, unit, nmy, true, allow_actions)
            data._last_mark_t = t
        end
    end
end

BB.IntimidationSystem = IntimidationSystem
BB.is_valid_intimidation_target = IntimidationSystem.is_valid_target
