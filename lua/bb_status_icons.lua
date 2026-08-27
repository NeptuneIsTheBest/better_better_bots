local BB = _G.BB

local UnitOps = BB.UnitOps

local StatusIcons = BB.StatusIcons or {}
BB.StatusIcons = StatusIcons

StatusIcons.ROLES = {
    hold = "hold",
    rescue = "rescue",
    rescue_guard = "rescue_guard",
    proactive_attack = "proactive_attack",
    proactive_guard = "proactive_guard",
}

local ROLE_NONE = "none"
local ROLE_DEFS = {
    hold = {
        color = "regular_color",
        icon = "pd2_defend",
    },
    rescue = {
        color = "friend_color",
        icon = "wp_revive",
    },
    rescue_guard = {
        color = "friend_color",
        icon = "pd2_defend",
    },
    proactive_attack = {
        color = "risk",
        icon = "wp_target",
    },
    proactive_guard = {
        color = "risk",
        icon = "pd2_defend",
    },
}

local MESSAGE_REQUEST = "BB_AI_STATUS_REQ_V1"
local MESSAGE_RESET = "BB_AI_STATUS_RESET_V1"
local MESSAGE_SET = "BB_AI_STATUS_SET_V1"
local NETWORK_HOOK_PREFIX = "BB_AIStatusIcons_"

local STATUS_PANEL_NAME = "bb_status_role"
local STATUS_BACKGROUND_NAME = "bb_status_background"
local STATUS_GLYPH_NAME = "bb_status_glyph"
local STATUS_SIZE = 18
local GLYPH_SIZE = 14
local BACKGROUND_ALPHA = 0.85
local STATE_UPDATE_INTERVAL = 0.2
local HUD_RECONCILE_INTERVAL = 0.25
local SNAPSHOT_RETRY_INTERVAL = 2
local SNAPSHOT_MAX_ATTEMPTS = 3

StatusIcons._roles = StatusIcons._roles or {}
StatusIcons._local_holds = StatusIcons._local_holds or {}
StatusIcons._pending_panel_holds = StatusIcons._pending_panel_holds or {}
StatusIcons._rendered = StatusIcons._rendered or {}
StatusIcons._next_state_t = StatusIcons._next_state_t or 0
StatusIcons._next_hud_t = StatusIcons._next_hud_t or 0
StatusIcons._next_snapshot_request_t = StatusIcons._next_snapshot_request_t or 0
StatusIcons._snapshot_request_attempts = StatusIcons._snapshot_request_attempts or 0
StatusIcons._dirty = StatusIcons._dirty ~= false

local function clear_table(value)
    for key in pairs(value) do
        value[key] = nil
    end

    return value
end

local function network_is_server()
    return Network:is_server()
end

local function network_is_client()
    return Network:is_client()
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

local function remove_native_stopped(parent)
    return remove_named_child(parent, "stopped")
end

local function configure_vr_bitmap(bitmap)
    if _G.IS_VR then
        bitmap:configure({
            depth_mode = "disabled",
            render_template = Idstring("OverlayVertexColorTextured"),
        })
    end
end

local function get_icon_data(icon_id)
    return tweak_data.hud_icons:get_icon_data(icon_id)
end

local function create_status_panel(parent, role)
    local role_def = ROLE_DEFS[role]
    if not alive(parent) then
        return nil
    end

    local background_texture, background_rect = get_icon_data("icon_circlefill16")
    local glyph_texture, glyph_rect = get_icon_data(role_def.icon)
    local role_color = tweak_data.screen_colors[role_def.color]
    local status_panel = parent:panel({
        h = STATUS_SIZE,
        layer = 10,
        name = STATUS_PANEL_NAME,
        w = STATUS_SIZE,
    })
    local background = status_panel:bitmap({
        color = role_color:with_alpha(BACKGROUND_ALPHA),
        h = STATUS_SIZE,
        layer = 0,
        name = STATUS_BACKGROUND_NAME,
        texture = background_texture,
        texture_rect = background_rect,
        w = STATUS_SIZE,
    })
    local glyph = status_panel:bitmap({
        color = Color.white,
        h = GLYPH_SIZE,
        layer = 1,
        name = STATUS_GLYPH_NAME,
        texture = glyph_texture,
        texture_rect = glyph_rect,
        w = GLYPH_SIZE,
    })

    glyph:set_center(status_panel:w() * 0.5, status_panel:h() * 0.5)
    configure_vr_bitmap(background)
    configure_vr_bitmap(glyph)

    return status_panel
end

local function cleanup_cached_surface(cache, surface)
    local parent_key = surface .. "_parent"
    local role_key = surface .. "_role"
    local old_parent = cache[parent_key]

    if alive(old_parent) then
        remove_named_child(old_parent, STATUS_PANEL_NAME)
    end

    cache[parent_key] = nil
    cache[role_key] = nil
end

local function apply_surface(cache, surface, parent, anchor, role, position_func)
    local parent_key = surface .. "_parent"
    local role_key = surface .. "_role"
    local old_parent = cache[parent_key]

    if old_parent and old_parent ~= parent then
        cleanup_cached_surface(cache, surface)
    end

    if alive(parent) then
        remove_native_stopped(parent)
    end

    if not (role and alive(parent) and alive(anchor)) then
        if alive(parent) then
            remove_named_child(parent, STATUS_PANEL_NAME)
        end

        cache[parent_key] = nil
        cache[role_key] = nil
        return false
    end

    local status_panel = parent:child(STATUS_PANEL_NAME)
    if cache[role_key] ~= role or not status_panel then
        remove_named_child(parent, STATUS_PANEL_NAME)
        status_panel = create_status_panel(parent, role)
    end

    if not status_panel then
        cache[parent_key] = nil
        cache[role_key] = nil
        return false
    end

    position_func(status_panel, anchor)
    status_panel:set_visible(true)
    cache[parent_key] = parent
    cache[role_key] = role

    return true
end

local function position_teammate_status(status_panel, name_text)
    status_panel:set_left(name_text:right() + 4)
    status_panel:set_center_y(name_text:center_y())
end

local function position_name_label_status(status_panel, name_text)
    status_panel:set_right(name_text:left() - 2)
    status_panel:set_center_y(name_text:center_y())
end

local function find_name_label(hud, unit)
    if not alive(unit) then
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

function StatusIcons:_get_character_surfaces(character_name)
    local criminals = managers.criminals
    local hud = managers.hud

    local character_data = criminals:character_data_by_name(character_name)
    local unit = criminals:character_unit_by_name(character_name)
    if not (character_data and character_data.ai and alive(unit)) then
        return nil
    end

    local teammate = hud._teammate_panels
            and character_data.panel_id
            and hud._teammate_panels[character_data.panel_id]
    local teammate_parent = teammate and teammate._panel
    local teammate_anchor = alive(teammate_parent) and teammate_parent:child("name") or nil
    local label = find_name_label(hud, unit)
    local label_parent = label and label.panel
    local label_anchor = label and (label.text or alive(label_parent) and label_parent:child("text"))

    return {
        label_anchor = label_anchor,
        label_parent = label_parent,
        teammate_anchor = teammate_anchor,
        teammate_parent = teammate_parent,
    }
end

function StatusIcons:_display_role(character_name)
    local role = self._roles[character_name]
    if role and ROLE_DEFS[role] then
        return role
    end

    local authoritative_ready = network_is_server() and self._authoritative_ready
            or network_is_client() and self._snapshot_received
    if not authoritative_ready and self._local_holds[character_name] then
        return self.ROLES.hold
    end

    return nil
end

function StatusIcons:get_display_role(character_name)
    if not character_name then
        return nil
    end

    return self:_display_role(character_name)
end

function StatusIcons:_reconcile_character(character_name)
    local role = self:_display_role(character_name)
    local cache = self._rendered[character_name] or {}
    local surfaces = self:_get_character_surfaces(character_name)

    if not surfaces then
        cleanup_cached_surface(cache, "teammate")
        cleanup_cached_surface(cache, "label")
        self._rendered[character_name] = nil
        return false
    end

    apply_surface(
            cache,
            "teammate",
            surfaces.teammate_parent,
            surfaces.teammate_anchor,
            role,
            position_teammate_status
    )
    apply_surface(
            cache,
            "label",
            surfaces.label_parent,
            surfaces.label_anchor,
            role,
            position_name_label_status
    )

    self._rendered[character_name] = role and cache or nil
    return role ~= nil
end

function StatusIcons:_reconcile_hud()
    local character_names = {}

    for character_name in pairs(self._roles) do
        character_names[character_name] = true
    end
    for character_name in pairs(self._local_holds) do
        character_names[character_name] = true
    end
    for character_name in pairs(self._rendered) do
        character_names[character_name] = true
    end

    for character_name in pairs(character_names) do
        self:_reconcile_character(character_name)
    end

    self._dirty = false
end

function StatusIcons:_remove_native_for_panel_id(ai_id)
    local hud = managers.hud

    local teammate = hud._teammate_panels and hud._teammate_panels[ai_id]
    if teammate and alive(teammate._panel) then
        remove_native_stopped(teammate._panel)
    end

    local labels = hud._hud and hud._hud.name_labels
    for _, label in ipairs(labels or {}) do
        if label.id == ai_id and alive(label.panel) then
            remove_native_stopped(label.panel)
        end
    end
end

function StatusIcons:on_native_ai_stopped(ai_id, stopped)
    self:_remove_native_for_panel_id(ai_id)

    local character_name = managers.criminals:character_name_by_panel_id(ai_id)
    if not character_name then
        self._pending_panel_holds[ai_id] = stopped and true or nil
        self._dirty = true
        self._next_state_t = 0
        return
    end

    self._pending_panel_holds[ai_id] = nil
    self._local_holds[character_name] = stopped and true or nil
    self._dirty = true
    self._next_state_t = 0
    self:_reconcile_character(character_name)
end

function StatusIcons:_resolve_pending_holds()
    local criminals = managers.criminals

    local resolved = false
    for ai_id in pairs(self._pending_panel_holds) do
        local character_name = criminals:character_name_by_panel_id(ai_id)
        if character_name then
            self._pending_panel_holds[ai_id] = nil
            self._local_holds[character_name] = true
            resolved = true
        end
    end

    if resolved then
        self._dirty = true
    end

    return resolved
end

function StatusIcons:_collect_authoritative_roles()
    local group_state = managers.groupai:state()
    if not group_state then
        return nil
    end

    local criminals = managers.criminals
    local desired = {}

    for _, unit_data in pairs(group_state:all_AI_criminals()) do
        local unit = unit_data and unit_data.unit
        local combat_status = UnitOps.combat_status(unit)
        local character_name = combat_status.is_alive
                and criminals:character_name_by_unit(unit)
        if character_name then
            local role = BB.RescueCoordinator.get_status_role(unit, combat_status)
            local movement = unit:movement()

            if not role
                    and combat_status.can_fight
                    and movement
                    and movement:should_stay()
            then
                role = self.ROLES.hold
            end

            if not role then
                role = BB.ProactiveAttack:get_status_role(unit, combat_status)
            end

            if role and ROLE_DEFS[role] then
                desired[character_name] = role
            end
        end
    end

    return desired
end

local function encode_role(character_name, role)
    return tostring(character_name) .. "|" .. tostring(role or ROLE_NONE)
end

local function decode_role(data)
    if type(data) ~= "string" then
        return nil, nil
    end

    local character_name, role = data:match("^([%w_%-]+)|([%w_]+)$")
    if not character_name or role ~= ROLE_NONE and not ROLE_DEFS[role] then
        return nil, nil
    end

    return character_name, role
end

function StatusIcons:_send_role_to_peers(character_name, role)
    LuaNetworking:SendToPeers(MESSAGE_SET, encode_role(character_name, role))
    return true
end

function StatusIcons:_apply_authoritative_roles(desired)
    if type(desired) ~= "table" then
        return false
    end

    local character_names = {}
    for character_name in pairs(self._roles) do
        character_names[character_name] = true
    end
    for character_name in pairs(desired) do
        character_names[character_name] = true
    end

    local changed = false
    for character_name in pairs(character_names) do
        local old_role = self._roles[character_name]
        local new_role = desired[character_name]
        if old_role ~= new_role then
            self._roles[character_name] = new_role
            self:_send_role_to_peers(character_name, new_role)
            changed = true
        end
    end

    self._authoritative_ready = true
    if changed then
        self._dirty = true
    end

    return true
end

function StatusIcons:_is_host_sender(sender)
    if not network_is_client() then
        return false
    end

    local session = managers.network and managers.network:session()
    local server_peer = session and session:server_peer()
    return server_peer and server_peer:id() == tonumber(sender) or false
end

function StatusIcons:_on_network_request(data, sender)
    if not network_is_server() then
        return
    end

    local peer_id = tonumber(sender)
    local session = managers.network and managers.network:session()
    local peer = peer_id and session and session:peer(peer_id)
    if not peer then
        return
    end

    if not self._authoritative_ready then
        self:_apply_authoritative_roles(self:_collect_authoritative_roles())
    end

    LuaNetworking:SendToPeer(peer_id, MESSAGE_RESET, "1")

    local character_names = {}
    for character_name in pairs(self._roles) do
        table.insert(character_names, character_name)
    end
    table.sort(character_names)

    for _, character_name in ipairs(character_names) do
        LuaNetworking:SendToPeer(
                peer_id,
                MESSAGE_SET,
                encode_role(character_name, self._roles[character_name])
        )
    end
end

function StatusIcons:_on_network_reset(data, sender)
    if not self:_is_host_sender(sender) then
        return
    end

    clear_table(self._roles)
    self._snapshot_received = true
    self._dirty = true
end

function StatusIcons:_on_network_set(data, sender)
    if not self:_is_host_sender(sender) then
        return
    end

    local character_name, role = decode_role(data)
    if not character_name then
        return
    end

    self._roles[character_name] = role ~= ROLE_NONE and role or nil
    self._dirty = true
end

function StatusIcons:_register_network_hooks()
    LuaNetworking:AddReceiveHook(
            MESSAGE_REQUEST,
            NETWORK_HOOK_PREFIX .. "Request",
            function(data, sender)
                StatusIcons:_on_network_request(data, sender)
            end
    )
    LuaNetworking:AddReceiveHook(
            MESSAGE_RESET,
            NETWORK_HOOK_PREFIX .. "Reset",
            function(data, sender)
                StatusIcons:_on_network_reset(data, sender)
            end
    )
    LuaNetworking:AddReceiveHook(
            MESSAGE_SET,
            NETWORK_HOOK_PREFIX .. "Set",
            function(data, sender)
                StatusIcons:_on_network_set(data, sender)
            end
    )

    return true
end

function StatusIcons:_request_snapshot(t)
    if self._snapshot_received
            or self._snapshot_request_attempts >= SNAPSHOT_MAX_ATTEMPTS
            or t < self._next_snapshot_request_t
    then
        return false
    end

    local session = managers.network and managers.network:session()
    local server_peer = session and session:server_peer()
    if not server_peer then
        return false
    end

    LuaNetworking:SendToPeer(server_peer:id(), MESSAGE_REQUEST, "1")
    self._snapshot_request_attempts = self._snapshot_request_attempts + 1
    self._next_snapshot_request_t = t + SNAPSHOT_RETRY_INTERVAL

    return true
end

function StatusIcons:update(t, dt)
    self:_resolve_pending_holds()

    if network_is_server() and t >= self._next_state_t then
        self._next_state_t = t + STATE_UPDATE_INTERVAL
        self:_apply_authoritative_roles(self:_collect_authoritative_roles())
    elseif network_is_client() then
        self:_request_snapshot(t)
    end

    if self._dirty or t >= self._next_hud_t then
        self._next_hud_t = t + HUD_RECONCILE_INTERVAL
        self:_reconcile_hud()
    end
end

function StatusIcons:reset_level_state()
    for _, cache in pairs(self._rendered) do
        cleanup_cached_surface(cache, "teammate")
        cleanup_cached_surface(cache, "label")
    end

    clear_table(self._roles)
    clear_table(self._local_holds)
    clear_table(self._pending_panel_holds)
    clear_table(self._rendered)
    self._authoritative_ready = nil
    self._snapshot_received = nil
    self._snapshot_request_attempts = 0
    self._next_snapshot_request_t = 0
    self._next_state_t = 0
    self._next_hud_t = 0
    self._dirty = true

    return true
end

StatusIcons:_register_network_hooks()

return StatusIcons
