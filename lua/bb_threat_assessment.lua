local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP
local CoopCacheManager = BB.CoopCacheManager
local EnemyClassifier = BB.EnemyClassifier

local ThreatAssessment = {}

local function _get_tweak_name(u)
    local base = alive(u) and u:base()
    return base and base._tweak_table
end

local PHALANX_VIP_SET = { phalanx_vip = true, phalanx_vip_test = true }
local PHALANX_MINION_SET = { phalanx_minion = true }
local LOG_TWO = math.log(2)

local CombatHelper = BB.CombatHelper

local function _clamp(value, low, high)
    return math.min(math.max(value, low), high)
end

local function _get_char_tweak(unit, target_data)
    if target_data and target_data.char_tweak then
        return target_data.char_tweak
    end

    local base = alive(unit) and unit:base()
    return base and base.char_tweak and base:char_tweak() or nil
end

local function _get_health_ratio(unit)
    local damage = alive(unit)
            and unit.character_damage
            and unit:character_damage()
    return damage and damage.health_ratio and damage:health_ratio() or nil
end

local function _get_max_health(unit)
    local damage = alive(unit)
            and unit.character_damage
            and unit:character_damage()
    local health = damage and damage._HEALTH_INIT
    return health and health > 0 and health or nil
end

local function _get_reference_health()
    return managers.modifiers:modify_value(
            "CopDamage:InitialHealth",
            tweak_data.character.heavy_swat.HEALTH_INIT,
            "heavy_swat"
    )
end

local function _select_falloff(falloff, distance)
    if not falloff then
        return nil
    end

    for _, range_data in ipairs(falloff) do
        if distance < range_data.r then
            return range_data
        end
    end

    return falloff[#falloff]
end

local function _turret_range_multiplier(ranges, distance)
    local range_index
    for index, range_data in ipairs(ranges) do
        if distance < range_data[1] or index == #ranges then
            range_index = index
            break
        end
    end

    if range_index == 1 or distance > ranges[range_index][1] then
        return ranges[range_index][2]
    end

    local previous = ranges[range_index - 1]
    local current = ranges[range_index]
    local progress = (distance - previous[1]) / (current[1] - previous[1])
    return previous[2] + (current[2] - previous[2]) * progress
end

function ThreatAssessment.calculate_effective_damage(
        base_damage,
        distance,
        falloff,
        turret_ranges
)
    if not base_damage or base_damage <= 0 then
        return nil
    end

    local falloff_data = _select_falloff(falloff, distance)
    if falloff_data then
        return base_damage * falloff_data.dmg_mul
    elseif turret_ranges then
        return base_damage * _turret_range_multiplier(turret_ranges, distance)
    end

    return base_damage
end

local function _get_weapon_context(unit)
    if not alive(unit) then
        return nil
    end

    local inventory = unit.inventory and unit:inventory()
    local weapon_unit = inventory
            and inventory.equipped_unit
            and inventory:equipped_unit()
    local weapon_base = alive(weapon_unit) and weapon_unit:base()
    if weapon_base then
        local weapon_tweak = weapon_base.weapon_tweak_data
                and weapon_base:weapon_tweak_data()

        return {
            damage = weapon_base._damage,
            weapon_tweak = weapon_tweak,
        }
    end

    local weapon_ext = unit.weapon and unit:weapon()
    if not weapon_ext then
        return nil
    end

    local unit_base = unit:base()
    local weapon_tweak = unit_base
            and unit_base.weapon_tweak_data
            and unit_base:weapon_tweak_data()
            or nil

    return {
        damage = weapon_ext._damage,
        weapon_tweak = weapon_tweak,
    }
end

local function _get_effective_damage(unit, target_data, distance)
    local context = _get_weapon_context(unit)
    local damage = context and context.damage
    if not damage or damage <= 0 then
        return nil
    end

    local unit_base = unit:base()
    if unit_base and unit_base.get_total_buff then
        local buff = unit_base:get_total_buff("base_damage")
        damage = damage * (1 + buff)
    end

    local weapon_tweak = context.weapon_tweak or {}
    local char_tweak = _get_char_tweak(unit, target_data)
    local usage = weapon_tweak.usage
    local usage_tweak = usage
            and char_tweak
            and char_tweak.weapon
            and char_tweak.weapon[usage]
            or nil
    return ThreatAssessment.calculate_effective_damage(
            damage,
            distance,
            usage_tweak and usage_tweak.FALLOFF,
            weapon_tweak.DAMAGE_MUL_RANGE
    )
end

local function _get_reference_damage(distance)
    local weapon_tweak = tweak_data.weapon.m4_npc
    local char_tweak = tweak_data.character.fbi_swat
    local usage_tweak = char_tweak.weapon[weapon_tweak.usage]
    return ThreatAssessment.calculate_effective_damage(
            weapon_tweak.DAMAGE,
            distance,
            usage_tweak.FALLOFF
    )
end

local function _is_actively_firing(unit)
    if not alive(unit) then
        return false
    end

    local brain = unit.brain and unit:brain()
    local logic_data = brain and brain._logic_data
    local internal_data = logic_data and logic_data.internal_data
    local anim_data = unit.anim_data and unit:anim_data()
    if internal_data and internal_data.firing == true
            or anim_data and anim_data.fire == true
    then
        return true
    end

    local weapon_ext = unit.weapon and unit:weapon()
    return weapon_ext and weapon_ext._shooting == true or false
end

local function _get_targeting_state(unit, data)
    local brain = alive(unit) and unit.brain and unit:brain()
    local logic_data = brain and brain._logic_data
    local attention = logic_data and logic_data.attention_obj
    if not attention then
        return false, false
    end

    if attention.u_key == data.key then
        return true, true
    end

    return false, attention.criminal_record ~= nil
end

function ThreatAssessment.get_weapon_archetype(unit)
    if not alive(unit) then
        return "unknown"
    end

    local inv = unit:inventory()
    local equipped_wep = inv and inv:equipped_unit()
    if not alive(equipped_wep) then
        return "unknown"
    end

    local wep_base = equipped_wep:base()
    if not wep_base or not wep_base.is_category then
        return "unknown"
    end

    if wep_base:is_category("snp") then
        return "sniper"
    elseif wep_base:is_category("shotgun") then
        return "shotgun"
    elseif wep_base:is_category("lmg") then
        return "lmg"
    elseif wep_base:is_category("smg") then
        return "smg"
    elseif wep_base:is_category("assault_rifle") then
        return "assault_rifle"
    elseif wep_base:is_category("akimbo") then
        return "akimbo"
    elseif wep_base:is_category("pistol") then
        return "pistol"
    elseif wep_base:is_category("flamethrower") then
        return "flamethrower"
    end

    return "rifle"
end

function ThreatAssessment.get_archetype_damage_multiplier(bot_unit)
    if not BB.FEATURE_FLAGS.DAMAGE_MULTIPLIER or not BB:get("combat", false) then
        return 1
    end
    local dmg_mul = BB:get("dmgmul", 5)
    local archetype = ThreatAssessment.get_weapon_archetype(bot_unit) or "unknown"
    local archetype_mul = BB.ARCHETYPE_DAMAGE_MULTIPLIERS[archetype] or CONSTANTS.DEFAULT_ARCHETYPE_MUL
    return dmg_mul * archetype_mul
end

function ThreatAssessment.count_alive_with_tweak(tweak_set)
    local gstate = managers.groupai and managers.groupai:state()
    if not (gstate and gstate._police) then
        return 0
    end

    local n = 0
    for _, rec in pairs(gstate._police) do
        local u = rec and rec.unit
        if alive(u) then
            local tn = _get_tweak_name(u)
            if tn and tweak_set[tn] then
                local dmg = u:character_damage()
                if dmg and not dmg:dead() then
                    n = n + 1
                end
            end
        end
    end

    return n
end

function ThreatAssessment.resolve_role_multiplier(tweak_name, flags, captain_suppressed)
    local roles = THREAT_WEIGHTS.ROLE_MULTIPLIERS

    if captain_suppressed and PHALANX_VIP_SET[tweak_name] then
        return THREAT_WEIGHTS.CAPTAIN_VIP_SUPPRESSED, "captain_suppressed"
    end

    local override = tweak_name
            and THREAT_WEIGHTS.TWEAK_MULTIPLIERS[tweak_name]
    if override then
        return override, tweak_name
    end

    if flags.dozer and flags.medic then
        return roles.DOZER_MEDIC, "dozer_medic"
    end

    local multiplier = flags.turret and roles.TURRET or roles.NORMAL
    local role_name = flags.turret and "turret" or "normal"
    local candidates = {
        { active = flags.shield, multiplier = roles.SHIELD, name = "shield" },
        { active = flags.dozer, multiplier = roles.DOZER, name = "dozer" },
        { active = flags.cloaker, multiplier = roles.CLOAKER, name = "cloaker" },
        { active = flags.boss, multiplier = roles.BOSS, name = "boss" },
        { active = flags.sniper, multiplier = roles.SNIPER, name = "sniper" },
        { active = flags.taser, multiplier = roles.TASER, name = "taser" },
        { active = flags.medic, multiplier = roles.MEDIC, name = "medic" },
    }

    for _, candidate in ipairs(candidates) do
        if candidate.active and candidate.multiplier > multiplier then
            multiplier = candidate.multiplier
            role_name = candidate.name
        end
    end

    if role_name == "normal" and flags.special then
        return roles.SPECIAL, "special"
    end

    return multiplier, role_name
end

function ThreatAssessment.get_role_multiplier(unit, target_data, flags)
    flags = flags or EnemyClassifier.classify(unit, target_data)
    local tweak_name = _get_tweak_name(unit)
    local captain_suppressed = PHALANX_VIP_SET[tweak_name]
            and ThreatAssessment.count_alive_with_tweak(PHALANX_MINION_SET) > 0
            or false
    local multiplier, role_name = ThreatAssessment.resolve_role_multiplier(
            tweak_name,
            flags,
            captain_suppressed
    )

    return multiplier, role_name, captain_suppressed
end

local function _calculate_log_multiplier(value, reference, weight, low, high)
    if not value or value <= 0 then
        return 1
    end

    local relative = value / reference
    local multiplier = 1 + weight * (math.log(relative) / LOG_TWO)
    return _clamp(multiplier, low, high)
end

function ThreatAssessment.calculate_health_multiplier(max_health, reference_health)
    return _calculate_log_multiplier(
            max_health,
            reference_health,
            THREAT_WEIGHTS.HEALTH_LOG_WEIGHT,
            THREAT_WEIGHTS.HEALTH_MUL_MIN,
            THREAT_WEIGHTS.HEALTH_MUL_MAX
    )
end

function ThreatAssessment.calculate_damage_multiplier(effective_damage, reference_damage)
    return _calculate_log_multiplier(
            effective_damage,
            reference_damage,
            THREAT_WEIGHTS.DAMAGE_LOG_WEIGHT,
            THREAT_WEIGHTS.DAMAGE_MUL_MIN,
            THREAT_WEIGHTS.DAMAGE_MUL_MAX
    )
end

function ThreatAssessment.calculate_adaptive_multiplier(
        max_health,
        reference_health,
        effective_damage,
        reference_damage
)
    local health_multiplier = ThreatAssessment.calculate_health_multiplier(
            max_health,
            reference_health
    )
    local damage_multiplier = ThreatAssessment.calculate_damage_multiplier(
            effective_damage,
            reference_damage
    )

    return _clamp(
            health_multiplier * damage_multiplier,
            THREAT_WEIGHTS.ADAPTIVE_MUL_MIN,
            THREAT_WEIGHTS.ADAPTIVE_MUL_MAX
    )
end

function ThreatAssessment.is_durable_from_metrics(
        flags,
        max_health,
        reference_health,
        health_ratio,
        captain_suppressed
)
    if captain_suppressed then
        return false
    elseif flags.turret then
        return true
    end

    if health_ratio and health_ratio <= CONSTANTS.LOW_HEALTH_RATIO then
        return false
    end

    if flags.dozer or flags.boss then
        return true
    end

    return max_health
            and max_health >= reference_health * CONSTANTS.DURABLE_HEALTH_REFERENCE_MUL
            or false
end

function ThreatAssessment.is_durable_target(unit, target_data, flags)
    if not alive(unit) then
        return false
    end

    flags = flags or EnemyClassifier.classify(unit, target_data)
    local tweak_name = _get_tweak_name(unit)
    local captain_suppressed = PHALANX_VIP_SET[tweak_name]
            and ThreatAssessment.count_alive_with_tweak(PHALANX_MINION_SET) > 0
            or false

    return ThreatAssessment.is_durable_from_metrics(
            flags,
            _get_max_health(unit),
            _get_reference_health(),
            _get_health_ratio(unit),
            captain_suppressed
    )
end

local function _calculate_tactical_multiplier(unit, data, flags, captain_suppressed)
    local multiplier = 1
    local health_ratio = _get_health_ratio(unit)
    local durable = ThreatAssessment.is_durable_from_metrics(
            flags,
            _get_max_health(unit),
            _get_reference_health(),
            1,
            captain_suppressed
    )

    if health_ratio and health_ratio < CONSTANTS.LOW_HEALTH_RATIO then
        multiplier = multiplier * (durable
                and CONSTANTS.DURABLE_LOW_HEALTH_THREAT_MUL
                or CONSTANTS.LOW_HEALTH_THREAT_MUL)
    end

    if _is_actively_firing(unit) then
        multiplier = multiplier * CONSTANTS.ACTIVE_FIRE_THREAT_MUL
    end

    local targets_me, targets_team = _get_targeting_state(unit, data)
    if targets_me then
        multiplier = multiplier * CONSTANTS.TARGETING_ME_THREAT_MUL
    elseif targets_team then
        multiplier = multiplier * CONSTANTS.TARGETING_TEAM_THREAT_MUL
    end

    return math.min(multiplier, CONSTANTS.TACTICAL_THREAT_MUL_MAX)
end

function ThreatAssessment.compose_threat_score(params)
    local distance = params.distance
    local flags = params.flags
    local threat = THREAT_WEIGHTS.DISTANCE_BASE / math.max(distance, 100)
    threat = threat * params.role_multiplier

    if params.captain_suppressed then
        return threat
    end

    threat = threat * params.adaptive_multiplier
    threat = threat * params.tactical_multiplier

    if flags.cloaker and distance < CONSTANTS.CLOAKER_CLOSE_RANGE then
        threat = threat * CONSTANTS.CLOAKER_CLOSE_MUL
    end

    if params.shield_blocked then
        threat = threat * THREAT_WEIGHTS.SHIELD_BLOCKED_PENALTY
    end

    if flags.tasing then
        threat = threat * CONSTANTS.TASING_THREAT_MUL
    end

    if flags.spooc_attack then
        threat = threat * CONSTANTS.SPOOC_THREAT_MUL
        if distance < CONSTANTS.SPOOC_CLOSE_RANGE then
            threat = threat * CONSTANTS.SPOOC_CLOSE_MUL
        end
    end

    return threat * ThreatAssessment.distance_falloff(distance, flags)
end

function ThreatAssessment.calculate_threat_value(bot_unit, target_data, data, target_distance, target_pos)
    if not (alive(bot_unit)
            and target_data
            and target_data.unit
            and alive(target_data.unit))
    then
        return 0
    end

    local bot_key = tostring(bot_unit:key())
    local target_key = tostring(target_data.unit:key())
    local cache_key = bot_key .. "_" .. target_key

    local cached = CoopCacheManager.threat_value:get(cache_key)
    if cached then
        return cached
    end

    local target_unit = target_data.unit
    local bot_mov = bot_unit:movement()
    if not bot_mov then
        return 0
    end
    local bot_head = bot_mov:m_head_pos()
    local dist = target_distance
            or target_data.verified_dis
            or (bot_head and target_data.m_head_pos and mvector3.distance(bot_head, target_data.m_head_pos))
            or 1000

    local flags = EnemyClassifier.classify(target_unit, target_data)
    local role_multiplier, _, captain_suppressed =
            ThreatAssessment.get_role_multiplier(target_unit, target_data, flags)
    local shield_blocked = false
    if flags.shield and not flags.turret and not captain_suppressed then
        local ap = CombatHelper.has_ap_ammo(bot_unit)
        local shield_pos = target_pos or target_data.m_head_pos
        local blocked = shield_pos and CombatHelper.shield_blocks_default(bot_unit, shield_pos)
        shield_blocked = blocked and not ap and dist > CONSTANTS.MELEE_DISTANCE or false
    end

    local reference_health = _get_reference_health()
    local adaptive_multiplier = ThreatAssessment.calculate_adaptive_multiplier(
            _get_max_health(target_unit),
            reference_health,
            _get_effective_damage(target_unit, target_data, dist),
            _get_reference_damage(dist)
    )
    local tactical_multiplier = captain_suppressed and 1
            or _calculate_tactical_multiplier(
                    target_unit,
                    data,
                    flags,
                    captain_suppressed
            )
    local threat = ThreatAssessment.compose_threat_score({
        distance = dist,
        flags = flags,
        role_multiplier = role_multiplier,
        adaptive_multiplier = adaptive_multiplier,
        tactical_multiplier = tactical_multiplier,
        shield_blocked = shield_blocked,
        captain_suppressed = captain_suppressed,
    })

    CoopCacheManager.threat_value:set(cache_key, threat, CONSTANTS.COOP_SCORE_CACHE_TTL)

    return threat
end

function ThreatAssessment.distance_falloff(dist, flags)
    if not flags.sniper and not flags.turret then
        if dist > CONSTANTS.DIST_FAR_THRESHOLD then
            return CONSTANTS.DIST_FAR_MUL
        elseif dist > CONSTANTS.DIST_MID_THRESHOLD then
            return CONSTANTS.DIST_MID_MUL
        elseif dist < CONSTANTS.DIST_CLOSE_THRESHOLD then
            return CONSTANTS.DIST_CLOSE_MUL
        end
    elseif flags.sniper and dist > CONSTANTS.DIST_MID_THRESHOLD then
        return CONSTANTS.SNIPER_FAR_MUL
    end
    return 1
end

function ThreatAssessment.calculate_suitability(bot_unit, target_data, target_pos, target_distance)
    if not (alive(bot_unit) and target_data and target_data.unit and alive(target_data.unit)) then
        return 0
    end

    local bot_key = tostring(bot_unit:key())
    local target_key = tostring(target_data.unit:key())
    local cache_key = bot_key .. "_" .. target_key

    local cached = CoopCacheManager.suitability:get(cache_key)
    if cached then
        return cached
    end

    local score = 100.0
    local bot_mov = bot_unit:movement()
    if not bot_mov then
        return 0
    end
    local bot_head = bot_mov:m_head_pos()

    local target_unit = target_data.unit
    local flags = EnemyClassifier.classify(target_unit, target_data)
    local tweak_name = _get_tweak_name(target_unit)

    if tweak_name
            and ENEMY_TWEAK_MAP[tweak_name]
            and ENEMY_TWEAK_MAP[tweak_name].captain
    then
        if PHALANX_VIP_SET[tweak_name]
                and ThreatAssessment.count_alive_with_tweak(PHALANX_MINION_SET) > 0
        then
            score = score - 200
        elseif PHALANX_MINION_SET[tweak_name] then
            score = score + 80
        end
    end

    local bot_fwd = bot_mov:m_head_fwd()
    if not bot_fwd then
        CoopCacheManager.suitability:set(cache_key, score, CONSTANTS.COOP_SCORE_CACHE_TTL)
        return score
    end
    local target_movement = target_unit.movement and target_unit:movement()
    target_pos = target_pos
            or target_data.m_head_pos
            or (target_movement
            and target_movement.m_head_pos
            and target_movement:m_head_pos())
    if not target_pos then
        CoopCacheManager.suitability:set(cache_key, score, CONSTANTS.COOP_SCORE_CACHE_TTL)
        return score
    end
    local dir_to_target = target_pos - bot_head

    mvector3.normalize(dir_to_target)
    local angle = mvector3.dot(dir_to_target, bot_fwd)
    score = score + (angle * 50)

    if flags.shield then
        local has_ap = CombatHelper.has_ap_ammo(bot_unit)
        if target_pos and (has_ap or not CombatHelper.shield_blocks_default(bot_unit, target_pos)) then
            score = score + 30
        else
            score = score - 80
        end
    end

    CoopCacheManager.suitability:set(cache_key, score, CONSTANTS.COOP_SCORE_CACHE_TTL)

    return score
end

BB.ThreatAssessment = ThreatAssessment
