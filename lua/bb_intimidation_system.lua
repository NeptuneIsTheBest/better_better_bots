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
local EMPTY_RAY_IGNORE_UNITS = {}

local function get_interaction_geometry(data, target_unit)
    local unit = data and data.unit
    if not (alive(unit) and alive(target_unit)) then
        return nil
    end

    local my_mov = unit:movement()
    local target_mov = target_unit:movement()
    if not (my_mov and target_mov) then
        return nil
    end

    local my_pos = my_mov:m_head_pos()
    local target_head_pos = target_mov:m_head_pos()
    local my_rot = my_mov:m_rot()
    local look_vec = my_rot and my_rot:y()
    if not (my_pos and target_head_pos and look_vec) then
        return nil
    end

    local target_pos = target_head_pos + math.UP * 30
    local target_vec = target_pos - my_pos
    local distance = mvector3.distance(my_pos, target_pos)
    local angle = mvector3.angle(target_vec, look_vec)

    return my_pos, target_pos, distance, angle
end

local function has_interaction_line_of_sight(data, my_pos, target_pos)
    local visibility_mask = (data and data.visibility_slotmask)
            or (BB.MASK and BB.MASK.AI_visibility)
    if not (visibility_mask and my_pos and target_pos) then
        return false
    end

    local ray = World:raycast(
            "ray",
            my_pos,
            target_pos,
            "slot_mask",
            visibility_mask,
            "ray_type",
            "ai_vision mover",
            "ignore_unit",
            EMPTY_RAY_IGNORE_UNITS
    )

    return not ray
            or (ray.position and mvector3.distance_sq(ray.position, target_pos) < 900)
end

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
    if anim.long_dis_interact_disabled then
        return false
    end

    local dmg = type(target_unit.character_damage) == "function"
            and target_unit:character_damage()
            or nil
    if dmg and dmg.dead and dmg:dead() then
        return false
    end

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
        if u_char and u_char.identified and u_char.verified and alive(u_char.unit) then
            local cop = u_char.unit
            if not BB:is_blacklisted_cop(cop:key()) then
                local anim_data = cop:anim_data() or {}
                local is_surrender_state = anim_data.hands_back or anim_data.surrender

                if are_units_foes(unit, cop) or is_surrender_state then
                    local my_pos, target_pos, dis, angle = get_interaction_geometry(data, cop)
                    if dis
                            and dis <= intimidate_range
                            and angle <= CONSTANTS.INTIMIDATE_ANGLE
                            and IntimidationSystem.is_valid_target(cop, data, dis, consider_all)
                            and has_interaction_line_of_sight(data, my_pos, target_pos)
                    then
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

    return best_unit
end

function IntimidationSystem.intimidate_law_enforcement(data, intim_unit, play_action)
    if not alive(intim_unit) or BB:is_blacklisted_cop(intim_unit:key()) then
        return false
    end

    local unit = data.unit
    if not alive(unit) then
        return false
    end

    local anim_data = intim_unit:anim_data()
    if not anim_data then
        return false
    end

    local is_surrender_state = anim_data.hands_back or anim_data.surrender
    if not (are_units_foes(unit, intim_unit) or is_surrender_state) then
        return false
    end

    local my_pos, target_pos, dis, angle = get_interaction_geometry(data, intim_unit)
    local allow_new = BB:get("dom", false)

    if not dis
            or angle > CONSTANTS.INTIMIDATE_ANGLE
            or not IntimidationSystem.is_valid_target(intim_unit, data, dis, allow_new)
            or not has_interaction_line_of_sight(data, my_pos, target_pos)
    then
        return false
    end

    local intim_brain = intim_unit:brain()
    if not (intim_brain and intim_brain.on_intimidated) then
        return false
    end

    local actions = {
        hands_back = { act = "arrest", sound = "l03x_sin" },
        surrender = { act = "arrest", sound = "l02x_sin" },
        default = { act = "gesture_stop", sound = "l01x_sin" },
    }

    local action = anim_data.hands_back and actions.hands_back
            or anim_data.surrender and actions.surrender
            or actions.default

    safe_say(unit, action.sound, true, true)

    if play_action then
        request_act(unit, action.act, data)
    end

    BB:on_intimidation_attempt(intim_unit:key())
    intim_brain:on_intimidated(1, unit)

    return true
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

    local carrying = unit:movement() and unit:movement():carrying_bag()
    local allow_actions = (not anim_data.reload) and (not carrying)

    local civ = TeamAILogicIdle
            and TeamAILogicIdle.find_civilian_to_intimidate
            and TeamAILogicIdle.find_civilian_to_intimidate(
            unit,
            CONSTANTS.INTIMIDATE_ANGLE,
            IntimidationSystem.get_intimidate_range()
    )

    if alive(civ) and TeamAILogicIdle and TeamAILogicIdle.intimidate_civilians then
        local ok, intimidated = safe_call(
                TeamAILogicIdle.intimidate_civilians,
                data,
                unit,
                true,
                allow_actions
        )
        if ok and intimidated then
            my_data._intimidate_t = t
            return
        end
    end

    local dom = IntimidationSystem.find_enemy_to_intimidate(data)
    if alive(dom) then
        local ok, intimidated = safe_call(
                IntimidationSystem.intimidate_law_enforcement,
                data,
                dom,
                allow_actions
        )
        if ok and intimidated then
            my_data._intimidate_t = t
            return
        end
    end

    local nmy = CombatBehavior.find_enemy_to_mark(data.detected_attention_objects, unit)
    if alive(nmy) then
        data._last_mark_t = data._last_mark_t or 0
        if data._last_mark_t + CONSTANTS.MARK_COOLDOWN < t then
            safe_call(CombatBehavior.mark_enemy, data, unit, nmy, true, allow_actions)
            data._last_mark_t = t
        end
    end
end

BB.IntimidationSystem = IntimidationSystem
BB.is_valid_intimidation_target = IntimidationSystem.is_valid_target
