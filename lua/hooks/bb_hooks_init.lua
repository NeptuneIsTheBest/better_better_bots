local BB = _G.BB
local Utils = BB.Utils

local bb_log = Utils.log
local safe_call = Utils.safe_call

Hooks:Add("LocalizationManagerPostInit", "BB_LocalizationManager_PostInit", function(loc)
    if not loc then
        bb_log("LocalizationManager is nil", "WARN")
        return
    end

    local loc_dir = BB._path .. "loc/"
    local files_ok, files = safe_call(file.GetFiles, loc_dir)

    if files_ok and files then
        local lang_key = SystemInfo:language():key()
        for _, filename in pairs(files) do
            local lang = filename:match("^(.*)%.txt$")
            if lang and Idstring(lang):key() == lang_key then
                safe_call(loc.load_localization_file, loc, loc_dir .. filename)
                break
            end
        end
    end

    safe_call(loc.load_localization_file, loc, BB._path .. "loc/english.txt", false)
end)

Hooks:Add("MenuManagerInitialize", "BB_MenuManager_Initialize", function(menu_manager)
    if not menu_manager then
        bb_log("MenuManager is nil", "WARN")
        return
    end

    local function register_toggle(cb_name, key)
        MenuCallbackHandler[cb_name] = function(_, item)
            BB._data[key] = Utils.as_bool_from_item(item)
            BB:Save()
        end
    end

    local function register_choice(cb_name, key, default_num)
        MenuCallbackHandler[cb_name] = function(_, item)
            BB._data[key] = Utils.as_number_from_item(item, default_num)
            BB:Save()
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

    for _, name in ipairs(toggles) do
        local key = name == "dwn" and "instadwn"
                or (name == "clk" and "clkarrest" or name)
        register_toggle("callback_" .. name .. "_toggle", key)
    end

    if MenuHelper and MenuHelper.LoadFromJsonFile then
        MenuHelper:LoadFromJsonFile(BB._path .. "menu.txt", BB, BB._data)
    else
        bb_log("MenuHelper not found", "WARN")
    end
end)
