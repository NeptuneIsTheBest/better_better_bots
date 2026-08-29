local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local UnitOps = BB.UnitOps
local CoopSystem = BB.CoopSystem
local StatusIcons = BB.StatusIcons

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

DebugOverlay._rendered = DebugOverlay._rendered or {}
DebugOverlay._next_update_t = DebugOverlay._next_update_t or 0

local function clear_table(value)
    if type(value) ~= "table" then
        return {}
    end

    for key in pairs(value) do
        value[key] = nil
    end

    return value
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
    for _ in pairs(type(value) == "table" and value or {}) do
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
    if not action or type(action.type) ~= "function" then
        return "-"
    end

    local action_type = action:type()
    if action_type == "walk" and type(action.haste) == "function" then
        local haste = action:haste()
        if haste then
            action_type = string.format("walk(%s)", tostring(haste))
        end
    end

    return tostring(action_type or "-")
end

local function actions_descriptor(movement)
    if not (movement and movement.get_action) then
        return "-"
    end

    local actions = {}
    for body_part = 1, 3 do
        actions[body_part] = string.format(
                "%d:%s",
                body_part,
                action_descriptor(movement:get_action(body_part))
        )
    end

    return table.concat(actions, ",")
end

local function attention_kind_descriptor(movement)
    local attention = movement:attention()
    if not attention then
        return "-"
    elseif attention.unit then
        return "unit"
    elseif attention.pos then
        return "pos"
    end

    return "-"
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

local function fire_state_data(movement, logic_data)
    local internal_data = logic_data and logic_data.internal_data
    local decision = internal_data and internal_data._bb_debug_fire_decision
    local common_data = movement._action_common_data

    return {
        aim = format_boolean(decision and decision.aim),
        allow_fire = format_boolean(movement._allow_fire),
        attention = attention_kind_descriptor(movement),
        firing = format_boolean(internal_data and internal_data.firing),
        shoot = format_boolean(decision and decision.shoot),
        shooting = format_boolean(internal_data and internal_data.shooting),
        suppressed = format_boolean(common_data.is_suppressed),
        weapon_range = weapon_range_descriptor(internal_data),
    }
end

local function cover_tactics_data(logic_data)
    local internal_data = logic_data and logic_data.internal_data
    local state = internal_data and internal_data._bb_cover_tactics
    local in_cover = internal_data and internal_data.in_cover
    local cover_data = in_cover
    local cover = "open"

    if in_cover == true then
        cover_data = internal_data.best_cover
    end

    if cover_data then
        cover = cover_data[4] and "high" or "low"
    end

    return {
        attitude = internal_data and tostring(internal_data.attitude or "-") or "-",
        cover = cover,
        phase = state and tostring(state.phase) or "-",
        tries = state and tostring(state.peek_attempts) or "-",
        wants = format_boolean(internal_data and internal_data.want_to_take_cover),
    }
end

local function path_descriptor(logic_data, objective, t)
    if not logic_data then
        return "-"
    end

    local states = {}
    local internal_data = logic_data.internal_data
    if internal_data and internal_data.advancing then
        table.insert(states, "adv")
    end

    local search_count = count_entries(logic_data.active_searches)
    if search_count > 0 then
        table.insert(states, "search" .. tostring(search_count))
    end

    if type(logic_data.path_fail_t) == "number"
            and t - logic_data.path_fail_t <= 6
    then
        table.insert(states, string.format("fail%.1f", math.max(t - logic_data.path_fail_t, 0)))
    end

    if #states == 0 and objective and objective.in_place then
        table.insert(states, "in_place")
    end

    return #states > 0 and table.concat(states, "+") or "idle"
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
    elseif attention.nearly_visible then
        return "near"
    end

    local verified_t = attention.verified_t
    local grace = CONSTANTS.COOP_RECENT_VERIFY_GRACE or 1
    if type(verified_t) == "number" and t - verified_t <= grace then
        return "recent"
    end

    return "stale"
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
            lock = "-",
            reaction = "-",
            visibility = "-",
        }
    end

    local attention_unit = attention.unit
    local attention_key = attention.u_key
            or alive(attention_unit) and attention_unit:key()
    local reaction = attention.reaction
            or attention.settings and attention.settings.reaction
    local lock_until = logic_data._target_lock_until
    local lock_remaining = type(lock_until) == "number"
            and math.max(lock_until - t, 0)
            or nil

    return {
        descriptor = target_descriptor(attention_unit, attention_key),
        distance = format_metric(attention_distance(unit, attention), "%.1f", "m"),
        lock = format_metric(lock_remaining, "%.1f", "s"),
        reaction = type(reaction) == "number" and tostring(reaction) or "-",
        visibility = visibility_descriptor(attention, t),
    }
end

local function find_observed_target_unit(logic_data, target_key)
    if not (logic_data and target_key ~= nil) then
        return nil
    end

    local attention = logic_data.detected_attention_objects
            and logic_data.detected_attention_objects[target_key]
    if not attention then
        attention = logic_data.detected_attention_objects
                and logic_data.detected_attention_objects[tonumber(target_key)]
    end

    return attention and attention.unit or nil
end

local function assignment_data(bot_key, logic_data, t)
    if not BB:get("coop", false) then
        return {
            age = "-",
            candidates = "-",
            descriptor = "-",
            load = "-",
            pressure = "-",
            score = "-",
        }
    end

    local data = CoopSystem.data or {}
    local assignment = data.assignment_snapshot or {}
    local assigned_key = assignment.by_bot and assignment.by_bot[bot_key]
    local observation = data.bot_observations and data.bot_observations[bot_key]
    local targets = observation and observation.targets or {}
    local assigned_observation = assigned_key and targets[tostring(assigned_key)]
    local assigned_unit = assigned_observation and assigned_observation.unit
            or find_observed_target_unit(logic_data, assigned_key)
    local pressure_entry = data.team_pressure_cache and data.team_pressure_cache[bot_key]
    local pressure = pressure_entry and pressure_entry.pressure
    local pressure_age = pressure_entry
            and type(pressure_entry.last_update) == "number"
            and math.max(t - pressure_entry.last_update, 0)
            or nil
    local snapshot_age = observation
            and type(observation.last_update) == "number"
            and math.max(t - observation.last_update, 0)
            or nil

    return {
        age = format_metric(snapshot_age, "%.1f", "s"),
        candidates = observation and tostring(count_entries(targets)) or "-",
        descriptor = target_descriptor(assigned_unit, assigned_key),
        load = assigned_key
                and assignment.target_load
                and tostring(assignment.target_load[tostring(assigned_key)] or "-")
                or "-",
        pressure = type(pressure) == "number" and (pressure_age
                and string.format("%.2f@%.1fs", pressure, pressure_age)
                or string.format("%.2f", pressure)) or "-",
        score = assigned_observation and format_number(assigned_observation.score, "%.0f") or "-",
    }
end

local function build_debug_text(unit, bot_key, character_name, t)
    local brain = unit:brain()
    local logic_data = brain and brain._logic_data
    local objective = logic_data and logic_data.objective
    local movement = unit:movement()
    local anim_data = unit:anim_data()
    local combat_status = UnitOps.combat_status(unit)
    local health = math.floor(UnitOps.health_ratio(unit) * 100 + 0.5)
    local role = StatusIcons:get_display_role(character_name) or "-"
    local current = current_target_data(unit, logic_data, t)
    local assignment = assignment_data(bot_key, logic_data, t)
    local fire = fire_state_data(movement, logic_data)
    local cover = cover_tactics_data(logic_data)

    return table.concat({
        string.format(
                "K:%s L:%s O:%s R:%s",
                bot_key,
                tostring(logic_data and logic_data.name or brain and brain._current_logic_name or "-"),
                objective_descriptor(objective),
                role
        ),
        string.format(
                "HP:%d%% ST:%s ACT:%s PATH:%s F:%s",
                health,
                combat_state_descriptor(combat_status),
                actions_descriptor(movement),
                path_descriptor(logic_data, objective, t),
                flags_descriptor(movement, anim_data)
        ),
        string.format(
                "CUR:%s V:%s D:%s RE:%s LK:%s",
                current.descriptor,
                current.visibility,
                current.distance,
                current.reaction,
                current.lock
        ),
        string.format(
                "FIRE AIM:%s SHOOT:%s ALLOW_FIRE:%s FIRING:%s SHOOTING:%s",
                fire.aim,
                fire.shoot,
                fire.allow_fire,
                fire.firing,
                fire.shooting
        ),
        string.format(
                "AIM_ATT:%s SUP:%s WR(C/O/F):%s",
                fire.attention,
                fire.suppressed,
                fire.weapon_range
        ),
        string.format(
                "CVR:%s/%s TRY:%s ATT:%s WANT:%s",
                cover.phase,
                cover.cover,
                cover.tries,
                cover.attitude,
                cover.wants
        ),
        string.format(
                "ASG:%s SC:%s C:%s LD:%s P:%s AGE:%s",
                assignment.descriptor,
                assignment.score,
                assignment.candidates,
                assignment.load,
                assignment.pressure,
                assignment.age
        ),
    }, "\n")
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

local function position_debug_panel(panel, name_text)
    local _, _, text_width = name_text:text_rect()
    local center_x = name_text:left() + text_width * 0.5

    panel:set_center_x(center_x)
    panel:set_bottom(name_text:top() - 2)
end

function DebugOverlay:is_enabled()
    return Network:is_server() and BB:get("debug", false) or false
end

function DebugOverlay:record_fire_decision(shoot, aim, my_data)
    local decision = my_data._bb_debug_fire_decision or {}
    my_data._bb_debug_fire_decision = decision

    decision.aim = aim
    decision.shoot = shoot
end

function DebugOverlay:apply_setting()
    self._setting_active = nil
    self._next_update_t = 0

    if not self:is_enabled() then
        self:_clear_rendered()
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

    text:set_text(build_debug_text(unit, bot_key, character_name, t))
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

    return true
end

function DebugOverlay:update(t, dt)
    local enabled = self:is_enabled()
    if not enabled then
        if self._setting_active or next(self._rendered) then
            self:_clear_rendered()
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
    self._setting_active = nil
    self._next_update_t = 0

    return true
end

return DebugOverlay
