_G.BB = _G.BB or {}
local BB = _G.BB

local Utils = BB.Utils

local CacheManager = {}
CacheManager.__index = CacheManager

function CacheManager.new(options)
    local self = setmetatable({}, CacheManager)
    options = options or {}

    self._cache = {}
    self._ttl = options.ttl or 5
    self._max_size = options.max_size or 1000
    self._last_cleanup = 0
    self._cleanup_interval = options.cleanup_interval or 10
    self._name = options.name or "UnnamedCache"

    return self
end

function CacheManager:get(key)
    if not key then
        return nil
    end

    local entry = self._cache[key]
    if not entry then
        return nil
    end

    local now = Utils.game_time()
    local ttl = entry.ttl or self._ttl

    if now - entry.t > ttl then
        self._cache[key] = nil
        return nil
    end

    entry.last_access = now
    return entry.value
end

function CacheManager:set(key, value, ttl)
    if not key then
        return
    end

    local now = Utils.game_time()

    self._cache[key] = {
        value = value,
        t = now,
        last_access = now,
        ttl = ttl
    }

    self:_maybe_cleanup(now)
end

function CacheManager:clear(key)
    if key then
        self._cache[key] = nil
    else
        self._cache = {}
        Utils.log(string.format("[%s] Cache cleared", self._name), "DEBUG")
    end
end

function CacheManager:has(key)
    return self:get(key) ~= nil
end

function CacheManager:size()
    local count = 0
    for _ in pairs(self._cache) do
        count = count + 1
    end
    return count
end

function CacheManager:cleanup(force)
    local now = Utils.game_time()

    if not force and now - self._last_cleanup < self._cleanup_interval then
        return
    end

    self._last_cleanup = now

    local removed = 0
    local remaining = 0

    for k, entry in pairs(self._cache) do
        local ttl = entry.ttl or self._ttl
        if now - entry.t > ttl then
            self._cache[k] = nil
            removed = removed + 1
        else
            remaining = remaining + 1
        end
    end

    if remaining > self._max_size then
        local entries = {}
        for k, entry in pairs(self._cache) do
            table.insert(entries, {
                key = k,
                last_access = entry.last_access or entry.t
            })
        end

        table.sort(entries, function(a, b)
            return a.last_access < b.last_access
        end)

        local to_remove = remaining - self._max_size
        for i = 1, to_remove do
            if entries[i] then
                self._cache[entries[i].key] = nil
                removed = removed + 1
            end
        end
    end

    if removed > 0 then
        Utils.log(string.format("[%s] Cleaned %d entries, %d remaining", self._name, removed, self:size()), "DEBUG")
    end
end

function CacheManager:_maybe_cleanup(now)
    now = now or Utils.game_time()

    if now - self._last_cleanup >= self._cleanup_interval then
        self:cleanup(false)
    end
end

function CacheManager:keys()
    local result = {}
    for k, _ in pairs(self._cache) do
        table.insert(result, k)
    end
    return result
end

function CacheManager:stats()
    local now = Utils.game_time()
    local total = 0
    local expired = 0

    for _, entry in pairs(self._cache) do
        total = total + 1
        local ttl = entry.ttl or self._ttl
        if now - entry.t > ttl then
            expired = expired + 1
        end
    end

    return {
        name = self._name,
        total = total,
        expired = expired,
        valid = total - expired,
        max_size = self._max_size,
        ttl = self._ttl,
        last_cleanup = self._last_cleanup
    }
end

local CoopCacheManager = {}

function CoopCacheManager.init()
    CoopCacheManager.teammate_status = CacheManager.new({
        ttl = 0.5,
        max_size = 20,
        cleanup_interval = 2,
        name = "TeammateStatus"
    })

    CoopCacheManager.priority_target = CacheManager.new({
        ttl = 2,
        max_size = 100,
        cleanup_interval = 5,
        name = "PriorityTarget"
    })

    CoopCacheManager.threat_value = CacheManager.new({
        ttl = 0.3,
        max_size = 200,
        cleanup_interval = 3,
        name = "ThreatValue"
    })

    CoopCacheManager.suitability = CacheManager.new({
        ttl = 0.3,
        max_size = 200,
        cleanup_interval = 3,
        name = "Suitability"
    })

    CoopCacheManager.teammate_distance = CacheManager.new({
        ttl = 0.2,
        max_size = 50,
        cleanup_interval = 2,
        name = "TeammateDistance"
    })
end

function CoopCacheManager.cleanup_all()
    if CoopCacheManager.teammate_status then
        CoopCacheManager.teammate_status:cleanup(true)
    end
    if CoopCacheManager.priority_target then
        CoopCacheManager.priority_target:cleanup(true)
    end
    if CoopCacheManager.threat_value then
        CoopCacheManager.threat_value:cleanup(true)
    end
    if CoopCacheManager.suitability then
        CoopCacheManager.suitability:cleanup(true)
    end
    if CoopCacheManager.teammate_distance then
        CoopCacheManager.teammate_distance:cleanup(true)
    end
end

function CoopCacheManager.clear_all()
    if CoopCacheManager.teammate_status then
        CoopCacheManager.teammate_status:clear()
    end
    if CoopCacheManager.priority_target then
        CoopCacheManager.priority_target:clear()
    end
    if CoopCacheManager.threat_value then
        CoopCacheManager.threat_value:clear()
    end
    if CoopCacheManager.suitability then
        CoopCacheManager.suitability:clear()
    end
    if CoopCacheManager.teammate_distance then
        CoopCacheManager.teammate_distance:clear()
    end
end

CoopCacheManager.init()

BB.CacheManager = CacheManager
BB.CoopCacheManager = CoopCacheManager
