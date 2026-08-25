local BB = _G.BB

local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP

local EnemyClassifier = {}
EnemyClassifier._cache_manager = nil

local function has_tag(tags, tag)
    local tags_type = type(tags)

    if tags_type == "string" then
        return tags == tag
    elseif tags_type ~= "table" then
        return false
    end

    if tags[tag] then
        return true
    end

    for _, value in ipairs(tags) do
        if value == tag then
            return true
        end
    end

    return false
end

local function update_dynamic_flags(flags, unit)
    local brain = unit:brain()
    local logic_data = brain and brain._logic_data
    local internal_data = logic_data and logic_data.internal_data

    flags.tasing = internal_data and internal_data.tasing or false
    flags.spooc_attack = internal_data and internal_data.spooc_attack or false
end

function EnemyClassifier._init_cache()
    if not EnemyClassifier._cache_manager then
        EnemyClassifier._cache_manager = BB.CacheManager.new({
            ttl = 1,
            max_size = 500,
            cleanup_interval = 5,
            name = "EnemyClassifier"
        })
    end
end

function EnemyClassifier._infer_flags_from_name(name)
    local f = {}

    if not name then
        return f
    end

    name = tostring(name):lower()

    for pattern, flag in pairs(BB.INFER_FLAGS_PATTERNS) do
        if name:find(pattern) then
            f[flag] = true
        end
    end

    return f
end

function EnemyClassifier._merge_flags(dst, src)
    if not (dst and src) then
        return
    end

    for k, v in pairs(src) do
        if v then
            dst[k] = true
        end
    end
end

function EnemyClassifier.classify(unit, att_obj)
    local result_default = { special = false }

    if not alive(unit) then
        return result_default
    end

    local base = unit:base()
    local tweak_name = base and base._tweak_table
    local u_key = tostring(unit:key())

    EnemyClassifier._init_cache()

    local cached = EnemyClassifier._cache_manager:get(u_key)
    if cached and cached.tweak_name == tweak_name and cached.flags then
        update_dynamic_flags(cached.flags, unit)
        return cached.flags
    end

    local flags = {
        turret = base and base.sentry_gun or false,
        shield = false,
        dozer = false,
        taser = false,
        cloaker = false,
        medic = false,
        sniper = false,
        captain = false,
        special = false,
        tasing = false,
        spooc_attack = false,
    }

    update_dynamic_flags(flags, unit)

    if att_obj then
        if att_obj.is_shield then
            flags.shield = true
        end
        if att_obj.is_very_dangerous then
            flags.special = true
        end
    end

    if base and base.has_tag then
        for tag, flag in pairs(BB.CLASSIFY_TAG_MAP) do
            if base:has_tag(tag) then
                flags[flag] = true
            end
        end
    end

    local char_tweak = (att_obj and att_obj.char_tweak)
            or (base and base.char_tweak and base:char_tweak())
            or (tweak_data and tweak_data.character and tweak_name and tweak_data.character[tweak_name])

    if tweak_name then
        local direct = ENEMY_TWEAK_MAP[tweak_name]
        if direct then
            EnemyClassifier._merge_flags(flags, direct)
        else
            EnemyClassifier._merge_flags(flags, EnemyClassifier._infer_flags_from_name(tweak_name))
        end
    end

    if char_tweak and char_tweak.tags then
        for tag, flag in pairs(BB.CLASSIFY_TAG_MAP) do
            if has_tag(char_tweak.tags, tag) then
                flags[flag] = true
            end
        end
    end

    if char_tweak and char_tweak.priority_shout then
        flags.special = true
    end

    if flags.shield
            or flags.dozer
            or flags.taser
            or flags.cloaker
            or flags.sniper
            or flags.medic
            or flags.captain
    then
        flags.special = true
    end

    EnemyClassifier._cache_manager:set(u_key, {
        tweak_name = tweak_name,
        flags = flags,
    })

    return flags
end

local function create_classifier_method(flag_name)
    return function(unit, att_obj)
        return EnemyClassifier.classify(unit, att_obj)[flag_name] or false
    end
end

EnemyClassifier.is_turret = create_classifier_method("turret")
EnemyClassifier.is_shield = create_classifier_method("shield")
EnemyClassifier.is_special = create_classifier_method("special")
EnemyClassifier.is_dozer = create_classifier_method("dozer")
EnemyClassifier.is_sniper = create_classifier_method("sniper")
EnemyClassifier.is_taser = create_classifier_method("taser")
EnemyClassifier.is_cloaker = create_classifier_method("cloaker")
EnemyClassifier.is_medic = create_classifier_method("medic")

BB.EnemyClassifier = EnemyClassifier
BB.classify_enemy = EnemyClassifier.classify
