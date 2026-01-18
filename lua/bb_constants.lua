local BB = _G.BB

local CONSTANTS = {
    GRACE_PERIOD = 10,
    INTIMIDATE_DISTANCE = 1200,
    INTIMIDATE_ANGLE = 90,
    MARK_DISTANCE = 3000,
    MELEE_DISTANCE = 200,
    MELEE_ANGLE = 60,
    CONC_DISTANCE = 3000,
    CONC_ANGLE = 90,
    CLUSTER_DISTANCE = 500,
    RELOAD_CHECK_INTERVAL = 1,
    MELEE_CHECK_INTERVAL = 0.5,
    CONC_COOLDOWN = 4,
    INTIMIDATE_COOLDOWN = 2,
    MARK_COOLDOWN = 2,
    INTIMIDATE_MAX_ATTEMPTS = 3,
    PRIORITY_TARGET_DURATION = 7,
    COOP_TEAMMATE_DANGER_RANGE = 1500,
    MAX_RELOADING_TEAMMATES = 1,
    PRIORITY_TARGET_CLAIM_TIMEOUT = 3,
    DOZER_FOCUS_REFRESH = 2,
    TARGET_SWITCH_DELAY = 1.5,
    COOP_REFRESH_INTERVAL = 0.4,
    TARGET_LOCK_MIN = 0.8,
}

local THREAT_WEIGHTS = {
    DISTANCE_BASE = 1000,
    CLOAKER = 100,
    TASER = 90,
    TASER_ACTIVE = 200,
    SHIELD = 60,
    DOZER = 80,
    MEDIC = 70,
    SNIPER = 75,
    SPECIAL = 65,
    TURRET = 85,
    LOW_HEALTH_BONUS = 50,
    TARGETING_ME_BONUS = 60,
    SAME_TARGET_PENALTY = 0.35,
    DIRECTION_BONUS = 30,
    CAPTAIN_MINION = 110,
    CAPTAIN_VIP_SUPPRESSED = 5,
    DOZER_MEDIC_SYNERGY = 25,
    SHIELD_BLOCKED_PENALTY = 0.2,
    TASING_BONUS = 120,
    SPOOC_ATTACK_BONUS = 140,
}

local SLOTS = {
    PLAYERS = { 2, 3, 4, 5 },
    CRIMINALS_NO_DEPLOYABLES = { 2, 3, 16 },
    HOSTAGES = 22,
    TURRETS = 25,
}

local ENEMY_TWEAK_MAP = {
    shield = { shield = true },
    fbi_shield = { shield = true },
    heavy_swat_shield = { shield = true },
    tank = { dozer = true },
    tank_medic = { dozer = true, medic = true },
    tank_hw = { dozer = true },
    tank_mini = { dozer = true },
    taser = { taser = true },
    spooc = { cloaker = true },
    medic = { medic = true },
    sniper = { sniper = true },
    phalanx_vip = { captain = true },
    phalanx_minion = { captain = true },
    phalanx_vip_test = { captain = true },
    swat_turret_gun = { turret = true },
}

BB.CONSTANTS = CONSTANTS
BB.THREAT_WEIGHTS = THREAT_WEIGHTS
BB.SLOTS = SLOTS
BB.ENEMY_TWEAK_MAP = ENEMY_TWEAK_MAP