local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local Utils = BB.Utils

local bb_log = Utils.log
local safe_call = Utils.safe_call
local game_time = Utils.game_time

BB._path = ModPath
BB._data_path = SavePath .. "bb_data.txt"
BB._data = BB._data or {}
BB.cops_to_intimidate = BB.cops_to_intimidate or {}
BB.grace_period = BB.grace_period or CONSTANTS.GRACE_PERIOD
BB.dom_failures = BB.dom_failures or {}
BB.dom_blacklist = BB.dom_blacklist or {}
BB.dom_pending = BB.dom_pending or {}

-- Older versions stored an unscoped timestamp here. It cannot be safely
-- attributed after a hot reload, so discard legacy pending entries.
for u_key, pending in pairs(BB.dom_pending) do
    if type(pending) ~= "table" or pending.aggressor_key == nil then
        BB.dom_pending[u_key] = nil
    end
end

function BB:Save()
    local ok, encoded = safe_call(json.encode, self._data)
    if not ok then
        bb_log("Failed to encode save data", "ERROR")
        return
    end

    local file = io.open(self._data_path, "w")
    if file then
        file:write(encoded)
        file:close()
    else
        bb_log("Failed to open save file", "ERROR")
    end
end

function BB:Load()
    local file = io.open(self._data_path, "r")
    if not file then
        bb_log("No save file found, using defaults")
        return
    end

    local raw = file:read("*all")
    file:close()

    if not raw or raw == "" then
        bb_log("Save file is empty")
        return
    end

    local ok, decoded = safe_call(json.decode, raw)
    if ok and type(decoded) == "table" then
        self._data = decoded
        bb_log("Data loaded")
    else
        bb_log("Failed to decode save data", "ERROR")
    end
end

function BB:get(key, default)
    local v = self._data[key]
    return v ~= nil and v or default
end

function BB:is_blacklisted_cop(u_key)
    return u_key and self.dom_blacklist and self.dom_blacklist[tostring(u_key)] == true
end

function BB:clear_cop_state(u_key)
    if not u_key then
        return
    end

    u_key = tostring(u_key)

    self.cops_to_intimidate[u_key] = nil
    self.dom_failures[u_key] = nil
    self.dom_blacklist[u_key] = nil
    self.dom_pending[u_key] = nil
end

function BB:on_intimidation_attempt(u_key, aggressor_key)
    if not u_key or not aggressor_key or self:is_blacklisted_cop(u_key) then
        return
    end

    local attempt = {
        aggressor_key = tostring(aggressor_key),
    }

    self.dom_pending[tostring(u_key)] = attempt

    return attempt
end

function BB:clear_intimidation_attempt(u_key, attempt)
    if not u_key or type(attempt) ~= "table" then
        return false
    end

    u_key = tostring(u_key)

    if self.dom_pending[u_key] ~= attempt then
        return false
    end

    self.dom_pending[u_key] = nil

    return true
end

function BB:on_intimidation_result(u_key, success, aggressor_key)
    if not u_key or not aggressor_key then
        return false
    end

    u_key = tostring(u_key)

    local pending = self.dom_pending[u_key]
    if type(pending) ~= "table" or pending.aggressor_key ~= tostring(aggressor_key) then
        return false
    end

    self.dom_pending[u_key] = nil

    if success then
        self.dom_failures[u_key] = nil
        self.dom_blacklist[u_key] = nil
        return true
    end

    local rec = self.dom_failures[u_key] or { attempts = 0 }
    rec.attempts = (rec.attempts or 0) + 1
    rec.last_t = game_time()
    self.dom_failures[u_key] = rec

    if rec.attempts >= CONSTANTS.INTIMIDATE_MAX_ATTEMPTS then
        self.dom_blacklist[u_key] = true
        self.cops_to_intimidate[u_key] = nil
    end

    return true
end

function BB:add_cop_to_intimidation_list(unit_key)
    if not unit_key or self:is_blacklisted_cop(unit_key) then
        return
    end

    local t = game_time()
    unit_key = tostring(unit_key)
    local prev_t = self.cops_to_intimidate[unit_key]
    self.cops_to_intimidate[unit_key] = t

    if not Network:is_server() then
        return
    end

    local is_new = not prev_t or (t - prev_t) > self.grace_period
    if not is_new then
        return
    end

    local function clear_attention_for_unit(unit)
        if not alive(unit) then
            return
        end

        local brain = unit:brain()
        if not (brain and brain._logic_data) then
            return
        end

        local att_obj = brain._logic_data.attention_obj
        if att_obj and tostring(att_obj.u_key) == unit_key then
            if CopLogicBase and CopLogicBase._set_attention_obj then
                CopLogicBase._set_attention_obj(brain._logic_data, nil, nil)
            end
        end
    end

    local gstate = managers.groupai and managers.groupai:state()
    if not gstate then
        return
    end

    if gstate._ai_criminals then
        for _, sighting in pairs(gstate._ai_criminals) do
            if sighting and sighting.unit then
                clear_attention_for_unit(sighting.unit)
            end
        end
    end

    if gstate._converted_police then
        for _, unit in pairs(gstate._converted_police) do
            clear_attention_for_unit(unit)
        end
    end
end

BB:Load()
