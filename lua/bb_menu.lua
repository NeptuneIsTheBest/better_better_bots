local BB = _G.BB
local Utils = BB.Utils
local RuntimeSettings = BB.RuntimeSettings

local bb_log = Utils.log

local MENU_ID = "bb_menu"
local MENU_TITLE = "bb_menu_title"
local MENU_DESC = "bb_menu_desc"
local RUNTIME_SETTING_KEYS = {
    move = true,
    dodge = true,
    biglob = true,
    conc = true,
    keepstaying = true,
}
local MENU_ITEMS = {
    {
        type = "multiple_choice",
        id = "health_choice",
        title = "health_choice_title",
        desc = "health_choice_desc",
        callback = "callback_health_choice",
        items = {
            "health_choice_default",
            "health_choice_2x",
            "health_choice_3x",
        },
        data_key = "health",
        default_value = 1,
        feature_flag = "HEALTH_MULTIPLIER",
    },
    {
        type = "multiple_choice",
        id = "move_choice",
        title = "move_choice_title",
        desc = "move_choice_desc",
        callback = "callback_move_choice",
        items = {
            "move_choice_default",
            "move_choice_dodge",
            "move_choice_no_crouching",
        },
        data_key = "move",
        default_value = 1,
    },
    {
        type = "multiple_choice",
        id = "dodge_choice",
        title = "dodge_choice_title",
        desc = "dodge_choice_desc",
        callback = "callback_dodge_choice",
        items = {
            "dodge_choice_poor",
            "dodge_choice_average",
            "dodge_choice_heavy",
            "dodge_choice_athletic",
            "dodge_choice_ninja",
        },
        data_key = "dodge",
        default_value = 4,
    },
    {
        type = "multiple_choice",
        id = "dmgmul_choice",
        title = "dmgmul_choice_title",
        desc = "dmgmul_choice_desc",
        callback = "callback_dmgmul_choice",
        items = {
            "dmgmul_choice_1",
            "dmgmul_choice_2",
            "dmgmul_choice_3",
            "dmgmul_choice_4",
            "dmgmul_choice_5",
        },
        data_key = "dmgmul",
        default_value = 5,
        feature_flag = "DAMAGE_MULTIPLIER",
    },
    {
        type = "toggle",
        id = "dwn_toggle",
        title = "dwn_toggle_title",
        desc = "dwn_toggle_desc",
        callback = "callback_dwn_toggle",
        data_key = "instadwn",
        default_value = false,
    },
    {
        type = "toggle",
        id = "clk_toggle",
        title = "clk_toggle_title",
        desc = "clk_toggle_desc",
        callback = "callback_clk_toggle",
        data_key = "clkarrest",
        default_value = false,
    },
    {
        type = "toggle",
        id = "chat_toggle",
        title = "chat_toggle_title",
        desc = "chat_toggle_desc",
        callback = "callback_chat_toggle",
        data_key = "chat",
        default_value = false,
    },
    {
        type = "toggle",
        id = "doc_toggle",
        title = "doc_toggle_title",
        desc = "doc_toggle_desc",
        callback = "callback_doc_toggle",
        data_key = "doc",
        default_value = false,
    },
    {
        type = "toggle",
        id = "dom_toggle",
        title = "dom_toggle_title",
        desc = "dom_toggle_desc",
        callback = "callback_dom_toggle",
        data_key = "dom",
        default_value = false,
    },
    {
        type = "toggle",
        id = "biglob_toggle",
        title = "biglob_toggle_title",
        desc = "biglob_toggle_desc",
        callback = "callback_biglob_toggle",
        data_key = "biglob",
        default_value = false,
    },
    {
        type = "toggle",
        id = "reflex_toggle",
        title = "reflex_toggle_title",
        desc = "reflex_toggle_desc",
        callback = "callback_reflex_toggle",
        data_key = "reflex",
        default_value = false,
    },
    {
        type = "toggle",
        id = "maskup_toggle",
        title = "maskup_toggle_title",
        desc = "maskup_toggle_desc",
        callback = "callback_maskup_toggle",
        data_key = "maskup",
        default_value = false,
    },
    {
        type = "toggle",
        id = "equip_toggle",
        title = "equip_toggle_title",
        desc = "equip_toggle_desc",
        callback = "callback_equip_toggle",
        data_key = "equip",
        default_value = false,
    },
    {
        type = "toggle",
        id = "combat_toggle",
        title = "combat_toggle_title",
        desc = "combat_toggle_desc",
        callback = "callback_combat_toggle",
        data_key = "combat",
        default_value = false,
    },
    {
        type = "toggle",
        id = "ammo_toggle",
        title = "ammo_toggle_title",
        desc = "ammo_toggle_desc",
        callback = "callback_ammo_toggle",
        data_key = "ammo",
        default_value = false,
    },
    {
        type = "toggle",
        id = "conc_toggle",
        title = "conc_toggle_title",
        desc = "conc_toggle_desc",
        callback = "callback_conc_toggle",
        data_key = "conc",
        default_value = false,
    },
    {
        type = "toggle",
        id = "coop_toggle",
        title = "coop_toggle_title",
        desc = "coop_toggle_desc",
        callback = "callback_coop_toggle",
        data_key = "coop",
        default_value = false,
    },
    {
        type = "toggle",
        id = "keepstaying_toggle",
        title = "keepstaying_toggle_title",
        desc = "keepstaying_toggle_desc",
        callback = "callback_keepstaying_toggle",
        data_key = "keepstaying",
        default_value = false,
    },
}

local function is_feature_flag_enabled(flag_name)
    if not flag_name then
        return true
    end

    return not BB.FEATURE_FLAGS or BB.FEATURE_FLAGS[flag_name] ~= false
end

local function get_menu_parent_node(nodes)
    return nodes and (nodes.lua_mod_options_menu or nodes.blt_options or nodes.options)
end

local function get_menu_item_value(item_def)
    return BB:get(item_def.data_key, item_def.default_value)
end

local function add_dynamic_menu_item(item_def, priority)
    if not MenuHelper then
        return
    end

    local data = {
        id = item_def.id,
        title = item_def.title,
        desc = item_def.desc,
        callback = item_def.callback,
        value = get_menu_item_value(item_def),
        menu_id = MENU_ID,
        priority = priority,
    }

    if item_def.type == "toggle" then
        MenuHelper:AddToggle(data)
    elseif item_def.type == "multiple_choice" then
        data.items = item_def.items
        MenuHelper:AddMultipleChoice(data)
    else
        bb_log("Unsupported menu item type: " .. tostring(item_def.type), "WARN")
    end
end

local function apply_runtime_setting(key)
    if RUNTIME_SETTING_KEYS[key] and RuntimeSettings and RuntimeSettings.apply then
        RuntimeSettings:apply(key)
    end
end

Hooks:Add("MenuManagerInitialize", "BB_MenuManager_Initialize", function(menu_manager)
    if not menu_manager then
        bb_log("MenuManager is nil", "WARN")
        return
    end

    local function register_toggle(cb_name, key)
        MenuCallbackHandler[cb_name] = function(_, item)
            BB._data[key] = Utils.as_bool_from_item(item)
            BB:Save()
            apply_runtime_setting(key)
        end
    end

    local function register_choice(cb_name, key, default_num)
        MenuCallbackHandler[cb_name] = function(_, item)
            BB._data[key] = Utils.as_number_from_item(item, default_num)
            BB:Save()
            apply_runtime_setting(key)
        end
    end

    register_choice("callback_health_choice", "health", 1)
    register_choice("callback_move_choice", "move", 1)
    register_choice("callback_dodge_choice", "dodge", 4)
    register_choice("callback_dmgmul_choice", "dmgmul", 5)

    local toggles = {
        "dwn",
        "clk",
        "chat",
        "doc",
        "dom",
        "biglob",
        "reflex",
        "maskup",
        "equip",
        "combat",
        "ammo",
        "conc",
        "coop",
        "keepstaying",
    }

    local toggle_keys = {
        dwn = "instadwn",
        clk = "clkarrest",
    }

    for _, name in ipairs(toggles) do
        local key = toggle_keys[name] or name
        register_toggle("callback_" .. name .. "_toggle", key)
    end
end)

Hooks:Add("MenuManagerSetupCustomMenus", "BB_MenuManager_SetupCustomMenus", function(menu_manager, nodes)
    if not (menu_manager and nodes) then
        bb_log("MenuManager setup received invalid state", "WARN")
        return
    end

    if MenuHelper and MenuHelper.NewMenu then
        MenuHelper:NewMenu(MENU_ID)
    else
        bb_log("MenuHelper not found", "WARN")
    end
end)

Hooks:Add("MenuManagerPopulateCustomMenus", "BB_MenuManager_PopulateCustomMenus", function(menu_manager, nodes)
    if not (menu_manager and nodes) then
        bb_log("MenuManager populate received invalid state", "WARN")
        return
    end

    if not MenuHelper then
        bb_log("MenuHelper not found", "WARN")
        return
    end

    local priority = #MENU_ITEMS
    for _, item_def in ipairs(MENU_ITEMS) do
        if is_feature_flag_enabled(item_def.feature_flag) then
            add_dynamic_menu_item(item_def, priority)
            priority = priority - 1
        end
    end
end)

Hooks:Add("MenuManagerBuildCustomMenus", "BB_MenuManager_BuildCustomMenus", function(menu_manager, nodes)
    if not (menu_manager and nodes) then
        bb_log("MenuManager build received invalid state", "WARN")
        return
    end

    if not MenuHelper then
        bb_log("MenuHelper not found", "WARN")
        return
    end

    local parent_node = get_menu_parent_node(nodes)
    if not parent_node then
        bb_log("Failed to locate mod options parent menu", "WARN")
        return
    end

    nodes[MENU_ID] = MenuHelper:BuildMenu(MENU_ID)
    MenuHelper:AddMenuItem(parent_node, MENU_ID, MENU_TITLE, MENU_DESC)
end)
