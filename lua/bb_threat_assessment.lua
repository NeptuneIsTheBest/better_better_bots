local BB = _G.BB

local CONSTANTS = BB.CONSTANTS
local THREAT_WEIGHTS = BB.THREAT_WEIGHTS
local ENEMY_TWEAK_MAP = BB.ENEMY_TWEAK_MAP
local CoopCacheManager = BB.CoopCacheManager
local UnitOps = BB.UnitOps
local EnemyClassifier = BB.EnemyClassifier

local ThreatAssessment = {}

local function _get_tweak_name(u)
    local base = alive(u) and u:base()
    return base and base._tweak_table
end

local PHALANX_VIP_SET = { phalanx_vip = true, phalanx_vip_test = true }
local PHALANX_MINION_SET = { phalanx_minion = true }

local CombatHelper = BB.CombatHelper

function ThreatAssessment.get_weapon_archetype(unit)
    local inv = unit:inventory()
    local equipped_wep = inv and inv:equipped_unit()
    if not equipped_wep then
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
                if dmg and not (dmg:dead() or dmg._dead) then
                    n = n + 1
                end
            end
        end
    end

    return n
end

function ThreatAssessment.calculate_threat_value(bot_unit, target_data, data)
    if not (alive(bot_unit) and target_data and target_data.unit) then
        return 0
    end

    local bot_key = tostring(bot_unit:key())
    local target_key = tostring(target_data.unit:key())
    local cache_key = bot_key .. "_" .. target_key

    local cached = CoopCacheManager.threat_value:get(cache_key)
    if cached then
        if not alive(target_data.unit) then
            CoopCacheManager.threat_value:clear(cache_key)
        else
            return cached
        end
    end

    local target_unit = target_data.unit
    local bot_mov = bot_unit:movement()
    if not bot_mov then
        return 0
    end
    local bot_head = bot_mov:m_head_pos()
    local dist = target_data.verified_dis
            or (bot_head and target_data.m_head_pos and mvector3.distance(bot_head, target_data.m_head_pos))
            or 1000

    local flags = EnemyClassifier.classify(target_unit, target_data)
    local tweak_name = _get_tweak_name(target_unit)
    local role_map = tweak_name and ENEMY_TWEAK_MAP[tweak_name]

    local threat = THREAT_WEIGHTS.DISTANCE_BASE / math.max(dist, 100)

    if role_map and role_map.captain then
        if PHALANX_VIP_SET[tweak_name] then
            local minions_alive = ThreatAssessment.count_alive_with_tweak(PHALANX_MINION_SET)
            if minions_alive > 0 then
                return threat * (THREAT_WEIGHTS.CAPTAIN_VIP_SUPPRESSED / 10)
            end

            threat = threat * (THREAT_WEIGHTS.SPECIAL / 10)
        else
            threat = threat * (THREAT_WEIGHTS.CAPTAIN_MINION / 10)
        end
    end

    local threat_modifiers = {
        { flag = flags.turret, weight = THREAT_WEIGHTS.TURRET },
        { flag = flags.dozer, weight = THREAT_WEIGHTS.DOZER },
        { flag = flags.taser, weight = THREAT_WEIGHTS.TASER },
        { flag = flags.cloaker, weight = THREAT_WEIGHTS.CLOAKER, distance_bonus = dist < 1200 and 2.0 },
        { flag = flags.medic, weight = THREAT_WEIGHTS.MEDIC },
        { flag = flags.sniper, weight = THREAT_WEIGHTS.SNIPER },
    }

    for _, modifier in ipairs(threat_modifiers) do
        if modifier.flag then
            threat = threat * (modifier.weight / 10)
            if modifier.distance_bonus then
                threat = threat * modifier.distance_bonus
            end
        end
    end

    if flags.dozer and flags.medic then
        threat = threat * (1 + (THREAT_WEIGHTS.DOZER_MEDIC_SYNERGY / 100))
    end

    local hr = UnitOps.health_ratio(target_unit)

    if flags.dozer then
        if hr < CONSTANTS.LOW_HEALTH_RATIO then
            threat = threat * CONSTANTS.DOZER_LOW_HEALTH_MUL
        end
    end

    if flags.shield and not flags.turret then
        local ap = CombatHelper.has_ap_ammo()
        local blocked = target_data.m_head_pos and CombatHelper.shield_blocks_default(bot_unit, target_data.m_head_pos)

        if blocked and (not ap) and dist > CONSTANTS.MELEE_DISTANCE then
            threat = threat * THREAT_WEIGHTS.SHIELD_BLOCKED_PENALTY
        else
            threat = threat * (THREAT_WEIGHTS.SHIELD / 10)
        end
    end

    if not flags.turret then
        if hr < CONSTANTS.LOW_HEALTH_RATIO then
            threat = threat + THREAT_WEIGHTS.LOW_HEALTH_BONUS
        end

        local enemy_brain = target_unit:brain()
        local enemy_data = enemy_brain and enemy_brain._logic_data
        if enemy_data and enemy_data.attention_obj and enemy_data.attention_obj.u_key == data.key then
            threat = threat + THREAT_WEIGHTS.TARGETING_ME_BONUS
        end
    end

    threat = threat * ThreatAssessment.distance_falloff(dist, flags)

    CoopCacheManager.threat_value:set(cache_key, threat, 0.3)

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

function ThreatAssessment.calculate_suitability(bot_unit, target_data)
    if not (alive(bot_unit) and target_data and target_data.unit and alive(target_data.unit)) then
        return 0
    end

    local bot_key = tostring(bot_unit:key())
    local target_key = tostring(target_data.unit:key())
    local cache_key = bot_key .. "_" .. target_key

    local cached = CoopCacheManager.suitability:get(cache_key)
    if cached then
        if not alive(target_data.unit) then
            CoopCacheManager.suitability:clear(cache_key)
        else
            return cached
        end
    end

    local score = 100.0
    local bot_mov = bot_unit:movement()
    if not bot_mov then
        return 0
    end
    local bot_head = bot_mov:m_head_pos()
    local dist = target_data.verified_dis
            or (bot_head and target_data.m_head_pos and mvector3.distance(bot_head, target_data.m_head_pos))
            or 1000

    local target_unit = target_data.unit
    local flags = EnemyClassifier.classify(target_unit, target_data)
    local tweak_name = _get_tweak_name(target_unit)

    if flags.turret then
        score = score + 10
        if dist < 1500 then
            score = score + 10
        end
    end

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

    local bot_rot = bot_mov:m_head_rot()
    local bot_fwd = bot_rot and bot_rot:y()
    if not bot_fwd then
        CoopCacheManager.suitability:set(cache_key, score, 0.3)
        return score
    end
    local target_pos = target_data.m_head_pos
            or (target_unit:movement() and target_unit:movement():m_head_pos())
    if not target_pos then
        CoopCacheManager.suitability:set(cache_key, score, 0.3)
        return score
    end
    local dir_to_target = target_pos - bot_head

    mvector3.normalize(dir_to_target)
    local angle = mvector3.dot(dir_to_target, bot_fwd)
    score = score + (angle * 50)

    if not target_data.verified then
        score = score * 0.7
    end

    if flags.shield then
        local has_ap = CombatHelper.has_ap_ammo()
        if target_data.m_head_pos and (has_ap or not CombatHelper.shield_blocks_default(bot_unit, target_data.m_head_pos)) then
            score = score + 30
        else
            score = score - 80
        end
    end

    CoopCacheManager.suitability:set(cache_key, score, 0.3)

    return score
end

BB.ThreatAssessment = ThreatAssessment
