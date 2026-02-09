local BB = _G.BB

local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP

local EnemyClassifier = {}
EnemyClassifier._cache_manager = nil

function EnemyClassifier._init_cache()
    if not EnemyClassifier._cache_manager and BB.CacheManager then
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

    EnemyClassifier._init_cache()

    local u_key = tostring(unit:key())

    if EnemyClassifier._cache_manager then
        local cached = EnemyClassifier._cache_manager:get(u_key)
        if cached then
            local brain = unit:brain()
            local logic_data = brain and brain._logic_data
            local internal_data = logic_data and logic_data.internal_data
            cached.tasing = internal_data and internal_data.tasing or false
            cached.spooc_attack = internal_data and internal_data.spooc_attack or false
            return cached
        end
    end

    local base = unit:base()
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

    local brain = unit:brain()
    local logic_data = brain and brain._logic_data
    local internal_data = logic_data and logic_data.internal_data
    if internal_data then
        if internal_data.tasing then
            flags.tasing = true
        end
        if internal_data.spooc_attack then
            flags.spooc_attack = true
        end
    end

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

    local tweak_name = base and base._tweak_table
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
            if char_tweak.tags[tag] then
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

    if EnemyClassifier._cache_manager then
        EnemyClassifier._cache_manager:set(u_key, flags)
    end

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
