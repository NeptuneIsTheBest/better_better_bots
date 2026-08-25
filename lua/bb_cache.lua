local BB = _G.BB

local Utils = BB.Utils
local CACHE_INSTANCES = BB._cache_instances

if type(CACHE_INSTANCES) ~= "table" then
    CACHE_INSTANCES = setmetatable({}, { __mode = "k" })
    BB._cache_instances = CACHE_INSTANCES
elseif not getmetatable(CACHE_INSTANCES) then
    setmetatable(CACHE_INSTANCES, { __mode = "k" })
end

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
    self._count = 0
    self._hits = 0
    self._misses = 0

    CACHE_INSTANCES[self] = true

    return self
end

function CacheManager:reset()
    self._cache = {}
    self._last_cleanup = 0
    self._count = 0
    self._hits = 0
    self._misses = 0
end

function CacheManager.reset_all_instances()
    local reset_count = 0

    for cache in pairs(CACHE_INSTANCES) do
        cache:reset()
        reset_count = reset_count + 1
    end

    return reset_count
end

function CacheManager:get(key)
    if not key then
        self._misses = self._misses + 1
        return nil
    end

    local entry = self._cache[key]
    if not entry then
        self._misses = self._misses + 1
        return nil
    end

    local now = Utils.game_time()
    local ttl = entry.ttl or self._ttl

    if now - entry.t > ttl then
        self._cache[key] = nil
        self._count = self._count - 1
        self._misses = self._misses + 1
        return nil
    end

    entry.last_access = now
    self._hits = self._hits + 1
    return entry.value
end

function CacheManager:set(key, value, ttl)
    if not key then
        return
    end

    local now = Utils.game_time()
    local is_new = self._cache[key] == nil

    self._cache[key] = {
        value = value,
        t = now,
        last_access = now,
        ttl = ttl
    }

    if is_new then
        self._count = self._count + 1
    end

    self:_maybe_cleanup(now)
end

function CacheManager:clear(key)
    if key then
        if self._cache[key] then
            self._cache[key] = nil
            self._count = self._count - 1
        end
    else
        self._cache = {}
        self._count = 0
        Utils.log(string.format("[%s] Cache cleared", self._name), "DEBUG")
    end
end

function CacheManager:has(key)
    return self:get(key) ~= nil
end

function CacheManager:size()
    return self._count
end

function CacheManager:cleanup(force)
    local now = Utils.game_time()

    if not force and now - self._last_cleanup < self._cleanup_interval then
        return
    end

    self._last_cleanup = now

    local removed = 0

    for k, entry in pairs(self._cache) do
        local ttl = entry.ttl or self._ttl
        if now - entry.t > ttl then
            self._cache[k] = nil
            removed = removed + 1
        end
    end

    self._count = self._count - removed

    if self._count > self._max_size then
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

        local to_remove = self._count - self._max_size
        for i = 1, to_remove do
            if entries[i] then
                self._cache[entries[i].key] = nil
                removed = removed + 1
                self._count = self._count - 1
            end
        end
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
    local total_requests = self._hits + self._misses
    local hit_rate = total_requests > 0 and (self._hits / total_requests * 100) or 0

    return {
        name = self._name,
        total = self._count,
        max_size = self._max_size,
        ttl = self._ttl,
        last_cleanup = self._last_cleanup,
        hits = self._hits,
        misses = self._misses,
        hit_rate = hit_rate
    }
end

local CoopCacheManager = {}

local CACHE_NAMES = {"teammate_status", "threat_value", "suitability", "teammate_distance", "conc_area_cooldown"}

function CoopCacheManager.init()
    CoopCacheManager.teammate_status = CacheManager.new({
        ttl = 0.5,
        max_size = 64,
        cleanup_interval = 2,
        name = "TeammateStatus"
    })

    CoopCacheManager.threat_value = CacheManager.new({
        ttl = 0.1,
        max_size = 200,
        cleanup_interval = 3,
        name = "ThreatValue"
    })

    CoopCacheManager.suitability = CacheManager.new({
        ttl = 0.1,
        max_size = 200,
        cleanup_interval = 3,
        name = "Suitability"
    })

    CoopCacheManager.teammate_distance = CacheManager.new({
        ttl = 0.5,
        max_size = 50,
        cleanup_interval = 2,
        name = "TeammateDistance"
    })

    CoopCacheManager.conc_area_cooldown = CacheManager.new({
        ttl = 3,
        max_size = 50,
        cleanup_interval = 2,
        name = "ConcAreaCooldown"
    })
    CoopCacheManager._next_cleanup_t = 0
end

function CoopCacheManager.cleanup_all(force)
    for _, name in ipairs(CACHE_NAMES) do
        CoopCacheManager[name]:cleanup(force)
    end
end

function CoopCacheManager.clear_all()
    for _, name in ipairs(CACHE_NAMES) do
        CoopCacheManager[name]:clear()
    end

    CoopCacheManager._next_cleanup_t = 0
end

function CoopCacheManager.all_stats()
    local result = {}
    for _, name in ipairs(CACHE_NAMES) do
        result[name] = CoopCacheManager[name]:stats()
    end
    return result
end

CoopCacheManager.init()

BB.CacheManager = CacheManager
BB.CoopCacheManager = CoopCacheManager
