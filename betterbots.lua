_G.BB = _G.BB or {}

do
	if ((getmetatable(_G) or {}).__index or {}).managers == nil then
		local t = { managers = managers, __index = { managers = managers } }
		setmetatable(_G, setmetatable(t, getmetatable(_G)))
	end
end

local BB = _G.BB

local function _get_mask(name, fallback_slots)
	if managers and managers.slot and managers.slot.get_mask then
		local ok, m = pcall(managers.slot.get_mask, managers.slot, name)
		if ok and m then
			return m
		end
	end

	if fallback_slots == nil then
		return World:make_slot_mask()
	end
	if type(fallback_slots) == "table" then
		return World:make_slot_mask(unpack(fallback_slots))
	elseif type(fallback_slots) == "number" then
		return World:make_slot_mask(fallback_slots)
	else
		return World:make_slot_mask()
	end
end

local MASK = {
	AI_visibility = _get_mask("AI_visibility", {1, 11, 38, 39}),
	enemy_shield_check = _get_mask("enemy_shield_check", 8),
	hostages = _get_mask("hostages", 22),
	players = _get_mask("players", {2, 3, 4, 5}),
	criminals_no_deployables = _get_mask("criminals_no_deployables", {2, 3, 16})
}

local SLOTS = {
	HOSTAGES = 22
}

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
}

BB._path = ModPath
BB._data_path = SavePath .. "bb_data.txt"
BB._data = BB._data or {}
BB.cops_to_intimidate = BB.cops_to_intimidate or {}
BB.grace_period = BB.grace_period or CONSTANTS.GRACE_PERIOD

local function bb_log(msg, level)
	log(string.format("[Better Bots][%s] %s", level or "INFO", tostring(msg)))
end

local function safe_call(func, ...)
	if type(func) ~= "function" then return end
	local success, result = pcall(func, ...)
	if not success then
		bb_log("Error: " .. tostring(result), "ERROR")
	end
	return result
end

local function clamp(x, a, b)
	return math.min(math.max(x, a), b)
end

local function as_bool_from_item(item)
	return item and item:value() == "on"
end

local function as_number_from_item(item, fallback)
	local v = item and tonumber(item:value())
	return v or fallback
end

local function unit_team(unit)
	if not alive(unit) then return nil end
	local mov = unit:movement()
	return mov and mov.team and mov:team()
end

local function is_team_ai(unit)
	return alive(unit) and managers.groupai and managers.groupai:state() 
		and managers.groupai:state():is_unit_team_AI(unit) or false
end

local function are_units_foes(a, b)
	local ta, tb = unit_team(a), unit_team(b)
	if not ta or not tb then return false end
	return ta.foes and ta.foes[tb.id] or false
end

local function is_law_unit(unit)
	local t = unit_team(unit)
	return t and t.id == "law1"
end

local function get_unit_health_ratio(unit)
	if not alive(unit) then return 0 end
	local damage = unit:character_damage()
	return damage and damage.health_ratio and damage:health_ratio() or 0
end

function BB:Save()
	local ok, encoded = pcall(json.encode, self._data)
	if not ok then
		bb_log("Failed to encode save data", "ERROR")
		return
	end
	
	local file = io.open(self._data_path, "w")
	if file then
		file:write(encoded)
		file:close()
		bb_log("Data saved")
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
	
	local ok, decoded = pcall(json.decode, raw)
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

BB:Load()

Hooks:Add("LocalizationManagerPostInit", "LocalizationManagerPostInit_BB", function(loc)
	if not loc then
		bb_log("LocalizationManager is nil", "WARN")
		return
	end
	
	local loc_dir = BB._path .. "loc/"
	local files_ok, files = pcall(file.GetFiles, loc_dir)
	
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

Hooks:Add("MenuManagerInitialize", "MenuManagerInitialize_BB", function(menu_manager)
	if not menu_manager then
		bb_log("MenuManager is nil", "WARN")
		return
	end
	
	local function register_toggle(cb_name, key)
		MenuCallbackHandler[cb_name] = function(self, item)
			BB._data[key] = as_bool_from_item(item)
			BB:Save()
		end
	end
	
	local function register_choice(cb_name, key, default_num)
		MenuCallbackHandler[cb_name] = function(self, item)
			BB._data[key] = as_number_from_item(item, default_num)
			BB:Save()
		end
	end

	register_choice("callback_health_choice", "health", 1)
	register_choice("callback_move_choice", "move", 1)
	register_choice("callback_dodge_choice", "dodge", 4)
	register_choice("callback_dmgmul_choice", "dmgmul", 5)

	register_toggle("callback_firemode_toggle", "firemode")
	register_toggle("callback_dwn_toggle", "instadwn")
	register_toggle("callback_clk_toggle", "clkarrest")
	register_toggle("callback_chat_toggle", "chat")
	register_toggle("callback_doc_toggle", "doc")
	register_toggle("callback_dom_toggle", "dom")
	register_toggle("callback_biglob_toggle", "biglob")
	register_toggle("callback_reflex_toggle", "reflex")
	register_toggle("callback_maskup_toggle", "maskup")
	register_toggle("callback_equip_toggle", "equip")
	register_toggle("callback_combat_toggle", "combat")
	register_toggle("callback_ammo_toggle", "ammo")
	register_toggle("callback_conc_toggle", "conc")

	BB:Load()
	
	if MenuHelper and MenuHelper.LoadFromJsonFile then
		MenuHelper:LoadFromJsonFile(BB._path .. "menu.txt", BB, BB._data)
	else
		bb_log("MenuHelper not found", "WARN")
	end
end)

function BB:add_cop_to_intimidation_list(unit_key)
	if not unit_key or not TimerManager or not TimerManager:game() then return end
	
	local t = TimerManager:game():time()
	local prev_t = self.cops_to_intimidate[unit_key]
	self.cops_to_intimidate[unit_key] = t

	if not Network:is_server() then return end
	
	local is_new = not prev_t or (t - prev_t) > self.grace_period
	if not is_new then return end
	
	local gstate = managers.groupai and managers.groupai:state()
	if not gstate then return end
	
	local function clear_attention_for_unit(unit)
		if not alive(unit) then return end
		local brain = unit:brain()
		if not brain or not brain._logic_data then return end
		
		local att_obj = brain._logic_data.attention_obj
		if att_obj and att_obj.u_key == unit_key then
			if CopLogicBase and CopLogicBase._set_attention_obj then
				CopLogicBase._set_attention_obj(brain._logic_data)
			end
		end
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

if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
	local is_server = Network:is_server()

	if BB:get("conc", false) and is_server then
		local old_init = GroupAIStateBase.init
		function GroupAIStateBase:init(...)
			if tweak_data.blackmarket and tweak_data.blackmarket.projectiles then
				local conc_data = tweak_data.blackmarket.projectiles.concussion
				if conc_data and conc_data.unit then
					local unit_name = Idstring(conc_data.unit)
					local dyn_res = managers.dyn_resource
					if dyn_res and not dyn_res:is_resource_ready(Idstring("unit"), unit_name, dyn_res.DYN_RESOURCES_PACKAGE) then
						safe_call(dyn_res.load, dyn_res, Idstring("unit"), unit_name, dyn_res.DYN_RESOURCES_PACKAGE)
					end
				end
			end
			return old_init(self, ...)
		end
	end

    if BB:get("chat", false) then
        local old_chatter = GroupAIStateBase.chk_say_teamAI_combat_chatter
        function GroupAIStateBase:chk_say_teamAI_combat_chatter(...)
            if BB:get("chat", false) then
                return
            end
            return old_chatter(self, ...)
        end
    end

	local old_tase = GroupAIStateBase.on_tase_start
	function GroupAIStateBase:on_tase_start(cop_key, criminal_key, ...)
		if self._ai_criminals then
			local bot_record = self._ai_criminals[criminal_key]
			if bot_record and bot_record.unit then
				local cop_data = self._police and self._police[cop_key]
				local taser_unit = cop_data and cop_data.unit
				
				if alive(taser_unit) then
					local contour = taser_unit:contour()
					if contour and managers.player then
						local mark_id = managers.player:get_contour_for_marked_enemy()
						if not contour._contour_list or not contour:has_id(mark_id) then
							if alive(bot_record.unit) and bot_record.unit:sound() then
								safe_call(bot_record.unit:sound().say, bot_record.unit:sound(), "f32x_any", true)
							end
							safe_call(contour.add, contour, "mark_enemy", true)
						end
					end
				end
			end
		end
		return old_tase(self, cop_key, criminal_key, ...)
	end

	function GroupAIStateBase:_get_balancing_multiplier(balance_multipliers, ...)
		local nr_crim = 0
		for _, u_data in pairs(self:all_char_criminals() or {}) do
			if not u_data.status then
				nr_crim = nr_crim + 1
			end
		end
		nr_crim = clamp(nr_crim, 1, 4)
		return balance_multipliers and balance_multipliers[nr_crim] or 1
	end
end

if RequiredScript == "lib/units/player_team/teamaibase" then
	local is_server = Network:is_server()
	
	local old_post = TeamAIBase.post_init
	function TeamAIBase:post_init(...)
		old_post(self, ...)
		self._upgrades = self._upgrades or {}
		self._upgrade_levels = self._upgrade_levels or {}
		
		if is_server then
			local upgrades = {
				"intimidate_enemies", "empowered_intimidation_mul", "intimidation_multiplier",
				"civ_calming_alerts", "intimidate_aura", "civ_intimidation_mul"
			}
			for _, upgrade in ipairs(upgrades) do
				self:set_upgrade_value("player", upgrade, 1)
			end
		end
	end
	
	function TeamAIBase:set_upgrade_value(category, upgrade, level)
		if HuskPlayerBase and HuskPlayerBase.set_upgrade_value then
			HuskPlayerBase.set_upgrade_value(self, category, upgrade, level)
		end
	end
	
	function TeamAIBase:upgrade_value(category, upgrade)
		return self._upgrades and self._upgrades[category] and self._upgrades[category][upgrade]
	end
	
	function TeamAIBase:upgrade_level(category, upgrade)
		return self._upgrade_levels and self._upgrade_levels[category] and self._upgrade_levels[category][upgrade]
	end
end

if RequiredScript == "lib/units/player_team/teamaidamage" then
	if BB:get("doc", false) then
		local old_damage = TeamAIDamage._apply_damage
		function TeamAIDamage:_apply_damage(...)
			local damage_percent, health_subtracted = old_damage(self, ...)
			if not self._unit then return damage_percent, health_subtracted end
			
			local brain = self._unit:brain()
			if not brain or not brain._logic_data then return damage_percent, health_subtracted end
			
			local my_data = brain._logic_data.internal_data
			if my_data and not my_data.said_hurt then
				if self._health_ratio and self._health_ratio <= 0.2 and not self:need_revive() then
					my_data.said_hurt = true
					if self._unit:sound() then
						safe_call(self._unit:sound().say, self._unit:sound(), "g80x_plu", true)
					end
				end
			end
			return damage_percent, health_subtracted
		end

		local old_regen = TeamAIDamage._regenerated
		function TeamAIDamage:_regenerated()
			if self._unit then
				local brain = self._unit:brain()
				if brain and brain._logic_data then
					local my_data = brain._logic_data.internal_data
					if my_data then
						my_data.said_hurt = false
					end
				end
			end
			return old_regen(self)
		end
	end

    local old_ff_hit = TeamAIDamage.friendly_fire_hit
    function TeamAIDamage:friendly_fire_hit()
        return
    end
end

if RequiredScript == "lib/units/interactions/interactionext" then
	if Network:is_server() then
		local function cancel_other_rescue_objectives(revive_unit, rescuer)
			if not alive(revive_unit) or not alive(rescuer) then return end
			
			local gstate = managers.groupai and managers.groupai:state()
			if not gstate then return end
			
			local revive_key = revive_unit:key()
			local rescuer_key = rescuer:key()
			
			for u_key, u_data in pairs(gstate:all_AI_criminals() or {}) do
				if u_key ~= rescuer_key then
					local unit = u_data.unit
					if alive(unit) then
						local brain = unit:brain()
						if brain and brain._logic_data then
							local obj = brain._logic_data.objective
							if obj and obj.type == "revive" then
								local follow_unit = obj.follow_unit
								if alive(follow_unit) and follow_unit:key() == revive_key then
									brain:set_objective()
								end
							end
						end
					end
				end
			end
		end

		local old_start = ReviveInteractionExt._at_interact_start
		function ReviveInteractionExt:_at_interact_start(player, ...)
			old_start(self, player, ...)
			if self.tweak_data == "revive" or self.tweak_data == "free" then
				cancel_other_rescue_objectives(self._unit, player)
			end
		end
	end
end

if RequiredScript == "lib/tweak_data/weapontweakdata" then
	if BB:get("combat", false) then
		local old_init = WeaponTweakData.init
		function WeaponTweakData:init(...)
			old_init(self, ...)
			
			for k, v in pairs(self) do
				if type(v) == "table" and k:match("_crew$") then
					v.DAMAGE = 3
					if v.auto and v.auto.fire_rate then
						v.auto.fire_rate = 0.2
					end
				end
			end

			local weapon_configs = {
				{ name = "m14_crew", usage = "is_pistol", anim_usage = "is_rifle" },
				{ name = "contraband_crew", usage = "is_pistol", anim_usage = "is_rifle" },
				{ name = "sub2000_crew", usage = "is_pistol" },
				{ name = "spas12_crew", usage = "is_shotgun_mag", anim_usage = "is_shotgun_pump" },
				{ name = "ben_crew", usage = "is_shotgun_mag", anim_usage = "is_shotgun_pump" },
				{ name = "ching_crew", usage = "is_pistol", anim_usage = "is_rifle" },
				{ name = "m95_crew", usage = "rifle", anim_usage = "is_bullpup" }
			}
			
			for _, config in ipairs(weapon_configs) do
				if self[config.name] then
					self[config.name].usage = config.usage
					if config.anim_usage then
						self[config.name].anim_usage = config.anim_usage
					end
				end
			end
		end
	end
end

if RequiredScript == "lib/managers/criminalsmanager" then
	local is_offline = Global and Global.game_settings and Global.game_settings.single_player
	local is_server = Network:is_server()
	local total_chars = CriminalsManager.get_num_characters and CriminalsManager.get_num_characters() or 4
	
	if BB:get("biglob", false) then
		CriminalsManager.MAX_NR_TEAM_AI = total_chars
	end

	if tweak_data and tweak_data.character and tweak_data.character.presets then
		local char_preset = tweak_data.character.presets

		local health_options = { nil, 75, 144 }
		local dodge_options = { "poor", "average", "heavy", "athletic", "ninja" }

		if char_preset.gang_member_damage then
			local health_idx = BB:get("health", 1)
			if health_options[health_idx] then
				char_preset.gang_member_damage.HEALTH_INIT = health_options[health_idx]
			end
			if BB:get("instadwn", false) then
				char_preset.gang_member_damage.DOWNED_TIME = 0
			end
		end

		local gang_weapon = char_preset.weapon and (char_preset.weapon.bot_weapons or char_preset.weapon.gang_member)
		if gang_weapon then
			local dodge_idx = BB:get("dodge", 4)
			local dodge_preset = dodge_options[dodge_idx]
			local damage_mul = BB:get("dmgmul", 5)

			for _, v in pairs(gang_weapon) do
				v.focus_delay = 0
				v.aim_delay = { 0, 0 }
				v.RELOAD_SPEED = 1
				
				if char_preset.weapon and char_preset.weapon.sniper and char_preset.weapon.sniper.is_rifle then
					v.range = deep_clone(char_preset.weapon.sniper.is_rifle.range)
				end
				
				if BB:get("combat", false) then
					v.spread = 5
					v.FALLOFF = {
						{ r = 1500, acc = {1, 1}, dmg_mul = damage_mul, recoil = {0.2, 0.2}, mode = {0, 0, 0, 1} },
						{ r = 4500, acc = {1, 1}, dmg_mul = 1, recoil = {2, 2}, mode = {0, 0, 0, 1} }
					}
				end
			end

			for _, v in pairs(tweak_data.character) do
				if type(v) == "table" and v.access == "teamAI1" then
					v.no_run_start = true
					v.no_run_stop = true
					v.always_face_enemy = true
					
					if char_preset.hurt_severities and char_preset.hurt_severities.only_light_hurt then
						v.damage = v.damage or {}
						v.damage.hurt_severity = char_preset.hurt_severities.only_light_hurt
					end
					
					if is_server and char_preset.move_speed and char_preset.move_speed.lightning then
						v.move_speed = char_preset.move_speed.lightning
					end

					local move_choice = BB:get("move", 1)
					if move_choice == 2 and dodge_preset and char_preset.dodge and char_preset.dodge[dodge_preset] then
						v.dodge = char_preset.dodge[dodge_preset]
					elseif move_choice == 3 then
						v.allowed_poses = { stand = true }
					end

					local orig_weapons = v.weapon and v.weapon.weapons_of_choice
					v.weapon = deep_clone(gang_weapon)
					if orig_weapons then
						v.weapon.weapons_of_choice = orig_weapons
					end

					if BB:get("combat", false) then
						if v.weapon.is_sniper and v.weapon.is_sniper.FALLOFF and v.weapon.is_sniper.FALLOFF[1] then
							v.weapon.is_sniper.FALLOFF[1].dmg_mul = damage_mul * 5
							v.weapon.is_sniper.FALLOFF[1].recoil = {1, 1}
						end
						if v.weapon.is_shotgun_pump and v.weapon.is_shotgun_pump.FALLOFF and v.weapon.is_shotgun_pump.FALLOFF[1] then
							v.weapon.is_shotgun_pump.FALLOFF[1].dmg_mul = damage_mul * 2.5
							v.weapon.is_shotgun_pump.FALLOFF[1].recoil = {0.5, 0.5}
						end
						if v.weapon.rifle and v.weapon.rifle.FALLOFF and v.weapon.rifle.FALLOFF[1] then
							v.weapon.rifle.FALLOFF[1].dmg_mul = damage_mul * 10
							v.weapon.rifle.FALLOFF[1].recoil = {2, 2}
						end
					end
				end
			end
		end
	end

	if is_offline and not BB:get("biglob", false) then
		local old_color = CriminalsManager.character_color_id_by_unit
		function CriminalsManager:character_color_id_by_unit(unit, ...)
			local char_data = self:character_data_by_unit(unit)
			if char_data and char_data.ai then
				char_data.ai_id = char_data.ai_id or (self:nr_AI_criminals() + 1)
				return char_data.ai_id
			end
			return old_color(self, unit, ...)
		end
	end
end

if RequiredScript == "lib/tweak_data/playertweakdata" then
    local old_set_sp = PlayerTweakData._set_singleplayer
    function PlayerTweakData:_set_singleplayer(...)
        return
    end
end

local function remove_ai_from_bullet_mask(self, setup_data)
	if not World then return end

	local user_unit = setup_data and setup_data.user_unit
	if alive(user_unit) and is_team_ai(user_unit) and self._bullet_slotmask then
		local ai_friends_mask = (MASK.criminals_no_deployables - MASK.players) + MASK.hostages
		self._bullet_slotmask = self._bullet_slotmask - ai_friends_mask
	end
end

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then
	local old_setup = NewNPCRaycastWeaponBase.setup
	function NewNPCRaycastWeaponBase:setup(setup_data, ...)
		old_setup(self, setup_data, ...)
		remove_ai_from_bullet_mask(self, setup_data)
	end
end

if RequiredScript == "lib/units/weapons/npcraycastweaponbase" then
	local old_setup = NPCRaycastWeaponBase.setup
	function NPCRaycastWeaponBase:setup(setup_data, ...)
		old_setup(self, setup_data, ...)
		remove_ai_from_bullet_mask(self, setup_data)
	end
end

if RequiredScript == "lib/units/player_team/teamaimovement" then
	if BB:get("clkarrest", false) then
		local settings = Global and Global.game_settings
		local is_private = settings and settings.permission and settings.permission ~= "public"
		local is_offline = settings and settings.single_player
		
		local old_spooc = TeamAIMovement.on_SPOOCed
		function TeamAIMovement:on_SPOOCed(...)
			if is_private or is_offline then
				return self:on_cuffed()
			end
			return old_spooc(self, ...)
		end
	end

	if not BotWeapons then
		if HuskPlayerMovement then
			TeamAIMovement.set_visual_carry = HuskPlayerMovement.set_visual_carry
			TeamAIMovement._destroy_current_carry_unit = HuskPlayerMovement._destroy_current_carry_unit
			TeamAIMovement._create_carry_unit = HuskPlayerMovement._create_carry_unit
		end

		if not BB:get("equip", false) then
			function TeamAIMovement:check_visual_equipment()
				if not tweak_data.levels or not managers.job then return end
				
				local level_id = tweak_data.levels[managers.job:current_level_id()]
				local bags = { {g_medicbag = true}, {g_ammobag = true} }
				local bag = bags[math.random(#bags)]
				
				for k, v in pairs(bag) do
					local mesh_obj = self._unit:get_object(Idstring(k))
					if mesh_obj then
						mesh_obj:set_visibility(v)
					end
				end
				
				if level_id and not level_id.player_sequence and self._unit:damage() then
					safe_call(self._unit:damage().run_sequence_simple, self._unit:damage(), "var_model_02")
				end
			end
		end

		local old_set = TeamAIMovement.set_carrying_bag
		function TeamAIMovement:set_carrying_bag(unit, ...)
			if not managers.hud then return old_set(self, unit, ...) end
			
			local bag_unit = unit or self._carry_unit
			
			if unit and unit:carry_data() then
				self:set_visual_carry(unit:carry_data():carry_id())
			else
				self:set_visual_carry(nil)
			end
			
			if alive(bag_unit) then
				bag_unit:set_visible(not unit)
			end
			
			local name_label_id = self._unit and self._unit:unit_data() and self._unit:unit_data().name_label_id
			local name_label = name_label_id and managers.hud:_get_name_label(name_label_id)
			if name_label and name_label.panel then
				local bag_panel = name_label.panel:child("bag")
				if bag_panel then
					bag_panel:set_visible(unit and true or false)
				end
			end
			
			return old_set(self, unit, ...)
		end
	end

	local old_throw = TeamAIMovement.throw_bag
	function TeamAIMovement:throw_bag(...)
		if self:carrying_bag() then
			local carry_tweak = self:carry_tweak()
			if carry_tweak and managers.player then
				local data = self._ext_brain and self._ext_brain._logic_data
				local objective = data and data.objective
				
				if objective and objective.type == "revive" then
					local no_cooldown = managers.player:is_custom_cooldown_not_active("team", "crew_inspire")
					if no_cooldown or carry_tweak.can_run then
						return
					end
				end
			end
		end
		return old_throw(self, ...)
	end
end

if RequiredScript == "lib/units/player_team/actions/lower_body/criminalactionwalk" then
	function CriminalActionWalk:init(...)
		if CriminalActionWalk.super and CriminalActionWalk.super.init then
			return CriminalActionWalk.super.init(self, ...)
		end
	end

	local function get_bag_speed_modifier(ext_movement)
		if not ext_movement or not ext_movement:carrying_bag() then return 1 end
		
		local carry_id = ext_movement:carry_id()
		if not carry_id or not tweak_data.carry then return 1 end
		
		local carry_td = tweak_data.carry[carry_id]
		if not carry_td then return 1 end
		
		local carry_type = carry_td.type
		if carry_type and tweak_data.carry.types and tweak_data.carry.types[carry_type] then
			local move_mod = tweak_data.carry.types[carry_type].move_speed_modifier or 1
			return math.min(1, move_mod * 1.5)
		end
		
		return 1
	end

	function CriminalActionWalk:_get_max_walk_speed(...)
		if not CriminalActionWalk.super or not CriminalActionWalk.super._get_max_walk_speed then
			return { 150 }
		end
		
		local speed = deep_clone(CriminalActionWalk.super._get_max_walk_speed(self, ...))
		local mod = get_bag_speed_modifier(self._ext_movement)
		
		for i = 1, #speed do
			speed[i] = speed[i] * mod
		end
		
		return speed
	end

	function CriminalActionWalk:_get_current_max_walk_speed(move_dir, ...)
		if not CriminalActionWalk.super or not CriminalActionWalk.super._get_current_max_walk_speed then
			return 150
		end
		
		local speed = CriminalActionWalk.super._get_current_max_walk_speed(self, move_dir, ...)
		return speed * get_bag_speed_modifier(self._ext_movement)
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
	local mvec3_norm = mvector3.normalize
	local mvec3_angle = mvector3.angle
	local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

	function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
		local best_target, best_priority, best_reaction
		local att_obj = data.attention_obj
		local unit = data.unit
		
		if not alive(unit) or not unit:movement() then
			return nil, nil, nil
		end
		
		local head_pos = unit:movement():m_head_pos()
		local is_team_ai = managers.groupai and managers.groupai:state():is_unit_team_AI(unit)
		local has_ap = is_team_ai and managers.player and managers.player:has_category_upgrade("team", "crew_ai_ap_ammo")

		local ammo_ratio = 1
		local current_wep = unit:inventory() and unit:inventory():equipped_unit()
		if current_wep and current_wep:base() then
			local ammo_max, ammo = current_wep:base():ammo_info()
			if ammo_max and ammo_max > 0 then
				ammo_ratio = ammo / ammo_max
			end
		end
		
		for u_key, attention_data in pairs(attention_objects or {}) do
			if attention_data.identified then
				local att_unit = attention_data.unit
				if alive(att_unit) then
					local reaction = attention_data.reaction or AIAttentionObject.REACT_IDLE
					if reaction >= REACT_COMBAT then
						local target_priority = attention_data.verified_dis
						if target_priority then
							local priority_mod = 1
							local threat_level = 1
							
							if attention_data.verified then
								local char_tweak = attention_data.char_tweak
								
								local enemy_brain = att_unit:brain()
								local enemy_data = enemy_brain and enemy_brain._logic_data
								if enemy_data then
									local enemy_att = enemy_data.attention_obj
									if enemy_att and enemy_att.u_key == data.key then
										threat_level = threat_level * 1.5
									end
								end
								
								local health_ratio = get_unit_health_ratio(att_unit)
								if health_ratio <= 0.3 then
									threat_level = threat_level * 0.7
									if enemy_data and enemy_data.attention_obj and enemy_data.attention_obj.u_key == data.key then
										threat_level = threat_level * 1.5
									end
								end
								
								if att_obj and att_obj.u_key == u_key then
									priority_mod = 10 * threat_level
								elseif char_tweak then
									local special_shout = char_tweak.priority_shout
									if special_shout then
										local can_heal = att_unit:base() and att_unit:base():has_tag("medic")
										if special_shout == "f34" then
											priority_mod = 9 * threat_level
										elseif can_heal then
											priority_mod = 8 * threat_level
										elseif attention_data.is_very_dangerous then
											priority_mod = 7 * threat_level
										elseif attention_data.is_shield then
											local is_shielded = World:raycast("ray", head_pos, attention_data.m_head_pos, "ignore_unit", {unit}, "slot_mask", MASK.enemy_shield_check)
											local melee_range = is_team_ai and target_priority <= CONSTANTS.MELEE_DISTANCE
											if has_ap or melee_range or not is_shielded then
												priority_mod = 6 * threat_level
											else
												priority_mod = 2
											end
										else
											priority_mod = 5 * threat_level
										end
									else
										priority_mod = 4 * threat_level
									end
								else
									priority_mod = 3 * threat_level
								end
							end
							
							if ammo_ratio < 0.3 and target_priority > 1000 then
								priority_mod = priority_mod * 0.5
							end

							target_priority = target_priority / priority_mod
							
							if not best_priority or best_priority > target_priority then
								local cop_key_time = BB.cops_to_intimidate[u_key]
								local intimidation_in_progress = cop_key_time and data.t - cop_key_time < BB.grace_period
								
								if not intimidation_in_progress then
									best_target = attention_data
									best_priority = target_priority
									best_reaction = reaction
								end
							end
						end
					end
				end
			end
		end
		
		return best_target, best_priority, best_reaction
	end

	function TeamAILogicIdle._find_intimidateable_civilians(criminal, use_default_shout_shape, max_angle, max_dis)
		if not alive(criminal) or not managers.enemy then
			return nil, 1, {}
		end
		
		max_angle = use_default_shout_shape and CONSTANTS.INTIMIDATE_ANGLE or (max_angle or CONSTANTS.INTIMIDATE_ANGLE)
		max_dis = use_default_shout_shape and CONSTANTS.INTIMIDATE_DISTANCE or (max_dis or CONSTANTS.INTIMIDATE_DISTANCE)
		
		local crim_mov = criminal:movement()
		if not crim_mov then return nil, 1, {} end
		
		local head_pos = crim_mov:m_head_pos()
		local look_vec = crim_mov:m_rot():y()
		local my_tracker = crim_mov:nav_tracker()
		if not my_tracker then return nil, 1, {} end
		
		local best_civ
		local intimidateable_civilians = {}
		local chk_vis_func = my_tracker.check_visibility
		local slotmask = managers.slot:get_mask("AI_visibility")
		
		for u_key, u_char in pairs(managers.enemy:all_civilians() or {}) do
			if u_char.tracker and chk_vis_func(my_tracker, u_char.tracker) then
				local unit = u_char.unit
				if alive(unit) then
					local unit_mov = unit:movement()
					if unit_mov then
						local u_head_pos = unit_mov:m_head_pos()
						local vec = u_head_pos - head_pos
						
						if mvec3_norm(vec) <= max_dis and mvec3_angle(vec, look_vec) <= max_angle then
							local ray = World:raycast("ray", head_pos, u_head_pos, "slot_mask", slotmask, "ray_type", "ai_vision")
							
							if not ray and u_char.char_tweak and u_char.char_tweak.intimidateable then
								local unit_base = unit:base()
								if not (unit_base and unit_base.unintimidateable) then
									local anim_data = unit:anim_data()
									local unit_data = unit:unit_data()
									local unit_brain = unit:brain()
									
									if anim_data and not anim_data.unintimidateable and unit_brain and not unit_brain:is_tied() 
										and not (unit_data and unit_data.disable_shout) then
										if not unit_mov:cool() and not anim_data.drop then
											table.insert(intimidateable_civilians, {unit = unit, key = u_key, inv_wgt = 1})
											best_civ = best_civ or unit
										end
									end
								end
							end
						end
					end
				end
			end
		end
		
		return best_civ, 1, intimidateable_civilians
	end

	if BB:get("maskup", false) then
		local old_onalert = TeamAILogicIdle.on_alert
		function TeamAILogicIdle.on_alert(data, alert_data, ...)
			if data.cool then
				local alert_type = alert_data[1]
				if CopLogicBase and CopLogicBase.is_alert_aggressive and CopLogicBase.is_alert_aggressive(alert_type) then
					local unit = data.unit
					if alive(unit) and unit:movement() then
						unit:movement():set_cool(false)
					end
				end
			end
			return old_onalert(data, alert_data, ...)
		end
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
	local mvec3_angle = mvector3.angle
	local mvec3_norm = mvector3.normalize
	local math_ceil = math.ceil
	local REACT_COMBAT = AIAttentionObject.REACT_COMBAT

	function TeamAILogicAssault.find_enemy_to_mark(enemies, my_unit)
		if not alive(my_unit) or not managers.player then return nil end
		
		local player_manager = managers.player
		local get_contour = player_manager:get_contour_for_marked_enemy()
		local has_ap = player_manager:has_category_upgrade("team", "crew_ai_ap_ammo")
		local unit_movement = my_unit:movement()
		if not unit_movement then return nil end
		
		local head_pos = unit_movement:m_head_pos()
		local best_nmy, best_nmy_wgt
		
		for _, attention_info in pairs(enemies or {}) do
			if attention_info.identified and (attention_info.verified or attention_info.nearly_visible) then
				local att_unit = attention_info.unit
				if alive(att_unit) then
					local reaction = attention_info.reaction or AIAttentionObject.REACT_IDLE
					if reaction >= REACT_COMBAT then
						local att_base = att_unit:base()
						local is_turret = att_base and att_base.sentry_gun
						local is_special = (att_base and att_base.has_tag and att_base:has_tag("special")) 
							or (attention_info.char_tweak and attention_info.char_tweak.priority_shout)
						
						if is_turret or is_special then
							local dis = attention_info.verified_dis
							if dis and dis <= CONSTANTS.MARK_DISTANCE then
								local is_shield = attention_info.is_shield
								local shielded = World:raycast("ray", head_pos, attention_info.m_head_pos, "ignore_unit", {my_unit}, "slot_mask", MASK.enemy_shield_check)
								local can_hit = has_ap or dis <= CONSTANTS.MELEE_DISTANCE or not shielded
								
								if not is_shield or can_hit then
									if (not best_nmy_wgt) or best_nmy_wgt > dis then
										local u_contour = att_unit:contour()
										if u_contour then
											local c_id = is_turret and "mark_unit_dangerous" or get_contour
											if not u_contour._contour_list or not u_contour:has_id(c_id) then
												best_nmy_wgt = dis
												best_nmy = att_unit
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
		
		return best_nmy
	end

	function TeamAILogicAssault.mark_enemy(data, criminal, to_mark, play_sound, play_action)
		if not alive(criminal) or not alive(to_mark) then return end
		
		local mark_base = to_mark:base()
		if not mark_base then return end
		
		local is_turret = mark_base.sentry_gun
		
		if play_sound then
			local sound_name = is_turret and "f44" or (mark_base:char_tweak() and mark_base:char_tweak().priority_shout)
			if sound_name and criminal:sound() then
				safe_call(criminal:sound().say, criminal:sound(), sound_name .. "x_any", true, true)
			end
		end
		
		if play_action and criminal:movement() and not criminal:movement():chk_action_forbidden("action") then
			local new_action = {type = "act", variant = "arrest", body_part = 3, align_sync = true}
			if criminal:brain() and criminal:brain():action_request(new_action) then
				if data.internal_data then
					data.internal_data.gesture_arrest = true
				end
			end
		end
		
		local contour = to_mark:contour()
		if contour then
			safe_call(contour.add, contour, is_turret and "mark_unit_dangerous" or "mark_enemy", true)
		end
	end

	function TeamAILogicAssault.check_smart_reload(data)
		local unit = data.unit
		if not alive(unit) then return end
		
		local unit_anim = unit:anim_data()
		local unit_movement = unit:movement()
		local unit_inventory = unit:inventory()
		
		if not unit_anim or unit_anim.reload then return end
		if not unit_movement or unit_movement:chk_action_forbidden("reload") then return end
		if not unit_inventory then return end
		
		local current_wep = unit_inventory:equipped_unit()
		if not (current_wep and current_wep:base()) then return end
		
		local ammo_max, ammo = current_wep:base():ammo_info()
		if not ammo_max or ammo_max == 0 then return end
		
		local nearby_threats = 0
		local closest_threat = math.huge
		
		for _, u_char in pairs(data.detected_attention_objects or {}) do
			if u_char.identified and u_char.verified and alive(u_char.unit) and are_units_foes(unit, u_char.unit) then
				nearby_threats = nearby_threats + 1
				if u_char.verified_dis and u_char.verified_dis < closest_threat then
					closest_threat = u_char.verified_dis
				end
			end
		end
		
		local reload_threshold = 0.6
		if nearby_threats == 0 then
			reload_threshold = 0.8
		elseif closest_threat < 500 then
			reload_threshold = 0.3
		elseif nearby_threats > 3 then
			reload_threshold = 0.4
		end
		
		if ammo <= math_ceil(ammo_max * reload_threshold) then
			local objective = data.objective
			local in_cover = objective and objective.in_place
			
			if in_cover or closest_threat > 1000 or ammo == 0 then
				if unit:brain() then
					unit:brain():action_request({type = "reload", body_part = 3})
				end
			end
		end
	end

	local function execute_melee_attack(data, criminal)
		if not alive(criminal) then return end
		
		local criminal_inventory = criminal:inventory()
		if not criminal_inventory then return end
		
		local current_wep = criminal_inventory:equipped_unit()
		local crim_mov = criminal:movement()
		if not crim_mov then return end
		
		local my_pos = crim_mov:m_head_pos()
		local look_vec = crim_mov:m_rot():y()
		
		local current_ammo_ratio = 1
		if current_wep and current_wep:base() then
			local ammo_max, ammo = current_wep:base():ammo_info()
			if ammo_max and ammo_max > 0 then
				current_ammo_ratio = ammo / ammo_max
			end
		end

		if current_ammo_ratio > 0.5 then return end
		
		local best_melee_target, best_melee_priority = nil, 0
		
		for _, u_char in pairs(data.detected_attention_objects or {}) do
			if u_char.identified and alive(u_char.unit) and are_units_foes(criminal, u_char.unit) then
				if u_char.verified and u_char.verified_dis and u_char.verified_dis <= CONSTANTS.MELEE_DISTANCE then
					local unit_pos = u_char.m_head_pos
					if unit_pos then
						local vec = unit_pos - my_pos
						if mvec3_angle(vec, look_vec) <= CONSTANTS.MELEE_ANGLE then
							local melee_priority = 0
							
							if u_char.is_shield then
								melee_priority = 10
							elseif not u_char.char_tweak or not u_char.char_tweak.priority_shout then
								local unit = u_char.unit
								local unit_inventory = unit:inventory()
								local unit_anim = unit:anim_data()
								if unit_inventory and unit_inventory:get_weapon() and unit_anim and not unit_anim.hurt then
									melee_priority = 5
								end
							end
							
							if melee_priority > best_melee_priority then
								best_melee_priority = melee_priority
								best_melee_target = u_char
							end
						end
					end
				end
			end
		end
		
		if not best_melee_target then return end
		
		local unit = best_melee_target.unit
		local damage = unit:character_damage()
		if not damage or not damage._HEALTH_INIT then return end
		
		local health_damage = math_ceil(damage._HEALTH_INIT / 2)
		local vec = best_melee_target.m_head_pos - my_pos
		local unit_body = unit:body("body")
		if not unit_body then return end
		
		local col_ray = {ray = -vec, body = unit_body, position = best_melee_target.m_head_pos}
		local damage_info = {
			attacker_unit = criminal,
			weapon_unit = current_wep,
			variant = best_melee_target.is_shield and "melee" or "bullet",
			damage = best_melee_target.is_shield and 0 or health_damage,
			col_ray = col_ray,
			origin = my_pos
		}
		
		if best_melee_target.is_shield then
			damage_info.shield_knock = true
			safe_call(damage.damage_melee, damage, damage_info)
		else
			damage_info.knock_down = true
			safe_call(damage.damage_bullet, damage, damage_info)
		end
		
		safe_call(crim_mov.play_redirect, crim_mov, "melee")
		if managers.network and managers.network:session() then
			safe_call(managers.network:session().send_to_peers, managers.network:session(), "play_distance_interact_redirect", criminal, "melee")
		end
	end

	local function throw_concussion_grenade(data, criminal)
		if not BB:get("conc", false) or not alive(criminal) then return end
		if not tweak_data.blackmarket or not tweak_data.blackmarket.projectiles then return end
		
		local conc_tweak = tweak_data.blackmarket.projectiles.concussion
		if not conc_tweak or not conc_tweak.unit then return end
		
		if not managers.dyn_resource then return end
		local pkg_ready = managers.dyn_resource:is_resource_ready(Idstring("unit"), Idstring(conc_tweak.unit), managers.dyn_resource.DYN_RESOURCES_PACKAGE)
		if not pkg_ready then return end

		local crim_mov = criminal:movement()
		if not crim_mov then return end
		
		local from_pos = crim_mov:m_head_pos()
		local look_vec = crim_mov:m_rot():y()
		
		local close_enemies, shield_count, special_count = 0, 0, 0
		local enemy_cluster = {}
		
		for _, u_char in pairs(data.detected_attention_objects or {}) do
			if u_char.identified and u_char.verified and u_char.verified_dis and u_char.verified_dis <= CONSTANTS.CONC_DISTANCE then
				local unit = u_char.unit
				if alive(unit) and are_units_foes(criminal, unit) then
					local vec = u_char.m_head_pos - from_pos
					if vec and mvec3_angle(vec, look_vec) <= CONSTANTS.CONC_ANGLE then
						local unit_base = unit:base()
						local tweak_table = unit_base and unit_base._tweak_table
						
						if tweak_table and tweak_table ~= "tank" then
							close_enemies = close_enemies + 1
							
							if u_char.is_shield then
								shield_count = shield_count + 1
							end
							if u_char.char_tweak and u_char.char_tweak.priority_shout then
								special_count = special_count + 1
							end
							
							table.insert(enemy_cluster, u_char)
						end
					end
				end
			end
		end

		local should_throw = (close_enemies >= 5) or (shield_count >= 2) or (special_count >= 2 and close_enemies >= 3)
		if not should_throw then return end
		
		local best_cluster_pos, best_cluster_count, target_unit = nil, 0, nil
		
		for i, u_char1 in ipairs(enemy_cluster) do
			local cluster_count = 0
			
			for j, u_char2 in ipairs(enemy_cluster) do
				if i ~= j and u_char2.m_head_pos then
					local dist = mvector3.distance(u_char1.m_head_pos, u_char2.m_head_pos)
					if dist <= CONSTANTS.CLUSTER_DISTANCE then
						cluster_count = cluster_count + 1
					end
				end
			end
			
			if cluster_count > best_cluster_count then
				best_cluster_count = cluster_count
				best_cluster_pos = u_char1.m_head_pos
				target_unit = u_char1.unit
			end
		end
		
		if not (alive(target_unit) and best_cluster_count >= 2 and best_cluster_pos) then return end
		
		local mvec_spread_direction = best_cluster_pos - from_pos
		if ProjectileBase and ProjectileBase.spawn then
			local cc_unit = ProjectileBase.spawn(conc_tweak.unit, from_pos, Rotation())
			if cc_unit and cc_unit:base() then
				mvec3_norm(mvec_spread_direction)
				safe_call(crim_mov.play_redirect, crim_mov, "throw_grenade")
				
				if managers.network and managers.network:session() then
					safe_call(managers.network:session().send_to_peers, managers.network:session(), "play_distance_interact_redirect", criminal, "throw_grenade")
				end
				
				if criminal:sound() then
					safe_call(criminal:sound().say, criminal:sound(), "g43", true, true)
				end
				
				cc_unit:base():throw({dir = mvec_spread_direction, owner = criminal})
				
				if data.internal_data then
					data.internal_data._conc_t = data.t + CONSTANTS.CONC_COOLDOWN
				end
			end
		end
	end

	if Network:is_server() then
		local old_update = TeamAILogicAssault.update
		function TeamAILogicAssault.update(data, ...)
			if not TimerManager or not TimerManager:game() then
				return old_update(data, ...)
			end

			local t = TimerManager:game():time()
			local my_data = data.internal_data or {}
			local unit = data.unit

			if (not my_data._conc_t) or (my_data._conc_t + 1 < t) then
				my_data._conc_t = t
				safe_call(throw_concussion_grenade, data, unit)
			end

			if (not my_data.melee_t) or (my_data.melee_t + CONSTANTS.MELEE_CHECK_INTERVAL < t) then
				my_data.melee_t = t
				safe_call(execute_melee_attack, data, unit)
			end

			if (not my_data.reload_t) or (my_data.reload_t + CONSTANTS.RELOAD_CHECK_INTERVAL < t) then
				my_data.reload_t = t
				safe_call(TeamAILogicAssault.check_smart_reload, data)
			end

			return old_update(data, ...)
		end
	end

	local old_exit = TeamAILogicAssault.exit
	function TeamAILogicAssault.exit(data, ...)
		safe_call(TeamAILogicAssault.check_smart_reload, data)
		return old_exit(data, ...)
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
	local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
	local mvec3_angle = mvector3.angle

	local function find_enemy_to_intimidate(data)
		if not alive(data.unit) or not data.unit:movement() then
			return nil
		end
		
		local look_vec = data.unit:movement():m_rot():y()
		local has_room = managers.groupai and managers.groupai:state() and managers.groupai:state():has_room_for_police_hostage()
		local consider_all = BB:get("dom", false)
		
		local targets = {}
		if consider_all then
			targets = data.detected_attention_objects or {}
		else
			for u_key, t in pairs(BB.cops_to_intimidate or {}) do
				if data.t - t < BB.grace_period then
					local att_obj = data.detected_attention_objects and data.detected_attention_objects[u_key]
					if att_obj then
						targets[u_key] = att_obj
					end
				end
			end
		end

		local best_nmy, best_dis
		
		for _, u_char in pairs(targets) do
			if u_char and u_char.identified and u_char.verified then
				local unit = u_char.unit
				if alive(unit) then
					local anim_data = unit:anim_data()
					local is_surrender_state = anim_data and (anim_data.hands_back or anim_data.surrender)
					
					if are_units_foes(data.unit, unit) or is_surrender_state then
						local intim_dis = u_char.verified_dis
						if intim_dis and intim_dis <= CONSTANTS.INTIMIDATE_DISTANCE and u_char.m_pos then
							local vec = u_char.m_pos - data.m_pos
							if mvec3_angle(vec, look_vec) <= CONSTANTS.INTIMIDATE_ANGLE then
								local char_tweak = u_char.char_tweak
								if char_tweak and char_tweak.surrender and not char_tweak.priority_shout then
									local unit_inventory = unit:inventory()
									if unit_inventory and unit_inventory:get_weapon() and anim_data then
										if has_room or is_surrender_state then
											local health_ratio = get_unit_health_ratio(unit)
											local is_hurt = health_ratio < 1
											
											local intim_priority = anim_data.hands_back and 3 
												or anim_data.surrender and 2 
												or (is_hurt and 1)
											
											if intim_priority then
												intim_dis = intim_dis / intim_priority
												if (not best_dis) or best_dis > intim_dis then
													best_nmy = unit
													best_dis = intim_dis
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end

		return best_nmy
	end

	local function intimidate_law_enforcement(data, intim_unit, play_action)
		if not alive(intim_unit) then return end
		
		local anim_data = intim_unit:anim_data()
		if not anim_data then return end
		
		local act_name, sound_name
		if anim_data.hands_back then
			act_name, sound_name = "arrest", "l03x_sin"
		elseif anim_data.surrender then
			act_name, sound_name = "arrest", "l02x_sin"
		else
			act_name, sound_name = "gesture_stop", "l01x_sin"
		end

		local unit = data.unit
		if not alive(unit) then return end
		
		if unit:sound() then
			safe_call(unit:sound().say, unit:sound(), sound_name, true, true)
		end
		
		if play_action and unit:movement() and not unit:movement():chk_action_forbidden("action") then
			if unit:brain() and unit:brain():action_request({type = "act", variant = act_name, body_part = 3, align_sync = true}) then
				if data.internal_data then
					data.internal_data.gesture_arrest = true
				end
			end
		end
		
		local intim_brain = intim_unit:brain()
		if intim_brain and intim_brain.on_intimidated then
			intim_brain:on_intimidated(1, unit)
		end
	end

	local function perform_interaction_check(data)
		local unit = data.unit
		if not alive(unit) then return end
		
		local unit_damage = unit:character_damage()
		if unit_damage and unit_damage:need_revive() then return end
		
		local anim_data = unit:anim_data()
		if not anim_data or anim_data.tased then return end
		
		local my_data = data.internal_data or {}
		if my_data.acting then return end

		local t = data.t
		local unit_sound = unit:sound()
		if unit_sound and unit_sound:speaking() then return end
		
		if my_data._intimidate_t and my_data._intimidate_t + CONSTANTS.INTIMIDATE_COOLDOWN >= t then
			return
		end

		my_data._intimidate_t = t
		
		local carrying = unit:movement() and unit:movement():carrying_bag()
		local allow_actions = (not anim_data.reload) and (not carrying)
		
		local civ = TeamAILogicIdle and TeamAILogicIdle.find_civilian_to_intimidate 
			and TeamAILogicIdle.find_civilian_to_intimidate(unit, CONSTANTS.INTIMIDATE_ANGLE, CONSTANTS.INTIMIDATE_DISTANCE)
		local dom = find_enemy_to_intimidate(data)
		local nmy = TeamAILogicAssault and TeamAILogicAssault.find_enemy_to_mark 
			and TeamAILogicAssault.find_enemy_to_mark(data.detected_attention_objects, unit)

		if alive(civ) and TeamAILogicIdle and TeamAILogicIdle.intimidate_civilians then
			safe_call(TeamAILogicIdle.intimidate_civilians, data, unit, true, allow_actions)
		elseif alive(dom) then
			intimidate_law_enforcement(data, dom, allow_actions)
		elseif alive(nmy) and TeamAILogicAssault and TeamAILogicAssault.mark_enemy then
			if TeamAILogicAssault._mark_special_chk_t ~= math.huge 
				and (not TeamAILogicBase._mark_t or TeamAILogicBase._mark_t + CONSTANTS.MARK_COOLDOWN < t) then
				safe_call(TeamAILogicAssault.mark_enemy, data, unit, nmy, true, allow_actions)
				TeamAILogicBase._mark_t = t
			end
		end
	end

	function TeamAILogicBase._set_attention_obj(data, new_att_obj, new_reaction)
		safe_call(perform_interaction_check, data)
		data.attention_obj = new_att_obj
		if new_att_obj then
			new_att_obj.reaction = new_reaction or new_att_obj.reaction
		end
	end

	function TeamAILogicBase._get_logic_state_from_reaction(data, reaction)
		return (not reaction or reaction < REACT_COMBAT) and "idle" or "assault"
	end
end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
	if BB:get("combat", false) then
		local math_lerp = math.lerp
		local old_shoot = CopActionShoot._get_shoot_falloff
		function CopActionShoot:_get_shoot_falloff(target_dis, falloff, ...)
			if self and self._unit and alive(self._unit) and is_team_ai(self._unit) then
				local i = #falloff
				local data = falloff[i]
				
				for i_range = 1, #falloff do
					local range_data = falloff[i_range]
					if range_data and target_dis < range_data.r then
						i, data = i_range, range_data
						break
					end
				end
				
				if i > 1 then
					local prev_data = falloff[i - 1]
					local t = (target_dis - prev_data.r) / (data.r - prev_data.r)
					
					local n_data = {
						dmg_mul = math_lerp(prev_data.dmg_mul, data.dmg_mul, t),
						r = target_dis,
						acc = {math_lerp(prev_data.acc[1], data.acc[1], t), math_lerp(prev_data.acc[2], data.acc[2], t)},
						recoil = {math_lerp(prev_data.recoil[1], data.recoil[1], t), math_lerp(prev_data.recoil[2], data.recoil[2], t)},
						mode = data.mode
					}
					return n_data, i
				end
				
				return data, i
			end
			return old_shoot(self, target_dis, falloff, ...)
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/copbrain" then
	local old_convert = CopBrain.convert_to_criminal
	function CopBrain:convert_to_criminal(...)
		old_convert(self, ...)
		if self._logic_data and self._logic_data.char_tweak then
			local char_tweak = deep_clone(self._logic_data.char_tweak)
			char_tweak.access = "teamAI1"
			char_tweak.always_face_enemy = true
			self._logic_data.char_tweak = char_tweak
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/copdamage" then
	local old_melee = CopDamage.damage_melee
	function CopDamage:damage_melee(attack_data, ...)
		if attack_data and attack_data.variant == "taser_tased" and self._unit then
			BB:add_cop_to_intimidation_list(self._unit:key())
		end
		return old_melee(self, attack_data, ...)
	end

	local old_sync_melee = CopDamage.sync_damage_melee
	function CopDamage:sync_damage_melee(variant, ...)
		if variant == 5 and self._unit then
			BB:add_cop_to_intimidation_list(self._unit:key())
		end
		return old_sync_melee(self, variant, ...)
	end

	if BB:get("ammo", false) then
		local old_die = CopDamage.die
		function CopDamage:die(attack_data, ...)
			if attack_data then
				local attacker_unit = attack_data.attacker_unit
				if alive(attacker_unit) and is_team_ai(attacker_unit) and self._pickup == "ammo" then
					self:set_pickup(nil)
				end
			end
			return old_die(self, attack_data, ...)
		end
	end

	if BB:get("combat", false) then
		local old_bullet = CopDamage.damage_bullet
		function CopDamage:damage_bullet(attack_data, ...)
			if self._unit and alive(self._unit) and self._unit:base() and self._unit:base():has_tag("sniper") then
				if attack_data then
					local attacker_unit = attack_data.attacker_unit
					if alive(attacker_unit) and is_team_ai(attacker_unit) and self._HEALTH_INIT then
						attack_data.damage = self._HEALTH_INIT
					end
				end
			end
			return old_bullet(self, attack_data, ...)
		end
	end

	local old_stun = CopDamage.stun_hit
	function CopDamage:stun_hit(...)
		if self._unit and alive(self._unit) and not is_law_unit(self._unit) then
			return
		end
		return old_stun(self, ...)
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
	if BB:get("reflex", false) then
		local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
		local old_upd = CopLogicBase._upd_attention_obj_detection

		function CopLogicBase._upd_attention_obj_detection(data, min_reaction, max_reaction, ...)
			local unit = data.unit
			if alive(unit) and is_team_ai(unit) then
				local t = data.t
				local my_key = data.key
				local detected_obj = data.detected_attention_objects or {}
				local unit_mov = unit:movement()
				if not unit_mov then
					return old_upd(data, min_reaction, max_reaction, ...)
				end
				
				local my_pos = unit_mov:m_head_pos()
				local my_access = data.SO_access
				local my_team = data.team
				local slotmask = data.visibility_slotmask
				local my_tracker = unit_mov:nav_tracker()
				if not my_tracker then
					return old_upd(data, min_reaction, max_reaction, ...)
				end
				
				local chk_vis_func = my_tracker.check_visibility
				local gstate = managers.groupai and managers.groupai:state()
				if not gstate then
					return old_upd(data, min_reaction, max_reaction, ...)
				end
				
				local all_attention_objects = gstate:get_AI_attention_objects_by_filter(data.SO_access_str, my_team)

				for u_key, attention_info in pairs(all_attention_objects or {}) do
					if u_key ~= my_key and not detected_obj[u_key] then
						local att_tracker = attention_info.nav_tracker
						if (not att_tracker) or chk_vis_func(my_tracker, att_tracker) then
							local att_handler = attention_info.handler
							if att_handler and att_handler.get_attention then
								local settings = att_handler:get_attention(my_access, min_reaction, max_reaction, my_team)
								if settings and att_handler.get_detection_m_pos then
									local attention_pos = att_handler:get_detection_m_pos()
									if attention_pos then
										local vis_ray = World:raycast("ray", my_pos, attention_pos, "slot_mask", slotmask, "ray_type", "ai_vision")
										if not vis_ray or (vis_ray.unit and vis_ray.unit:key() == u_key) then
											if CopLogicBase._create_detected_attention_object_data then
												local att_obj = CopLogicBase._create_detected_attention_object_data(t, unit, u_key, attention_info, settings)
												if att_obj then
													local new_reaction = (settings and settings.reaction) or AIAttentionObject.REACT_IDLE

													if new_reaction < REACT_COMBAT then
														local their_team = attention_info.team
														local foes = my_team and my_team.foes
														if their_team and foes and foes[their_team.id] then
															new_reaction = REACT_COMBAT
														end
													end
													
													att_obj.identified = true
													att_obj.identified_t = t
													att_obj.reaction = new_reaction
													att_obj.settings.reaction = new_reaction
													detected_obj[u_key] = att_obj
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end

			return old_upd(data, min_reaction, max_reaction, ...)
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then
	if Network:is_server() then
		local old_enter = CopLogicIdle.enter
		function CopLogicIdle.enter(data, ...)
			old_enter(data, ...)
			if data.is_converted and TeamAILogicAssault and TeamAILogicAssault.check_smart_reload then
				safe_call(TeamAILogicAssault.check_smart_reload, data)
			end
		end

		local old_intim = CopLogicIdle.on_intimidated
		function CopLogicIdle.on_intimidated(data, ...)
			local surrender = old_intim(data, ...)
			local unit = data.unit
			if alive(unit) then
				BB:add_cop_to_intimidation_list(unit:key())
                if surrender and unit:base() and unit:base().set_slot then
                    unit:base():set_slot(unit, SLOTS.HOSTAGES)
                end
			end
			return surrender
		end

		local old_prio = CopLogicIdle._get_priority_attention
		function CopLogicIdle._get_priority_attention(data, attention_objects, reaction_func)
			local best_target, best_priority, best_reaction = old_prio(data, attention_objects, reaction_func)
			if data.is_converted and TeamAILogicIdle and TeamAILogicIdle._get_priority_attention then
				best_target, best_priority, best_reaction = TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
			end
			return best_target, best_priority, best_reaction
		end
	end
end

if RequiredScript == "lib/managers/mission/elementmissionend" then
	local is_offline = Global and Global.game_settings and Global.game_settings.single_player
	
	function ElementMissionEnd:on_executed(instigator)
		if not self._values.enabled then return end
		if self._values.state ~= "none" and managers.platform and managers.platform:presence() == "Playing" then
			if self._values.state == "success" then
				local num_winners = 0
				if managers.network and managers.network:session() then
					num_winners = managers.network:session():amount_of_alive_players()
				end
				if is_offline and managers.groupai and managers.groupai:state() then
					num_winners = num_winners + managers.groupai:state():amount_of_winning_ai_criminals()
				end
				if managers.network and managers.network:session() then
					managers.network:session():send_to_peers("mission_ended", true, num_winners)
				end
				if game_state_machine and managers.player and managers.player:player_unit() then
					game_state_machine:change_state_by_name("victoryscreen", {
						num_winners = num_winners,
						personal_win = alive(managers.player:player_unit())
					})
				end
			elseif self._values.state == "failed" then
				if managers.network and managers.network:session() then
					managers.network:session():send_to_peers("mission_ended", false, 0)
				end
				if game_state_machine then
					game_state_machine:change_state_by_name("gameoverscreen")
				end
			elseif self._values.state == "leave" then
				if MenuCallbackHandler and MenuCallbackHandler.leave_mission then
					MenuCallbackHandler:leave_mission()
				end
			elseif self._values.state == "leave_safehouse" and instigator and instigator:base() and instigator:base().is_local_player then
				if MenuCallbackHandler and MenuCallbackHandler.leave_safehouse then
					MenuCallbackHandler:leave_safehouse()
				end
			end
		elseif Application:editor() and managers.editor then
			managers.editor:output_error("Cant change to state " .. tostring(self._values.state) .. " in mission end element " .. tostring(self._editor_name) .. ".")
		end
		if ElementMissionEnd.super and ElementMissionEnd.super.on_executed then
			ElementMissionEnd.super.on_executed(self, instigator)
		end
	end
end