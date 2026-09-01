local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils
local UnitOps = BB.UnitOps
local CoopSystem = BB.CoopSystem
local StatusIcons = BB.StatusIcons

local game_time = Utils.game_time

local DebugOverlay = BB.DebugOverlay or {}
BB.DebugOverlay = DebugOverlay

local PANEL_NAME = "bb_debug_overlay"
local BACKGROUND_NAME = "bb_debug_background"
local TEXT_NAME = "bb_debug_text"
local PANEL_WIDTH = 460
local PANEL_HEIGHT = 64
local PANEL_PADDING = 3
local FONT_SIZE = 12
local UPDATE_INTERVAL = 0.2
local PATH_FAILURE_WINDOW = 6
local SCREEN_PADDING = 2

local reaction_names

local SEARCH_TYPES = {
    {"cover_path_search_id", "cover"},
    {"advance_path_search_id", "advance"},
    {"coarse_path_search_id", "coarse"},
    {"charge_path_search_id", "charge"},
    {"expected_pos_path_search_id", "expected"},
    {"stare_path_search_id", "stare"},
}

DebugOverlay._rendered = DebugOverlay._rendered or {}
DebugOverlay._last_shot_t = DebugOverlay._last_shot_t or {}
DebugOverlay._next_update_t = DebugOverlay._next_update_t or 0

local function clear_table(value)
    for key in pairs(value) do
        value[key] = nil
    end
end

local function remove_named_child(parent, name)
    if not alive(parent) then
        return false
    end

    local child = parent:child(name)
    if not child then
        return false
    end

    parent:remove(child)
    return true
end

local function count_entries(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end

    return count
end

local function format_boolean(value)
    if value == true then
        return "T"
    elseif value == false then
        return "F"
    end

    return "-"
end

local function format_number(value, format)
    if type(value) ~= "number" then
        return "-"
    end

    return string.format(format, value)
end

local function format_metric(value, format, suffix)
    local formatted = format_number(value, format)
    return formatted == "-" and formatted or formatted .. suffix
end

local function format_age(timestamp, t, missing)
    if type(timestamp) ~= "number" then
        return missing or "-"
    end

    return string.format("%.1fs", math.max(t - timestamp, 0))
end

local function find_name_label(unit)
    if not alive(unit) then
        return nil
    end

    local hud = managers.hud
    if not hud then
        return nil
    end

    local unit_data = unit:unit_data()
    local label_id = unit_data and unit_data.name_label_id
    local label = label_id and hud:_get_name_label(label_id)
    if label then
        return label
    end

    local labels = hud._hud and hud._hud.name_labels
    for _, candidate in ipairs(labels or {}) do
        local movement = candidate and candidate.movement
        if movement and movement._unit == unit then
            return candidate
        end
    end

    return nil
end

local function target_descriptor(unit, fallback_key)
    local key = fallback_key
    local name

    if alive(unit) then
        key = unit:key()

        local base = unit:base()
        name = base and base._tweak_table

        if not name and managers.criminals then
            name = managers.criminals:character_name_by_unit(unit)
        end
    end

    if key == nil then
        return "-"
    end

    return string.format("%s#%s", tostring(name or "unit"), tostring(key))
end

local function objective_descriptor(objective)
    if type(objective) ~= "table" then
        return "-"
    end

    local descriptor
    if objective._bb_rescue_guard then
        descriptor = "rescue_guard"
    elseif objective._bb_proactive_attack then
        descriptor = "proactive_attack"
    elseif objective._bb_proactive_recall_id then
        descriptor = "proactive_recall"
    elseif objective._bb_hold_return then
        descriptor = "hold_return"
    elseif objective._bb_hold_stationary then
        descriptor = "hold_stationary"
    else
        descriptor = tostring(objective.type or "unknown")
    end

    if objective._bb_rescue_cloaker_key then
        descriptor = descriptor .. "/evade"
    end

    if alive(objective.follow_unit) then
        descriptor = string.format(
                "%s(%s)",
                descriptor,
                target_descriptor(objective.follow_unit)
        )
    end

    if objective.in_place then
        descriptor = descriptor .. "/in_place"
    end

    if objective.forced then
        descriptor = descriptor .. "/forced"
    end

    return descriptor
end

local function combat_state_descriptor(combat_status)
    if combat_status.is_dead then
        return "dead"
    elseif combat_status.is_downed then
        return "down"
    elseif combat_status.is_arrested then
        return "arrest"
    elseif combat_status.is_tased then
        return "tased"
    end

    return combat_status.can_fight and "ok" or "blocked"
end

local function action_descriptor(action)
    if not action then
        return "-"
    end

    local action_type = action:type()
    if action_type == "walk" then
        local details = {}
        local haste = action:haste()
        if haste then
            table.insert(details, tostring(haste))
        end
        if action:stopping() then
            table.insert(details, "stop")
        end
        if #details > 0 then
            action_type = string.format("walk(%s)", table.concat(details, ","))
        end
    end

    return tostring(action_type or "-")
end

local function actions_descriptor(movement)
    local actions = {}
    local labels = {"F", "L", "U", "P"}
    for body_part = 1, 4 do
        table.insert(actions, string.format(
                "%s:%s",
                labels[body_part],
                action_descriptor(movement:get_action(body_part))
        ))
    end

    return table.concat(actions, " ")
end

local function attention_key(attention)
    if not attention then
        return nil
    end

    local key = attention.u_key
    local unit = attention.unit
    if key == nil and alive(unit) then
        key = unit:key()
    end

    return key ~= nil and tostring(key) or nil
end

local function reaction_descriptor(reaction)
    if not reaction_names then
        reaction_names = {
            [AIAttentionObject.REACT_IDLE] = "idle",
            [AIAttentionObject.REACT_CURIOUS] = "curious",
            [AIAttentionObject.REACT_CHECK] = "check",
            [AIAttentionObject.REACT_SUSPICIOUS] = "suspicious",
            [AIAttentionObject.REACT_SURPRISED] = "surprised",
            [AIAttentionObject.REACT_SCARED] = "scared",
            [AIAttentionObject.REACT_AIM] = "aim",
            [AIAttentionObject.REACT_ARREST] = "arrest",
            [AIAttentionObject.REACT_DISARM] = "disarm",
            [AIAttentionObject.REACT_SHOOT] = "shoot",
            [AIAttentionObject.REACT_MELEE] = "melee",
            [AIAttentionObject.REACT_COMBAT] = "combat",
            [AIAttentionObject.REACT_SPECIAL_ATTACK] = "special",
        }
    end

    return reaction_names[reaction] or string.format("unknown(%d)", reaction)
end

local function runtime_attention_descriptor(movement, current_key)
    local attention = movement:attention()
    if not attention then
        return "none"
    elseif attention.unit then
        local runtime_key = attention_key(attention)
        if current_key == nil or runtime_key == nil then
            return "unit"
        end

        return runtime_key == current_key
                and "unit=same"
                or "unit=other"
    elseif attention.pos then
        return "pos"
    end

    return "other"
end

local function weapon_range_descriptor(internal_data)
    local weapon_range = internal_data and internal_data.weapon_range
    if type(weapon_range) == "number" then
        return string.format("%.1fm", weapon_range / 100)
    elseif type(weapon_range) ~= "table" then
        return "-"
    end

    local has_range = false
    local values = {}
    for _, key in ipairs({"close", "optimal", "far"}) do
        local value = weapon_range[key]
        if type(value) == "number" then
            has_range = true
            table.insert(values, string.format("%.1f", value / 100))
        else
            table.insert(values, "-")
        end
    end

    return has_range and table.concat(values, "/") .. "m" or "-"
end

local function weapon_ammo_descriptor(unit)
    local weapon_unit = unit:inventory():equipped_unit()
    if not alive(weapon_unit) then
        return "-"
    end

    local clip_max, clip_ammo = weapon_unit:base():ammo_info()
    return string.format("%.0f/%.0f", clip_ammo, clip_max)
end

local function fire_state_data(bot_key, movement, logic_data, current_key, t)
    local internal_data = logic_data and logic_data.internal_data
    local decision = internal_data and internal_data._bb_debug_fire_decision
    local decision_descriptor = "-"
    local decision_target = "-"

    if decision then
        decision_descriptor = string.format(
                "%s/%s@%s",
                format_boolean(decision.aim),
                format_boolean(decision.shoot),
                format_age(decision.t, t)
        )

        if decision.target_key == nil then
            decision_target = "none"
        elseif current_key ~= nil and decision.target_key == current_key then
            decision_target = "same"
        else
            decision_target = "other"
        end
    end

    return {
        allow_fire = format_boolean(movement._allow_fire),
        attention = runtime_attention_descriptor(movement, current_key),
        decision = decision_descriptor,
        decision_target = decision_target,
        shot_age = format_age(DebugOverlay._last_shot_t[bot_key], t, "never"),
    }
end

local function cover_location_descriptor(internal_data)
    if not internal_data then
        return "-"
    end

    local in_cover = internal_data.in_cover
    local cover_data = in_cover
    if in_cover == true then
        cover_data = internal_data.best_cover
        if type(cover_data) ~= "table" then
            return "cover"
        end
    end

    if type(cover_data) == "table" then
        return cover_data[4] and "high" or "low"
    end

    return "open"
end

local function cover_phase_descriptor(internal_data)
    local state = internal_data and internal_data._bb_cover_tactics
    if not state then
        return "-"
    end

    return tostring(state.phase or "-")
end

local function cover_timer_descriptor(internal_data, t)
    local state = internal_data and internal_data._bb_cover_tactics
    if not state then
        return "-"
    end

    if type(state.path_deadline_t) == "number" then
        return string.format(
                "path@%.1fs",
                math.max(state.path_deadline_t - t, 0)
        )
    elseif type(state.blocked_since_t) == "number" then
        local deadline = state.blocked_since_t
                + CONSTANTS.COVER_TACTICS_BLOCKED_TIMEOUT
        return string.format("act@%.1fs", math.max(deadline - t, 0))
    elseif type(state.next_reposition_t) == "number"
            and state.next_reposition_t > t
    then
        return string.format(
                "retry@%.1fs",
                state.next_reposition_t - t
        )
    elseif type(state.next_lane_check_t) == "number" then
        return string.format(
                "check@%.1fs",
                math.max(state.next_lane_check_t - t, 0)
        )
    end

    return "-"
end

local function cover_tactics_data(logic_data, t)
    local internal_data = logic_data and logic_data.internal_data
    local state = internal_data and internal_data._bb_cover_tactics
    local enabled = state ~= nil
    local wants = "-"
    if enabled or internal_data and internal_data.want_to_take_cover ~= nil then
        wants = format_boolean(internal_data.want_to_take_cover == true)
    end

    return {
        attitude = internal_data and tostring(internal_data.attitude or "-") or "-",
        blocked = state and format_age(state.blocked_since_t, t) or "-",
        cover = cover_location_descriptor(internal_data),
        force = state and format_boolean(state.force_cover == true) or "-",
        lane = state and tostring(state.lane or "-") or "-",
        phase = cover_phase_descriptor(internal_data),
        step = enabled and tostring(internal_data.cover_test_step or "-") or "-",
        timer = cover_timer_descriptor(internal_data, t),
        wants = wants,
    }
end

local function classify_search(search_id, internal_data)
    for _, entry in ipairs(SEARCH_TYPES) do
        if internal_data and internal_data[entry[1]] == search_id then
            return entry[2]
        end
    end

    local id = string.lower(tostring(search_id))
    if string.find(id, "expected", 1, true) then
        return "expected"
    elseif string.find(id, "charge", 1, true) then
        return "charge"
    elseif string.find(id, "cover", 1, true) then
        return "cover"
    elseif string.find(id, "coarse", 1, true) then
        return "coarse"
    elseif string.find(id, "detailed", 1, true)
            or string.find(id, "advance", 1, true)
    then
        return "advance"
    elseif string.find(id, "hunt", 1, true) then
        return "hunt"
    elseif string.find(id, "stare", 1, true) then
        return "stare"
    end

    return "other"
end

local function active_searches_descriptor(logic_data)
    local active_searches = logic_data and logic_data.active_searches
    if not logic_data or not next(active_searches) then
        return "-"
    end

    local internal_data = logic_data.internal_data
    local seen = {}
    local search_types = {}
    for search_id in pairs(active_searches) do
        local search_type = classify_search(search_id, internal_data)
        if not seen[search_type] then
            seen[search_type] = true
            table.insert(search_types, search_type)
        end
    end

    table.sort(search_types)
    return table.concat(search_types, ",")
end

local function movement_descriptor(logic_data, objective)
    local internal_data = logic_data and logic_data.internal_data
    if not internal_data then
        return "-"
    elseif internal_data.moving_to_cover then
        return "to_cover"
    elseif internal_data.walking_to_cover_shoot_pos then
        return "to_shoot_pos"
    elseif internal_data.advancing then
        return "advancing"
    elseif internal_data.starting_advance_action then
        return "starting"
    elseif objective and objective.in_place then
        return "in_place"
    end

    return "idle"
end

local function path_failure_descriptor(logic_data, t)
    local internal_data = logic_data and logic_data.internal_data
    local failures = {
        {"path", logic_data and logic_data.path_fail_t},
        {"cover", internal_data and internal_data.cover_path_failed_t},
        {"charge", internal_data and internal_data.charge_path_failed_t},
    }
    local latest_name
    local latest_t

    for _, failure in ipairs(failures) do
        local failure_t = failure[2]
        if type(failure_t) == "number"
                and t - failure_t <= PATH_FAILURE_WINDOW
                and (not latest_t or failure_t > latest_t)
        then
            latest_name = failure[1]
            latest_t = failure_t
        end
    end

    return latest_name and string.format(
            "%s@%s",
            latest_name,
            format_age(latest_t, t)
    ) or "-"
end

local function flags_descriptor(movement, anim_data)
    local flags = {}

    if movement and movement.should_stay and movement:should_stay() then
        table.insert(flags, "stay")
    end
    if movement and movement.carrying_bag and movement:carrying_bag() then
        table.insert(flags, "bag")
    end
    if anim_data and anim_data.reload then
        table.insert(flags, "reload")
    end

    return #flags > 0 and table.concat(flags, ",") or "-"
end

local function visibility_descriptor(attention, t)
    if not attention then
        return "-"
    elseif attention.verified then
        return "verified"
    end

    local verified_t = attention.verified_t
    local age = format_age(verified_t, t)
    if attention.nearly_visible then
        return verified_t and "near@" .. age or "near"
    elseif type(verified_t) ~= "number" then
        return "never"
    end

    local grace = CONSTANTS.COOP_RECENT_VERIFY_GRACE
    return t - verified_t <= grace and "recent@" .. age or "stale@" .. age
end

local function attention_distance(unit, attention)
    if not attention then
        return nil
    end

    local distance = attention.verified_dis or attention.dis
    if type(distance) == "number" then
        return distance / 100
    end

    local my_pos = UnitOps.head_pos(unit)
    local target_pos = attention.m_head_pos
            or attention.verified_pos
            or attention.last_verified_pos
    if my_pos and target_pos then
        return mvector3.distance(my_pos, target_pos) / 100
    end

    return nil
end

local function current_target_data(unit, logic_data, t)
    local attention = logic_data and logic_data.attention_obj
    if not attention then
        return {
            descriptor = "-",
            distance = "-",
            key = nil,
            lock = "-",
            reaction = "-",
            visibility = "-",
        }
    end

    local attention_unit = attention.unit
    local current_key = attention_key(attention)
    local reaction = attention.reaction
    local lock_until = logic_data._target_lock_until
    local lock_remaining = type(lock_until) == "number" and lock_until > t
            and lock_until - t
            or nil

    return {
        descriptor = target_descriptor(attention_unit, current_key),
        distance = format_metric(attention_distance(unit, attention), "%.1f", "m"),
        key = current_key,
        lock = format_metric(lock_remaining, "%.1f", "s"),
        reaction = reaction_descriptor(reaction),
        visibility = visibility_descriptor(attention, t),
    }
end

local function find_observed_target_unit(logic_data, target_key)
    if not (logic_data and target_key ~= nil) then
        return nil
    end

    local attention = logic_data.detected_attention_objects[tonumber(target_key)]

    return attention and attention.unit or nil
end

local function assignment_tag(observation)
    if not observation then
        return "-"
    end

    local tags = {}
    if observation.urgency >= 3 then
        table.insert(tags, "urgent")
    elseif observation.urgency >= 2 then
        table.insert(tags, "high")
    end
    if observation.durable then
        table.insert(tags, "durable")
    end

    return #tags > 0 and table.concat(tags, "+") or "normal"
end

local function assignment_data(bot_key, logic_data, current_key, t)
    if not BB:get("coop", false) then
        return { enabled = false }
    end

    local data = CoopSystem.data
    local assignment = data.assignment_snapshot
    local assigned_key = assignment.by_bot[bot_key]
    local observation = data.bot_observations[bot_key]
    local assigned_observation = observation
            and assigned_key
            and observation.targets[assigned_key]
    local assigned_unit = assigned_observation and assigned_observation.unit
            or find_observed_target_unit(logic_data, assigned_key)
    local pressure_entry = data.team_pressure_cache[bot_key]
    local mode = "waiting"
    if observation then
        if observation.restricted then
            mode = observation.fixed_target and "fixed" or "restricted"
        else
            mode = "free"
        end
    end

    local pressure_descriptor = "-"
    if pressure_entry then
        pressure_descriptor = string.format(
                "%.2f@%s",
                pressure_entry.pressure,
                format_age(pressure_entry.last_update, t)
        )
    end

    return {
        age = format_age(observation and observation.last_update, t),
        candidates = observation
                and tostring(count_entries(observation.targets))
                or "-",
        descriptor = target_descriptor(assigned_unit, assigned_key),
        enabled = true,
        load = assigned_key
                and string.format("%d", assignment.target_load[assigned_key])
                or "-",
        match = assigned_key and format_boolean(
                current_key ~= nil and assigned_key == current_key
        ) or "-",
        mode = mode,
        pressure = pressure_descriptor,
        score = assigned_observation
                and string.format("%.0f", assigned_observation.score)
                or "-",
        tag = assignment_tag(assigned_observation),
    }
end

local function build_section_ranges(lines)
    local ranges = {}
    local offset = 0
    for _, line in ipairs(lines) do
        local section_end = string.find(line, "]", 1, true)
        table.insert(ranges, {offset, offset + section_end})

        local line_length = utf8.len(line)
        offset = offset + line_length + 1
    end

    return ranges
end

local function build_debug_text(unit, bot_key, character_name, t)
    local brain = unit:brain()
    local logic_data = brain and brain._logic_data
    local internal_data = logic_data and logic_data.internal_data
    local objective = logic_data and logic_data.objective
    local movement = unit:movement()
    local anim_data = unit:anim_data()
    local combat_status = UnitOps.combat_status(unit)
    local health = math.floor(UnitOps.health_ratio(unit) * 100 + 0.5)
    local role = StatusIcons:get_display_role(character_name) or "-"
    local current = current_target_data(unit, logic_data, t)
    local assignment = assignment_data(bot_key, logic_data, current.key, t)
    local fire = fire_state_data(bot_key, movement, logic_data, current.key, t)
    local cover = cover_tactics_data(logic_data, t)
    local common_data = movement._action_common_data
    local suppressed = logic_data and logic_data.is_suppressed == true
            or common_data.is_suppressed == true
            or false
    local lines = {
        string.format(
                "[AI] KEY:%s LOGIC:%s OBJ:%s ROLE:%s",
                bot_key,
                tostring(logic_data and logic_data.name
                        or brain and brain._current_logic_name
                        or "-"),
                objective_descriptor(objective),
                role
        ),
        string.format(
                "[STATE] HP:%d%% STATUS:%s ACT:%s FLAGS:%s",
                health,
                combat_state_descriptor(combat_status),
                actions_descriptor(movement),
                flags_descriptor(movement, anim_data)
        ),
        string.format(
                "[MOVE] STATE:%s SEARCH:%s FAIL:%s",
                movement_descriptor(logic_data, objective),
                active_searches_descriptor(logic_data),
                path_failure_descriptor(logic_data, t)
        ),
        string.format(
                "[TARGET] CUR:%s VIS:%s DIST:%s REACT:%s LOCK:%s",
                current.descriptor,
                current.visibility,
                current.distance,
                current.reaction,
                current.lock
        ),
        string.format(
                "[FIRE] DEC(A/S):%s DEC_TGT:%s ATT:%s ALLOW:%s SHOT:%s",
                fire.decision,
                fire.decision_target,
                fire.attention,
                fire.allow_fire,
                fire.shot_age
        ),
        string.format(
                "[WEAPON] AMMO:%s RANGE(C/O/F):%s RELOAD:%s SUP:%s",
                weapon_ammo_descriptor(unit),
                weapon_range_descriptor(internal_data),
                format_boolean(anim_data and anim_data.reload == true),
                format_boolean(suppressed)
        ),
        string.format(
                "[COVER] PHASE:%s POS:%s LANE:%s BLOCK:%s WANT:%s FORCE:%s ATT:%s STEP:%s TIMER:%s",
                cover.phase,
                cover.cover,
                cover.lane,
                cover.blocked,
                cover.wants,
                cover.force,
                cover.attitude,
                cover.step,
                cover.timer
        ),
    }

    if assignment.enabled then
        table.insert(lines, string.format(
                "[COOP] MODE:%s ASG:%s MATCH:%s SCORE:%s CAND:%s LOAD:%s TAG:%s AGE:%s PRESS:%s",
                assignment.mode,
                assignment.descriptor,
                assignment.match,
                assignment.score,
                assignment.candidates,
                assignment.load,
                assignment.tag,
                assignment.age,
                assignment.pressure
        ))
    else
        table.insert(lines, "[COOP] off")
    end

    return table.concat(lines, "\n"), build_section_ranges(lines)
end

local function create_debug_panel(parent)
    local panel = parent:panel({
        h = PANEL_HEIGHT,
        layer = 20,
        name = PANEL_NAME,
        w = PANEL_WIDTH,
    })

    panel:rect({
        color = Color.black:with_alpha(0.65),
        h = PANEL_HEIGHT,
        layer = 0,
        name = BACKGROUND_NAME,
        rotation = 360,
        w = PANEL_WIDTH,
    })

    local text = panel:text({
        align = "left",
        color = Color.white,
        font = tweak_data.hud.small_font,
        font_size = FONT_SIZE,
        h = PANEL_HEIGHT - PANEL_PADDING * 2,
        layer = 1,
        name = TEXT_NAME,
        rotation = 360,
        vertical = "top",
        w = PANEL_WIDTH - PANEL_PADDING * 2,
        word_wrap = false,
        wrap = false,
        x = PANEL_PADDING,
        y = PANEL_PADDING,
    })

    return panel, text
end

local function resize_debug_panel(panel, text)
    local _, _, text_width, text_height = text:text_rect()
    text_width = math.ceil(text_width)
    text_height = math.ceil(text_height)

    local panel_width = text_width + PANEL_PADDING * 2
    local panel_height = text_height + PANEL_PADDING * 2
    local background = panel:child(BACKGROUND_NAME)

    text:set_size(text_width, text_height)
    panel:set_size(panel_width, panel_height)

    if background then
        background:set_size(panel_width, panel_height)
    end
end

local function apply_section_colors(text, ranges)
    text:set_color(Color.white)

    local value = text:text()
    local value_length = utf8.len(value)
    text:clear_range_color(0, value_length)

    for _, range in ipairs(ranges) do
        text:set_range_color(range[1], range[2], tweak_data.screen_colors.button_stage_2)
    end
end

local function position_debug_panel(panel, name_text)
    local _, _, text_width = name_text:text_rect()
    local center_x = name_text:left() + text_width * 0.5

    panel:set_center_x(center_x)
    panel:set_bottom(name_text:top() - 2)

    local root = panel:parent():parent()

    local min_x = root:world_left() + SCREEN_PADDING
    local max_x = root:world_right() - SCREEN_PADDING
    if panel:world_left() < min_x then
        panel:set_world_left(min_x)
    end
    if panel:world_right() > max_x then
        panel:set_world_right(max_x)
    end

    local min_y = root:world_top() + SCREEN_PADDING
    local max_y = root:world_bottom() - SCREEN_PADDING
    if panel:world_top() < min_y then
        panel:set_world_top(name_text:world_bottom() + 2)
    end
    if panel:world_bottom() > max_y then
        panel:set_world_bottom(max_y)
    end
end

function DebugOverlay:is_enabled()
    return Network:is_server() and BB:get("debug", false) or false
end

function DebugOverlay:record_fire_decision(shoot, aim, data, my_data)
    local decision = my_data._bb_debug_fire_decision or {}
    my_data._bb_debug_fire_decision = decision

    decision.aim = aim
    decision.shoot = shoot
    decision.t = game_time()
    decision.target_key = attention_key(data.attention_obj)
end

function DebugOverlay:record_weapon_shot(user_unit)
    self._last_shot_t[tostring(user_unit:key())] = game_time()
end

function DebugOverlay:_clear_diagnostics()
    clear_table(self._last_shot_t)

    local group_state = managers.groupai and managers.groupai:state()
    local ai_criminals = group_state and group_state:all_AI_criminals() or {}
    for _, unit_data in pairs(ai_criminals) do
        local unit = unit_data.unit
        if alive(unit) then
            local logic_data = unit:brain()._logic_data
            local internal_data = logic_data and logic_data.internal_data
            if internal_data then
                internal_data._bb_debug_fire_decision = nil
            end
        end
    end
end

function DebugOverlay:apply_setting()
    self._setting_active = nil
    self._next_update_t = 0

    if not self:is_enabled() then
        self:_clear_rendered()
        self:_clear_diagnostics()
    end

    return true
end

function DebugOverlay:_remove_rendered(bot_key)
    local cache = self._rendered[bot_key]
    if cache and alive(cache.parent) then
        remove_named_child(cache.parent, PANEL_NAME)
    end

    self._rendered[bot_key] = nil
end

function DebugOverlay:_clear_rendered()
    for bot_key in pairs(self._rendered) do
        self:_remove_rendered(bot_key)
    end

    clear_table(self._rendered)
end

function DebugOverlay:_render_unit(unit, bot_key, character_name, t)
    local label = find_name_label(unit)
    local parent = label and label.panel
    local name_text = label and (label.text or alive(parent) and parent:child("text"))
    if not (alive(parent) and alive(name_text)) then
        self:_remove_rendered(bot_key)
        return false
    end

    local cache = self._rendered[bot_key]
    if cache and cache.parent ~= parent then
        self:_remove_rendered(bot_key)
        cache = nil
    end

    local panel = parent:child(PANEL_NAME)
    local text = panel and panel:child(TEXT_NAME)
    if panel and not text then
        parent:remove(panel)
        panel = nil
    end

    if not panel then
        panel, text = create_debug_panel(parent)
    end

    local debug_text, section_ranges = build_debug_text(
            unit,
            bot_key,
            character_name,
            t
    )
    text:set_text(debug_text)
    apply_section_colors(text, section_ranges)
    resize_debug_panel(panel, text)
    position_debug_panel(panel, name_text)
    panel:set_visible(true)

    self._rendered[bot_key] = {
        parent = parent,
        panel = panel,
    }

    return true
end

function DebugOverlay:_reconcile(t)
    local group_ai = managers.groupai
    local group_state = group_ai and group_ai:state()
    local criminals = managers.criminals
    if not (group_state and criminals) then
        self:_clear_rendered()
        self:_clear_diagnostics()
        return false
    end

    local seen = {}
    for raw_key, unit_data in pairs(group_state:all_AI_criminals()) do
        local unit = unit_data and unit_data.unit
        if alive(unit) and unit_data.status ~= "removed" then
            local bot_key = tostring(raw_key or unit:key())
            local character_name = criminals:character_name_by_unit(unit)
            seen[bot_key] = true
            self:_render_unit(unit, bot_key, character_name, t)
        end
    end

    for bot_key in pairs(self._rendered) do
        if not seen[bot_key] then
            self:_remove_rendered(bot_key)
        end
    end
    for bot_key in pairs(self._last_shot_t) do
        if not seen[bot_key] then
            self._last_shot_t[bot_key] = nil
        end
    end

    return true
end

function DebugOverlay:update(t, dt)
    local enabled = self:is_enabled()
    if not enabled then
        if self._setting_active
                or next(self._rendered)
                or next(self._last_shot_t)
        then
            self:_clear_rendered()
            self:_clear_diagnostics()
        end

        self._setting_active = false
        self._next_update_t = 0
        return
    end

    if not self._setting_active then
        self._setting_active = true
        self._next_update_t = 0
    end

    if t < self._next_update_t then
        return
    end

    self._next_update_t = t + UPDATE_INTERVAL
    self:_reconcile(t)
end

function DebugOverlay:reset_level_state()
    self:_clear_rendered()
    self:_clear_diagnostics()
    self._setting_active = nil
    self._next_update_t = 0

    return true
end

return DebugOverlay
