_G.BB = _G.BB or {}
do
	if ((getmetatable(_G) or {}).__index or {}).managers == nil then
		local t = { managers = managers }
		t.__index = t
		setmetatable(_G, setmetatable(t, getmetatable(_G)))
	end
end

local BB = _G.BB

BB._path = ModPath
BB._data_path = SavePath .. "bb_data.txt"
BB._data = BB._data or {}
BB.cops_to_intimidate = BB.cops_to_intimidate or {}
BB.grace_period = BB.grace_period or 10

local function clamp(x, a, b)
	return math.min(math.max(x, a), b)
end

local function as_bool_from_item(item)
	return item and item:value() == "on"
end

local function as_number_from_item(item, fallback)
	local v = item and item:value()
	v = tonumber(v)
	return v or fallback
end

function BB:Save()
	local ok, encoded = pcall(json.encode, self._data)
	if not ok then
		return
	end
	local file = io.open(self._data_path, "w")
	if file then
		file:write(encoded)
		file:close()
	end
end

function BB:Load()
	local file = io.open(self._data_path, "r")
	if not file then
		return
	end
	local raw = file:read("*all")
	file:close()
	if not raw or raw == "" then
		return
	end
	local ok, decoded = pcall(json.decode, raw)
	if ok and type(decoded) == "table" then
		self._data = decoded
	end
end

function BB:get(key, default)
	local v = self._data[key]
	if v == nil then
		return default
	end
	return v
end

BB:Load()

Hooks:Add("LocalizationManagerPostInit", "LocalizationManagerPostInit_BB", function(loc)
	local loc_dir = BB._path .. "loc/"
	for _, filename in pairs(file.GetFiles(loc_dir)) do
		local lang = filename:match("^(.*)%.txt$")
		if lang and Idstring(lang) and Idstring(lang):key() == SystemInfo:language():key() then
			loc:load_localization_file(loc_dir .. filename)
			break
		end
	end
	loc:load_localization_file(BB._path .. "loc/english.txt", false)
end)

Hooks:Add("MenuManagerInitialize", "MenuManagerInitialize_BB", function(menu_manager)
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
	MenuHelper:LoadFromJsonFile(BB._path .. "menu.txt", BB, BB._data)
end)

function BB:add_cop_to_intimidation_list(unit_key)
	local t = TimerManager:game():time()
	local prev_t = self.cops_to_intimidate[unit_key]
	self.cops_to_intimidate[unit_key] = t

	if Network:is_server() then
		local is_new = not prev_t or (t - prev_t) > self.grace_period
		if is_new then
			local gstate = managers.groupai:state()
			local function _dont_attack(unit)
				local brain = unit:brain()
				local data = brain and brain._logic_data
				if data then
					local att_obj = data.attention_obj
					if att_obj and att_obj.u_key == unit_key then
						CopLogicBase._set_attention_obj(data)
					end
				end
			end
			for _, sighting in pairs(gstate._ai_criminals) do
				_dont_attack(sighting.unit)
			end
			for _, unit in pairs(gstate._converted_police) do
				_dont_attack(unit)
			end
		end
	end
end

if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then
	local is_server = Network:is_server()
	local data_conc = BB:get("conc", false)

	if data_conc and is_server then
		local old_init = GroupAIStateBase.init
		function GroupAIStateBase:init(...)
			local conc_data = tweak_data.blackmarket.projectiles and tweak_data.blackmarket.projectiles.concussion
			if conc_data and conc_data.unit then
				local unit_name = Idstring(conc_data.unit)
				if not managers.dyn_resource:is_resource_ready(Idstring("unit"), unit_name, managers.dyn_resource.DYN_RESOURCES_PACKAGE) then
					managers.dyn_resource:load(Idstring("unit"), unit_name, managers.dyn_resource.DYN_RESOURCES_PACKAGE)
				end
			end
			return old_init(self, ...)
		end
	end

	if BB:get("chat", false) then
		function GroupAIStateBase:chk_say_teamAI_combat_chatter(...)
			return
		end
	end

	local bb_original_groupaistatebase_ontasestart = GroupAIStateBase.on_tase_start
	function GroupAIStateBase:on_tase_start(cop_key, criminal_key, ...)
		local bot_record = self._ai_criminals[criminal_key]
		if bot_record then
			local cop_data = self._police[cop_key]
			local taser_unit = cop_data and cop_data.unit
			local taser_contour = taser_unit and taser_unit:contour()
			if taser_contour then
				local get_contour = managers.player:get_contour_for_marked_enemy()
				if not taser_contour._contour_list or not taser_contour:has_id(get_contour) then
					bot_record.unit:sound():say("f32x_any", true)
					taser_contour:add("mark_enemy", true)
				end
			end
		end
		return bb_original_groupaistatebase_ontasestart(self, cop_key, criminal_key, ...)
	end

	function GroupAIStateBase:_get_balancing_multiplier(balance_multipliers, ...)
		local nr_crim = 0
		for _, u_data in pairs(self:all_char_criminals()) do
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
		self._upgrades = {}
		self._upgrade_levels = {}
		if is_server then
			self:set_upgrade_value("player", "intimidate_enemies", 1)
			self:set_upgrade_value("player", "empowered_intimidation_mul", 1)
			self:set_upgrade_value("player", "intimidation_multiplier", 1)
			self:set_upgrade_value("player", "civ_calming_alerts", 1)
			self:set_upgrade_value("player", "intimidate_aura", 1)
			self:set_upgrade_value("player", "civ_intimidation_mul", 1)
		end
	end
	function TeamAIBase:set_upgrade_value(category, upgrade, level)
		HuskPlayerBase.set_upgrade_value(self, category, upgrade, level)
	end
	function TeamAIBase:upgrade_value(category, upgrade)
		return self._upgrades[category] and self._upgrades[category][upgrade]
	end
	function TeamAIBase:upgrade_level(category, upgrade)
		return self._upgrade_levels[category] and self._upgrade_levels[category][upgrade]
	end
end

if RequiredScript == "lib/units/player_team/teamaidamage" then
	if BB:get("doc", false) then
		local bb_original_teamaidamage_applydamage = TeamAIDamage._apply_damage
		function TeamAIDamage:_apply_damage(...)
			local damage_percent, health_subtracted = bb_original_teamaidamage_applydamage(self, ...)
			local brain = self._unit:brain()
			local data = brain and brain._logic_data
			if data then
				local my_data = data.internal_data
				if my_data and not my_data.said_hurt then
					if self._health_ratio <= 0.2 then
						if not self:need_revive() then
							my_data.said_hurt = true
							self._unit:sound():say("g80x_plu", true)
						end
					end
				end
			end
			return damage_percent, health_subtracted
		end

		local bb_original_teamaidamage_regenerated = TeamAIDamage._regenerated
		function TeamAIDamage:_regenerated(...)
			local brain = self._unit:brain()
			local data = brain and brain._logic_data
			if data then
				local my_data = data.internal_data
				if my_data and my_data.said_hurt then
					my_data.said_hurt = false
				end
			end
			return bb_original_teamaidamage_regenerated(self, ...)
		end
	end

	function TeamAIDamage:friendly_fire_hit(...)
		return
	end
end

if RequiredScript == "lib/units/interactions/interactionext" then
	if Network:is_server() then
		local function _cancel_rescue(revive_unit, rescuer)
			for u_key, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
				local unit = u_data.unit
				if alive(unit) and u_key ~= rescuer:key() then
					local brain = unit:brain()
					local data = brain and brain._logic_data
					local obj = data and data.objective
					if obj and obj.type == "revive" then
						local follow_unit = obj.follow_unit
						if follow_unit and follow_unit:key() == revive_unit:key() then
							brain:set_objective()
						end
					end
				end
			end
		end

		local old_start = ReviveInteractionExt._at_interact_start
		function ReviveInteractionExt:_at_interact_start(player, ...)
			old_start(self, player, ...)
			if self.tweak_data == "revive" or self.tweak_data == "free" then
				_cancel_rescue(self._unit, player)
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

			if self.m14_crew then
				self.m14_crew.usage = "is_pistol"
				self.m14_crew.anim_usage = "is_rifle"
			end
			if self.contraband_crew then
				self.contraband_crew.usage = "is_pistol"
				self.contraband_crew.anim_usage = "is_rifle"
			end
			if self.sub2000_crew then
				self.sub2000_crew.usage = "is_pistol"
			end
			if self.spas12_crew then
				self.spas12_crew.usage = "is_shotgun_mag"
				self.spas12_crew.anim_usage = "is_shotgun_pump"
			end
			if self.ben_crew then
				self.ben_crew.usage = "is_shotgun_mag"
				self.ben_crew.anim_usage = "is_shotgun_pump"
			end
			if self.ching_crew then
				self.ching_crew.usage = "is_pistol"
				self.ching_crew.anim_usage = "is_rifle"
			end
			if self.m95_crew then
				self.m95_crew.usage = "rifle"
				self.m95_crew.anim_usage = "is_bullpup"
			end
		end
	end
end

if RequiredScript == "lib/managers/criminalsmanager" then
	local is_offline = Global and Global.game_settings and Global.game_settings.single_player
	local is_server = Network:is_server()
	local total_chars = CriminalsManager.get_num_characters()
	if BB:get("biglob", false) then
		CriminalsManager.MAX_NR_TEAM_AI = total_chars
	end

	local char_tweak = tweak_data.character
	if char_tweak and char_tweak.presets then
		local char_preset = char_tweak.presets

		local params = {
			health = { nil, 75, 144 },
			dodge = { "poor", "average", "heavy", "athletic", "ninja" }
		}

		local char_damage = char_preset.gang_member_damage
		if char_damage then
			local health_idx = BB:get("health", 1)
			local health_bot = params.health[health_idx]
			if health_bot then
				char_damage.HEALTH_INIT = health_bot
			end
			if BB:get("instadwn", false) then
				char_damage.DOWNED_TIME = 0
			end
		end

		local gang_weapon = char_preset.weapon.bot_weapons or char_preset.weapon.gang_member
		if gang_weapon then
			local dodge_idx = BB:get("dodge", 4)
			local dodge_bot = params.dodge[dodge_idx]
			local damage_bot = BB:get("dmgmul", 5)

			for _, v in pairs(gang_weapon) do
				v.focus_delay = 0
				v.aim_delay = { 0, 0 }
				v.range = deep_clone(char_preset.weapon.sniper.is_rifle.range)
				v.RELOAD_SPEED = 1
				if BB:get("combat", false) then
					v.spread = 5
					v.FALLOFF = {
						{
							r = 1500,
							acc = { 1, 1 },
							dmg_mul = damage_bot,
							recoil = { 0.2, 0.2 },
							mode = { 0, 0, 0, 1 }
						},
						{
							r = 4500,
							acc = { 1, 1 },
							dmg_mul = 1,
							recoil = { 2, 2 },
							mode = { 0, 0, 0, 1 }
						}
					}
				end
			end

			for _, v in pairs(char_tweak) do
				if type(v) == "table" and v.access == "teamAI1" then
					v.no_run_start = true
					v.no_run_stop = true
					v.always_face_enemy = true
					v.damage.hurt_severity = char_preset.hurt_severities.only_light_hurt
					if is_server then
						v.move_speed = char_preset.move_speed.lightning
					end

					local move_choice = BB:get("move", 1)
					if move_choice == 2 and dodge_bot then
						v.dodge = char_preset.dodge[dodge_bot]
					elseif move_choice == 3 then
						v.allowed_poses = { stand = true }
					end

					local orig = v.weapon.weapons_of_choice
					v.weapon = deep_clone(gang_weapon)
					v.weapon.weapons_of_choice = orig

					if BB:get("combat", false) then
						v.weapon.is_sniper.FALLOFF[1].dmg_mul = damage_bot * 5
						v.weapon.is_sniper.FALLOFF[1].recoil = { 1, 1 }
						v.weapon.is_shotgun_pump.FALLOFF[1].dmg_mul = damage_bot * 2.5
						v.weapon.is_shotgun_pump.FALLOFF[1].recoil = { 0.5, 0.5 }
						v.weapon.rifle.FALLOFF[1].dmg_mul = damage_bot * 10
						v.weapon.rifle.FALLOFF[1].recoil = { 2, 2 }
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
				if not char_data.ai_id then
					char_data.ai_id = self:nr_AI_criminals() + 1
				end
				return char_data.ai_id
			end
			return old_color(self, unit, ...)
		end
	end
end

if RequiredScript == "lib/tweak_data/playertweakdata" then
	function PlayerTweakData:_set_singleplayer()
		return
	end
end

local function remove_ai_from_bullet_mask(self, setup_data)
	local ai_mask = World:make_slot_mask(16, 22)
	local user_unit = setup_data and setup_data.user_unit
	if user_unit and user_unit:in_slot(16) and self._bullet_slotmask then
		self._bullet_slotmask = self._bullet_slotmask - ai_mask
		self._bullet_slotmask = self._bullet_slotmask
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
		TeamAIMovement.set_visual_carry = HuskPlayerMovement.set_visual_carry
		TeamAIMovement._destroy_current_carry_unit = HuskPlayerMovement._destroy_current_carry_unit
		TeamAIMovement._create_carry_unit = HuskPlayerMovement._create_carry_unit

		if not BB:get("equip", false) then
			function TeamAIMovement:check_visual_equipment()
				local level_id = tweak_data.levels[managers.job:current_level_id()]
				local bags = { { g_medicbag = true }, { g_ammobag = true } }
				local bag_choice = bags[math.random(#bags)]
				for k, v in pairs(bag_choice) do
					local mesh_obj = self._unit:get_object(Idstring(k))
					if mesh_obj then
						mesh_obj:set_visibility(v)
					end
				end
				if level_id and not level_id.player_sequence then
					self._unit:damage():run_sequence_simple("var_model_02")
				end
			end
		end

		local old_set = TeamAIMovement.set_carrying_bag
		function TeamAIMovement:set_carrying_bag(unit, ...)
			local name_label = managers.hud:_get_name_label(self._unit:unit_data().name_label_id)
			local bag_unit = unit or self._carry_unit
			self:set_visual_carry(unit and unit:carry_data():carry_id())
			if bag_unit then
				bag_unit:set_visible(not unit)
			end
			if name_label then
				local bag_panel = name_label.panel and name_label.panel:child("bag")
				if bag_panel then
					bag_panel:set_visible(unit)
				end
			end
			return old_set(self, unit, ...)
		end
	end

	local old_throw = TeamAIMovement.throw_bag
	function TeamAIMovement:throw_bag(...)
		if self:carrying_bag() then
			local carry_tweak = self:carry_tweak()
			if carry_tweak then
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
		return CriminalActionWalk.super.init(self, ...)
	end

	local function bag_speed_modifier(ext_movement)
		if not ext_movement:carrying_bag() then
			return 1
		end
		local carry_id = ext_movement:carry_id()
		local carry_td = carry_id and tweak_data.carry[carry_id]
		if not carry_td then
			return 1
		end
		local carry_type = carry_td.type
		local move_mod = carry_type and tweak_data.carry.types[carry_type] and tweak_data.carry.types[carry_type].move_speed_modifier or 1
		return math.min(1, move_mod * 1.5)
	end

	function CriminalActionWalk:_get_max_walk_speed(...)
		local speed = deep_clone(CriminalActionWalk.super._get_max_walk_speed(self, ...))
		local mod = bag_speed_modifier(self._ext_movement)
		for i = 1, #speed do
			speed[i] = speed[i] * mod
		end
		return speed
	end

	function CriminalActionWalk:_get_current_max_walk_speed(move_dir, ...)
		local speed = CriminalActionWalk.super._get_current_max_walk_speed(self, move_dir, ...)
		local mod = bag_speed_modifier(self._ext_movement)
		return speed * mod
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then
	local mvec3_norm = mvector3.normalize
	local mvec3_angle = mvector3.angle
	local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
	local W = World

	function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func)
		local best_target, best_target_priority, best_target_reaction
		local att_obj = data.attention_obj
		local unit = data.unit
		local head_pos = unit:movement():m_head_pos()
		local is_team_ai = managers.groupai:state():is_unit_team_AI(unit)
		local has_ap = is_team_ai and managers.player:has_category_upgrade("team", "crew_ai_ap_ammo")

		local current_wep = unit:inventory():equipped_unit()
		local ammo_ratio = 1
		if current_wep then
			local ammo_max, ammo = current_wep:base():ammo_info()
			ammo_ratio = ammo / ammo_max
		end
		
		for u_key, attention_data in pairs(attention_objects) do
			if attention_data.identified then
				local att_unit = attention_data.unit
				if att_unit:in_slot(12, 25) then
					local reaction = attention_data.reaction
					if reaction and reaction >= REACT_COMBAT then
						local target_priority = attention_data.verified_dis
						if target_priority then
							local target_priority_mod = 1
							
							local threat_level = 1
							
							if attention_data.verified then
								local char_tweak = attention_data.char_tweak
								
								local enemy_brain = att_unit:brain()
								local enemy_data = enemy_brain and enemy_brain._logic_data
								local is_attacking = false
								if enemy_data then
									local enemy_att = enemy_data.attention_obj
									if enemy_att and enemy_att.u_key == data.key then
										is_attacking = true
										threat_level = threat_level * 1.5
									end
								end
								
								local enemy_damage = att_unit:character_damage()
								if enemy_damage then
									local health_ratio = enemy_damage:health_ratio()
									if health_ratio <= 0.3 then
										threat_level = threat_level * 0.7
										if is_attacking then
											threat_level = threat_level * 1.5
										end
									end
								end
								
								if att_obj and att_obj.u_key == u_key then
									target_priority_mod = 10 * threat_level
								elseif char_tweak then
									local special_shout = char_tweak.priority_shout
									if special_shout then
										local can_heal = att_unit:base():has_tag("medic")
										if special_shout == "f34" then -- Cloaker
											target_priority_mod = 9 * threat_level
										elseif can_heal then -- Medic
											target_priority_mod = 8 * threat_level
										elseif attention_data.is_very_dangerous then -- Taser/etc
											target_priority_mod = 7 * threat_level
										elseif attention_data.is_shield then
											local is_shielded = W:raycast("ray", head_pos, attention_data.m_head_pos, "ignore_unit", { unit }, "slot_mask", 8)
											local melee_range = is_team_ai and target_priority <= 200
											if has_ap or melee_range or not is_shielded then
												target_priority_mod = 6 * threat_level
											else
												target_priority_mod = 2
											end
										else
											target_priority_mod = 5 * threat_level
										end
									else
										target_priority_mod = 4 * threat_level
									end
								else
									target_priority_mod = 3 * threat_level
								end
							end
							
							if ammo_ratio < 0.3 then
								if target_priority > 1000 then
									target_priority_mod = target_priority_mod * 0.5
								end
							end

							target_priority = target_priority / target_priority_mod
							if not best_target_priority or best_target_priority > target_priority then
								local cop_key_time = BB.cops_to_intimidate[u_key]
								local intimidation_in_progress = cop_key_time and data.t - cop_key_time < BB.grace_period
								if not intimidation_in_progress then
									best_target = attention_data
									best_target_priority = target_priority
									best_target_reaction = reaction
								end
							end
						end
					end
				end
			end
		end
		return best_target, best_target_priority, best_target_reaction
	end

	function TeamAILogicIdle._find_intimidateable_civilians(criminal, use_default_shout_shape, max_angle, max_dis)
		local best_civ
		local intimidateable_civilians = {}
		if use_default_shout_shape then
			max_angle = 90
			max_dis = 1200
		end
		max_angle = max_angle or 90
		max_dis = max_dis or 1200
		local crim_mov = criminal:movement()
		local head_pos = crim_mov:m_head_pos()
		local look_vec = crim_mov:m_rot():y()
		local my_tracker = crim_mov:nav_tracker()
		local chk_vis_func = my_tracker.check_visibility
		local slotmask = managers.slot:get_mask("AI_visibility")
		for u_key, u_char in pairs(managers.enemy:all_civilians()) do
			if chk_vis_func(my_tracker, u_char.tracker) then
				local unit = u_char.unit
				local unit_mov = unit:movement()
				local u_head_pos = unit_mov:m_head_pos()
				local vec = u_head_pos - head_pos
				if mvec3_norm(vec) <= max_dis and mvec3_angle(vec, look_vec) <= max_angle then
					local ray = W:raycast("ray", head_pos, u_head_pos, "slot_mask", slotmask, "ray_type", "ai_vision")
					if not ray then
						if u_char.char_tweak.intimidateable and not unit:base().unintimidateable then
							local anim_data = unit:anim_data()
							local unit_data = unit:unit_data()
							if not anim_data.unintimidateable and not unit:brain():is_tied() and not (unit_data and unit_data.disable_shout) then
								if not unit_mov:cool() and not anim_data.drop then
									intimidateable_civilians[#intimidateable_civilians + 1] = { unit = unit, key = u_key, inv_wgt = 1 }
									if not best_civ then
										best_civ = unit
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
				if CopLogicBase.is_alert_aggressive(alert_type) then
					data.unit:movement():set_cool(false)
				end
			end
			return old_onalert(data, alert_data, ...)
		end
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then
	local W = World
	local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
	local mvec3_angle = mvector3.angle
	local mvec3_norm = mvector3.normalize
	local math_ceil = math.ceil

	function TeamAILogicAssault.find_enemy_to_mark(enemies, my_unit)
		local best_nmy, best_nmy_wgt
		if my_unit then
			local player_manager = managers.player
			local get_contour = player_manager:get_contour_for_marked_enemy()
			local has_ap = player_manager:has_category_upgrade("team", "crew_ai_ap_ammo")
			local head_pos = my_unit:movement():m_head_pos()
			for _, attention_info in pairs(enemies) do
				if attention_info.identified and (attention_info.verified or attention_info.nearly_visible) then
					local att_unit = attention_info.unit
					if att_unit:in_slot(12, 25) then
						local reaction = attention_info.reaction
						if reaction and reaction >= REACT_COMBAT then
							local char_tweak = attention_info.char_tweak
							local is_turret = attention_info.is_deployable
							if (char_tweak and char_tweak.priority_shout) or is_turret then
								local dis = attention_info.verified_dis
								if dis <= 3000 then
									local is_shield = attention_info.is_shield
									local shielded = W:raycast("ray", head_pos, attention_info.m_head_pos, "ignore_unit", { my_unit }, "slot_mask", 8)
									local can_hit = has_ap or dis <= 200 or not shielded
									if not is_shield or can_hit then
										if (not best_nmy_wgt) or best_nmy_wgt > dis then
											local u_contour = att_unit:contour()
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
		local mark_base = to_mark:base()
		local is_turret = mark_base.sentry_gun
		if play_sound then
			local sound_name = is_turret and "f44" or (mark_base:char_tweak() and mark_base:char_tweak().priority_shout)
			if sound_name then
				criminal:sound():say(sound_name .. "x_any", true, true)
			end
		end
		if play_action and not criminal:movement():chk_action_forbidden("action") then
			local new_action = { type = "act", variant = "arrest", body_part = 3, align_sync = true }
			if criminal:brain():action_request(new_action) then
				data.internal_data.gesture_arrest = true
			end
		end
		to_mark:contour():add(is_turret and "mark_unit_dangerous" or "mark_enemy", true)
	end

	function TeamAILogicAssault.check_smart_reload(data)
		local unit = data.unit
		if unit and not unit:anim_data().reload and not unit:movement():chk_action_forbidden("reload") then
			local current_wep = unit:inventory():equipped_unit()
			if current_wep then
				local ammo_max, ammo = current_wep:base():ammo_info()
				
				local nearby_threats = 0
				local closest_threat = math.huge
				for _, u_char in pairs(data.detected_attention_objects) do
					if u_char.identified and u_char.verified and u_char.unit:in_slot(12) then
						nearby_threats = nearby_threats + 1
						if u_char.verified_dis < closest_threat then
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
						unit:brain():action_request({ type = "reload", body_part = 3 })
					end
				end
			end
		end
	end

	local function _do_melee(data, criminal)
		local current_wep = criminal:inventory():equipped_unit()
		local crim_mov = criminal:movement()
		local my_pos = crim_mov:m_head_pos()
		local look_vec = crim_mov:m_rot():y()
		local detected_obj = data.detected_attention_objects
		
		local current_ammo_ratio = 1
		if current_wep then
			local ammo_max, ammo = current_wep:base():ammo_info()
			current_ammo_ratio = ammo / ammo_max
		end

		if current_ammo_ratio > 0.5 then
			return
		end
		
		local best_melee_target = nil
		local best_melee_priority = 0
		
		for _, u_char in pairs(detected_obj) do
			if u_char.identified then
				local unit = u_char.unit
				if unit:in_slot(12) and u_char.verified and u_char.verified_dis <= 200 then
					local unit_pos = u_char.m_head_pos
					local vec = unit_pos - my_pos
					if mvec3_angle(vec, look_vec) <= 60 then
						local melee_priority = 0
						
						if u_char.is_shield then
							melee_priority = 10
						elseif not u_char.char_tweak.priority_shout then
							if unit:inventory():get_weapon() and not unit:anim_data().hurt then
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
		
		if best_melee_target then
			local unit = best_melee_target.unit
			local damage = unit:character_damage()
			local health_damage = math_ceil(damage._HEALTH_INIT / 2)
			local vec = best_melee_target.m_head_pos - my_pos
			local col_ray = { ray = -vec, body = unit:body("body"), position = best_melee_target.m_head_pos }
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
				damage:damage_melee(damage_info)
			else
				damage_info.knock_down = true
				damage:damage_bullet(damage_info)
			end
			
			crim_mov:play_redirect("melee")
			managers.network:session():send_to_peers("play_distance_interact_redirect", criminal, "melee")
		end
	end

	local function _throw_conc(data, criminal)
		if not BB:get("conc", false) then
			return
		end
		local conc_tweak = tweak_data.blackmarket.projectiles.concussion
		if not conc_tweak or not conc_tweak.unit then
			return
		end
		local pkg_ready = managers.dyn_resource:is_resource_ready(Idstring("unit"), Idstring(conc_tweak.unit), managers.dyn_resource.DYN_RESOURCES_PACKAGE)
		if not pkg_ready then
			return
		end

		local target_unit, target_dis
		local close_enemies = 0
		local shield_count = 0
		local special_count = 0
		local crim_mov = criminal:movement()
		local from_pos = crim_mov:m_head_pos()
		local look_vec = crim_mov:m_rot():y()
		local enemy_cluster = {}
		
		for _, u_char in pairs(data.detected_attention_objects) do
			if u_char.identified and u_char.verified and u_char.verified_dis <= 3000 then
				local unit = u_char.unit
				if unit:in_slot(12) then
					local vec = u_char.m_head_pos - from_pos
					if mvec3_angle(vec, look_vec) <= 90 then
						local tweak_table = unit:base()._tweak_table
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

		local should_throw = false
		
		if close_enemies >= 5 then
			should_throw = true
		end
		
		if shield_count >= 2 then
			should_throw = true
		end
		
		if special_count >= 2 and close_enemies >= 3 then
			should_throw = true
		end
		
		if should_throw then
			local best_cluster_pos = nil
			local best_cluster_count = 0
			
			for i, u_char1 in ipairs(enemy_cluster) do
				local cluster_count = 0
				local cluster_pos = u_char1.m_head_pos
				
				for j, u_char2 in ipairs(enemy_cluster) do
					if i ~= j then
						local dist = mvector3.distance(u_char1.m_head_pos, u_char2.m_head_pos)
						if dist <= 500 then
							cluster_count = cluster_count + 1
						end
					end
				end
				
				if cluster_count > best_cluster_count then
					best_cluster_count = cluster_count
					best_cluster_pos = cluster_pos
					target_unit = u_char1.unit
				end
			end
			
			if target_unit and best_cluster_count >= 2 then
				local mvec_spread_direction = best_cluster_pos - from_pos
				local cc_unit = ProjectileBase.spawn(conc_tweak.unit, from_pos, Rotation())
				mvec3_norm(mvec_spread_direction)
				crim_mov:play_redirect("throw_grenade")
				managers.network:session():send_to_peers("play_distance_interact_redirect", criminal, "throw_grenade")
				criminal:sound():say("g43", true, true)
				cc_unit:base():throw({ dir = mvec_spread_direction, owner = criminal })
				data.internal_data._conc_t = data.t + 4
			end
		end
	end

	if Network:is_server() then
		local old_update = TeamAILogicAssault.update
		function TeamAILogicAssault.update(data, ...)
			local t = TimerManager:game():time()
			local my_data = data.internal_data

			if (not my_data._conc_t) or (my_data._conc_t + 1 < t) then
				my_data._conc_t = t
				_throw_conc(data, data.unit)
			end

			if (not my_data.melee_t) or (my_data.melee_t + 0.5 < t) then
				my_data.melee_t = t
				_do_melee(data, data.unit)
			end

			if (not my_data.reload_t) or (my_data.reload_t + 1 < t) then
				my_data.reload_t = t
				TeamAILogicAssault.check_smart_reload(data)
			end
			
			return old_update(data, ...)
		end
	end

	local old_exit = TeamAILogicAssault.exit
	function TeamAILogicAssault.exit(data, ...)
		TeamAILogicAssault.check_smart_reload(data)
		return old_exit(data, ...)
	end
end

if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then
	local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
	local mvec3_angle = mvector3.angle

	local function _find_enemy_to_intimidate(data)
		local best_nmy, best_dis
		local look_vec = data.unit:movement():m_rot():y()
		local has_room = managers.groupai:state():has_room_for_police_hostage()
		local consider_all = BB:get("dom", false)
		local targets

		if consider_all then
			targets = data.detected_attention_objects
		else
			targets = {}
			for u_key, t in pairs(BB.cops_to_intimidate) do
				if data.t - t < BB.grace_period then
					targets[u_key] = data.detected_attention_objects[u_key]
				end
			end
		end

		for _, u_char in pairs(targets) do
			if u_char and u_char.identified and u_char.verified then
				local unit = u_char.unit
				if unit:in_slot(12, 22) then
					local intim_dis = u_char.verified_dis
					if intim_dis and intim_dis <= 1200 then
						local vec = u_char.m_pos - data.m_pos
						if mvec3_angle(vec, look_vec) <= 90 then
							local char_tweak = u_char.char_tweak
							if char_tweak.surrender and not char_tweak.priority_shout then
								if unit:inventory():get_weapon() then
									local anim_data = unit:anim_data()
									if has_room or (anim_data.hands_back or anim_data.surrender) then
										local is_hurt = unit:character_damage():health_ratio() < 1
										local intim_priority = anim_data.hands_back and 3 or anim_data.surrender and 2 or (is_hurt and 1)
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

		return best_nmy
	end

	local function _intimidate_law_enforcement(data, intim_unit, play_action)
		local anim_data = intim_unit:anim_data()
		local act_name, sound_name
		if anim_data.hands_back then
			act_name = "arrest"
			sound_name = "l03x_sin"
		elseif anim_data.surrender then
			act_name = "arrest"
			sound_name = "l02x_sin"
		else
			act_name = "gesture_stop"
			sound_name = "l01x_sin"
		end

		local unit = data.unit
		unit:sound():say(sound_name, true, true)
		if play_action and not unit:movement():chk_action_forbidden("action") then
			if unit:brain():action_request({ type = "act", variant = act_name, body_part = 3, align_sync = true }) then
				data.internal_data.gesture_arrest = true
			end
		end
		intim_unit:brain():on_intimidated(1, unit)
	end

	local function _interact_check(data)
		local unit = data.unit
		if unit:character_damage():need_revive() then
			return
		end
		local anim_data = unit:anim_data()
		if anim_data.tased then
			return
		end
		local my_data = data.internal_data
		if my_data.acting then
			return
		end

		local t = data.t
		if unit:sound():speaking() then
			return
		end
		if my_data._intimidate_t and my_data._intimidate_t + 2 >= t then
			return
		end

		my_data._intimidate_t = t
		local is_reloading_ok = not anim_data.reload
		local civ = TeamAILogicIdle.find_civilian_to_intimidate(unit, 90, 1200)
		local dom = _find_enemy_to_intimidate(data)
		local nmy = TeamAILogicAssault.find_enemy_to_mark(data.detected_attention_objects, unit)

		if civ then
			TeamAILogicIdle.intimidate_civilians(data, unit, true, is_reloading_ok)
		elseif dom then
			_intimidate_law_enforcement(data, dom, is_reloading_ok)
		elseif nmy then
			if TeamAILogicAssault._mark_special_chk_t ~= math.huge and (not TeamAILogicBase._mark_t or TeamAILogicBase._mark_t + 2 < t) then
				TeamAILogicAssault.mark_enemy(data, unit, nmy, true, is_reloading_ok)
				TeamAILogicBase._mark_t = t
			end
		end
	end

	function TeamAILogicBase._set_attention_obj(data, new_att_obj, new_reaction)
		_interact_check(data)
		data.attention_obj = new_att_obj
		if new_att_obj then
			new_att_obj.reaction = new_reaction or new_att_obj.reaction
		end
	end

	function TeamAILogicBase._get_logic_state_from_reaction(data, reaction)
		if not reaction or reaction < REACT_COMBAT then
			return "idle"
		end
		return "assault"
	end
end

if RequiredScript == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
	if BB:get("combat", false) then
		local math_lerp = math.lerp
		local old_shoot = CopActionShoot._get_shoot_falloff
		function CopActionShoot:_get_shoot_falloff(target_dis, falloff, ...)
			if self and self._unit:in_slot(16) then
				local i = #falloff
				local data = falloff[i]
				for i_range = 1, #falloff do
					local range_data = falloff[i_range]
					if range_data and target_dis < range_data.r then
						i = i_range
						data = range_data
						break
					end
				end
				if i > 1 then
					local prev_data = falloff[i - 1]
					local t = (target_dis - prev_data.r) / (data.r - prev_data.r)
					local n_data = {
						dmg_mul = math_lerp(prev_data.dmg_mul, data.dmg_mul, t),
						r = target_dis,
						acc = { math_lerp(prev_data.acc[1], data.acc[1], t), math_lerp(prev_data.acc[2], data.acc[2], t) },
						recoil = { math_lerp(prev_data.recoil[1], data.recoil[1], t), math_lerp(prev_data.recoil[2], data.recoil[2], t) },
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
		local char_tweak = deep_clone(self._logic_data.char_tweak)
		char_tweak.access = "teamAI1"
		char_tweak.always_face_enemy = true
		self._logic_data.char_tweak = char_tweak
	end
end

if RequiredScript == "lib/units/enemies/cop/copdamage" then
	local bb_original_copdamage_damagemelee = CopDamage.damage_melee
	function CopDamage:damage_melee(attack_data, ...)
		if attack_data.variant == "taser_tased" then
			BB:add_cop_to_intimidation_list(self._unit:key())
		end
		return bb_original_copdamage_damagemelee(self, attack_data, ...)
	end

	local bb_original_copdamage_syncdamagemelee = CopDamage.sync_damage_melee
	function CopDamage:sync_damage_melee(variant, ...)
		if variant == 5 then
			BB:add_cop_to_intimidation_list(self._unit:key())
		end
		return bb_original_copdamage_syncdamagemelee(self, variant, ...)
	end

	if BB:get("ammo", false) then
		local old_die = CopDamage.die
		function CopDamage:die(attack_data, ...)
			local attacker_unit = attack_data.attacker_unit
			if attacker_unit and attacker_unit:in_slot(16) and self._pickup == "ammo" then
				self:set_pickup(nil)
			end
			return old_die(self, attack_data, ...)
		end
	end

	if BB:get("combat", false) then
		local old_bullet = CopDamage.damage_bullet
		function CopDamage:damage_bullet(attack_data, ...)
			if self._unit:base():has_tag("sniper") then
				local attacker_unit = attack_data.attacker_unit
				if attacker_unit and attacker_unit:in_slot(16) then
					attack_data.damage = self._HEALTH_INIT
				end
			end
			return old_bullet(self, attack_data, ...)
		end
	end

	local old_stun = CopDamage.stun_hit
	function CopDamage:stun_hit(...)
		if self._unit:in_slot(16, 22) then
			return
		end
		return old_stun(self, ...)
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicbase" then
	if BB:get("reflex", false) then
		local REACT_COMBAT = AIAttentionObject.REACT_COMBAT
		local REACT_IDLE = AIAttentionObject.REACT_IDLE
		local W = World
		local old_upd = CopLogicBase._upd_attention_obj_detection

		function CopLogicBase._upd_attention_obj_detection(data, min_reaction, max_reaction, ...)
			local unit = data.unit
			if unit and unit:in_slot(16) then
				local t = data.t
				local my_key = data.key
				local detected_obj = data.detected_attention_objects
				local unit_mov = unit:movement()
				local my_pos = unit_mov:m_head_pos()
				local my_access = data.SO_access
				local my_team = data.team
				local slotmask = data.visibility_slotmask
				local my_tracker = unit_mov:nav_tracker()
				local chk_vis_func = my_tracker.check_visibility
				local all_attention_objects = managers.groupai:state():get_AI_attention_objects_by_filter(data.SO_access_str, my_team)

				for u_key, attention_info in pairs(all_attention_objects) do
					if u_key ~= my_key and not detected_obj[u_key] then
						local att_tracker = attention_info.nav_tracker
						if (not att_tracker) or chk_vis_func(my_tracker, att_tracker) then
							local att_handler = attention_info.handler
							if att_handler then
								local settings = att_handler:get_attention(my_access, min_reaction, max_reaction, my_team)
								if settings then
									local attention_pos = att_handler:get_detection_m_pos()
									local vis_ray = W:raycast("ray", my_pos, attention_pos, "slot_mask", slotmask, "ray_type", "ai_vision")
									if not vis_ray or vis_ray.unit:key() == u_key then
										local att_obj = CopLogicBase._create_detected_attention_object_data(t, unit, u_key, attention_info, settings)
										if att_obj then
											local is_enemy = attention_info.unit:in_slot(12, 25)
											local new_reaction = is_enemy and REACT_COMBAT or REACT_IDLE
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

			return old_upd(data, min_reaction, max_reaction, ...)
		end
	end
end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then
	if Network:is_server() then
		local old_enter = CopLogicIdle.enter
		function CopLogicIdle.enter(data, ...)
			old_enter(data, ...)
			if data.is_converted then
				TeamAILogicAssault.check_smart_reload(data)
			end
		end

		local old_intim = CopLogicIdle.on_intimidated
		function CopLogicIdle.on_intimidated(data, ...)
			local surrender = old_intim(data, ...)
			local unit = data.unit
			BB:add_cop_to_intimidation_list(unit:key())
			if surrender then
				unit:base():set_slot(unit, 22)
			end
			return surrender
		end

		local old_prio = CopLogicIdle._get_priority_attention
		function CopLogicIdle._get_priority_attention(data, attention_objects, reaction_func)
			local best_target, best_target_priority_slot, best_target_reaction = old_prio(data, attention_objects, reaction_func)
			if data.is_converted then
				best_target, best_target_priority_slot, best_target_reaction = TeamAILogicIdle._get_priority_attention(data, attention_objects)
			end
			return best_target, best_target_priority_slot, best_target_reaction
		end
	end
end

if RequiredScript == "lib/managers/mission/elementmissionend" then
	local is_offline = Global and Global.game_settings and Global.game_settings.single_player
	function ElementMissionEnd:on_executed(instigator)
		if not self._values.enabled then
			return
		end
		if self._values.state ~= "none" and managers.platform:presence() == "Playing" then
			if self._values.state == "success" then
				local num_winners = managers.network:session():amount_of_alive_players()
				if is_offline then
					num_winners = num_winners + managers.groupai:state():amount_of_winning_ai_criminals()
				end
				managers.network:session():send_to_peers("mission_ended", true, num_winners)
				game_state_machine:change_state_by_name("victoryscreen", {
					num_winners = num_winners,
					personal_win = alive(managers.player:player_unit())
				})
			elseif self._values.state == "failed" then
				managers.network:session():send_to_peers("mission_ended", false, 0)
				game_state_machine:change_state_by_name("gameoverscreen")
			elseif self._values.state == "leave" then
				MenuCallbackHandler:leave_mission()
			elseif self._values.state == "leave_safehouse" and instigator:base().is_local_player then
				MenuCallbackHandler:leave_safehouse()
			end
		elseif Application:editor() then
			managers.editor:output_error("Cant change to state " .. self._values.state .. " in mission end element " .. self._editor_name .. ".")
		end
		ElementMissionEnd.super.on_executed(self, instigator)
	end
end
