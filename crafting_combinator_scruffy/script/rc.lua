local E = require "script.error-handling"
local config = require 'config'
local util = require 'script.util'
local gui = require 'script.gui'
local recipe_selector = require 'script.recipe-selector'
local signals = require 'script.signals'

---@class RcControl
local _M = {}
local combinator_mt = {__index = _M}

-- index metamethod for global.cc.data to handle key not found cases
local global_data_mt = {
	__index = function(_, key)
		local tname = "global.rc.data"
		E.on_key_not_found(key, tname)
	end,
	__metatable = E
}

-- General housekeeping

function _M.init_global()
	storage.rc = storage.rc or {}
	storage.rc.data = storage.rc.data or {}
	storage.rc.ordered = storage.rc.ordered or {}
end

function _M.build_machine_cache()
	_M.item_map = {}
	_M.category_map = {}
	for name, prototype in pairs(game.entity_prototypes) do
		if prototype.crafting_categories and prototype.items_to_place_this then
			for category in pairs(prototype.crafting_categories) do
				_M.category_map[category] = _M.category_map[category] or {}
				for _, item in pairs(prototype.items_to_place_this) do
					_M.item_map[item.name] = {}
					table.insert(_M.category_map[category], item.name)
				end
			end
		end
	end
	for _, recipe in pairs(game.recipe_prototypes) do
		for _, product in pairs(recipe.products) do
			if _M.item_map[product.name] ~= nil then
				table.insert(_M.item_map[product.name], recipe.name)
			end
		end
	end
end

local _rc_slot_count = nil
function _M.get_rc_slot_count()
	if _rc_slot_count == nil then _rc_slot_count = game.entity_prototypes[config.RC_PROXY_NAME].item_slot_count; end
	return _rc_slot_count
end

function _M.on_load(skip_set_mt)
	local global_data = storage.rc.data
	if skip_set_mt then return end
--	setmetatable(global_data, global_data_mt)
	for _, combinator in pairs(global_data) do setmetatable(combinator, combinator_mt); end
end


-- Lifecycle events

function _M.create(entity, tags, migrated_state)
	local combinator = setmetatable({
		entityUID = entity.unit_number,
		entity = entity,
		output_proxy = (migrated_state and migrated_state.output_proxy) or entity.surface.create_entity {
			name = config.RC_PROXY_NAME,
			position = entity.position,
			force = entity.force,
			create_build_effect_smoke = false,
		},
		input_control_behavior = (migrated_state and migrated_state.input_control_behavior) or entity.get_or_create_control_behavior(),
		settings = util.merge_combinator_settings(config.RC_DEFAULT_SETTINGS, tags, migrated_state),
		last_signal = nil,
		last_name = nil,
		last_count = 0
	}, combinator_mt) --[[@as RcState]]
	


	local rcon1 = entity.get_wire_connector(defines.wire_connector_id.combinator_output_red,false)
	local rcon2 = combinator.output_proxy.get_wire_connector(defines.wire_connector_id.circuit_red,false)
	rcon1.connect_to(rcon2,false,defines.wire_origin.script)


	local gcon1 = entity.get_wire_connector(defines.wire_connector_id.combinator_output_green,false)
	local gcon2 = combinator.output_proxy.get_wire_connector(defines.wire_connector_id.circuit_green,false)
	gcon1.connect_to(rcon2,false,defines.wire_origin.script)


	local test=1



--[[
	entity.connect_neighbour {
		wire = defines.wire_type.red,
	target_entity = combinator.output_proxy,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
	}



	entity.connect_neighbour {
		wire = defines.wire_type.green,
		target_entity = combinator.output_proxy,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
	}
	combinator.output_proxy.destructible = false
	combinator.control_behavior = combinator.output_proxy.get_or_create_control_behavior() --[[@as LuaControlBehavior]]

	--]]
	
	storage.main_uid_by_part_uid[combinator.output_proxy.unit_number] = combinator.entityUID
	storage.rc.data[entity.unit_number] = combinator
	table.insert(storage.rc.ordered, combinator)

	return combinator
end

---Destroy method for rc state
---@param entity unit_number|LuaEntity
function _M.destroy(entity)
	local unit_number = (type(entity) == "number" and entity) or entity.unit_number

	-- closes gui for entity if it is opened
	gui.destroy_entity_gui(unit_number)

	signals.cache.drop(unit_number)
	
	storage.rc.data[unit_number] = nil
	for k, v in pairs(storage.rc.ordered) do
		if v.entityUID == unit_number then
			table.remove(storage.rc.ordered, k)
			break
		end
	end
end

---@param state RcState
function _M.check_entities(state)
	local signals_cache = storage.signals.cache[state.entityUID]
	if signals_cache then signals.check_signal_cache_entities(signals_cache, state.entityUID) end

	if state.entity and state.entity.valid
	and state.output_proxy and state.output_proxy.valid then
		return true
	else
		log({"", "RC state destroyed due to invalid entity ", state.entityUID})
		_M.destroy(state.entityUID)
	end
end

---@param self RcState
function _M:update(forced)
	if not self:check_entities() then return end
	if forced then
		self.last_signal = nil
		self.last_name = nil
		self.last_count = 0
	end
	
	if self.settings.mode == 'rec' or self.settings.mode == 'use' then self:find_recipe()
	elseif self.settings.mode == 'mac' then self:find_machines(forced)
	else self:find_ingredients_and_products(forced); end
end


local DUMMY_SIGNAL = {type = 'virtual', name = config.TIME_SIGNAL_NAME}
local param_cache = {}
local function get_params(size)
	local params = param_cache[size]
	if not params then
		params = {}
		for i = 1, size do params[i] = {index = i}; end
		param_cache[size] = params
	end
	return params
end

---@param self RcState
function _M:find_recipe()
	local changed, recipes, count, signal = recipe_selector.get_recipes(
		self.entity, defines.circuit_connector_id.combinator_input,
		self.settings.mode == 'rec' and 'products' or 'ingredients',
		self.last_signal, self.settings.multiply_by_input and self.last_count or nil, self.entityUID
	)
	
	if not changed then return; end
	self.last_signal = signal
	self.last_count = count
	
	local recipes_count = #recipes
	local params = get_params(recipes_count)
	if recipes_count > 0 then
		local index = 1
		local slots = _M.get_rc_slot_count()
		count = self.settings.multiply_by_input and count or 1
		local round = self.settings.mode == 'use' and math.floor or math.ceil
		for i=1,recipes_count do
			local result = recipes[i]
			local param = params[i]
			if not result.recipe.hidden and result.recipe.enabled then
				param.signal = recipe_selector.get_signal(result.recipe.name)
				param.count = self.settings.differ_output and index or (self.settings.divide_by_output and round(count/result.amount) or count)
				param.index = index
				index = index + 1
			elseif slots > index then
				param.signal = DUMMY_SIGNAL
				param.count = 0
				param.index = slots
				slots = slots - 1
			end
		end
	end
	self.control_behavior.parameters = params
end

---@param self RcState
function _M:find_ingredients_and_products()
	local changed, recipe, input_count = recipe_selector.get_recipe(
		self.entity,
		defines.circuit_connector_id.combinator_input,
		self.last_name,
		self.settings.multiply_by_input and self.last_count or nil,
		self.entityUID
	)
	
	if not changed then return; end
	self.last_name = recipe and recipe.name
	self.last_count = input_count
	
	if recipe and (recipe.hidden or not recipe.enabled) then recipe = nil; end
	
	local params = {}
	
	if recipe then
		local crafting_multiplier = self.settings.multiply_by_input and input_count or 1
		---@type Ingredient[]|Product[]|false
		local objects = (self.settings.mode == 'prod' and recipe.products) or (self.settings.mode == 'ing' and recipe.ingredients)
		if not objects then goto recipe_time end
		for i=1,#objects do
			local obj = objects[i]
			local amount = math.ceil(
				tonumber(obj.amount or obj.amount_min or obj.amount_max)
				* crafting_multiplier
				* (tonumber(obj.probability) or 1)
			)
			params[i] = {
				signal = {type = obj.type, name = obj.name},
				count = self.settings.differ_output and i or util.simulate_overflow(amount),
				index = i,
			}
		end
		::recipe_time::
		if self.settings.time_multiplier == 0 then goto exit end
		local count = util.simulate_overflow(math.floor(tonumber(recipe.energy) * self.settings.time_multiplier * crafting_multiplier))
		if count == 0 then goto exit end
		params[#params+1] = {
			signal = {type = 'virtual', name = config.TIME_SIGNAL_NAME},
			count = count,
			index = _M.get_rc_slot_count(),
		}
		::exit::
	end
	
	self.control_behavior.parameters = params
end

---@param self RcState
function _M:find_machines()
	local changed, recipe, input_count = recipe_selector.get_recipe(
		self.entity,
		defines.circuit_connector_id.combinator_input,
		self.last_name,
		self.settings.multiply_by_input and self.last_count or nil,
		self.entityUID
	)
	
	if not changed then return; end
	self.last_name = recipe and recipe.name
	self.last_count = input_count
	
	if recipe and (recipe.hidden or not recipe.enabled) then recipe = nil; end
	
	if _M.item_map == nil then _M.build_machine_cache(); end

	local params = {}
	local index = 1
	if recipe and recipe.category then
		for _, item in pairs(_M.category_map[recipe.category] or {}) do
			for _, recipe in pairs(_M.item_map[item]) do
				local mac_res = self.entity.force.recipes[recipe]
				if mac_res and not mac_res.hidden and mac_res.enabled then
					table.insert(params, {
						signal = recipe_selector.get_signal(item),
						count = self.settings.multiply_by_input and input_count or
							self.settings.differ_output and index or 1,
						index = index,
					})
					index = index + 1
					break
				end
			end
		end
	end
	self.control_behavior.parameters = params
end

---@param self RcState
function _M:open(player_index)
	local root = gui.entity(self.entity, {
		gui.section {
			name = 'mode',
			gui.radio('ing', self.settings.mode, {locale='mode-ing', tooltip=true}),
			gui.radio('prod', self.settings.mode, {locale='mode-prod', tooltip=true}),
			gui.radio('use', self.settings.mode, {locale='mode-use', tooltip=true}),
			gui.radio('rec', self.settings.mode, {locale='mode-rec', tooltip=true}),
			gui.radio('mac', self.settings.mode, {locale='mode-mac', tooltip=true}),
		},
		gui.section {
			name = 'misc',
			gui.checkbox('multiply-by-input', self.settings.multiply_by_input, {tooltip=true}),
			gui.checkbox('divide-by-output', self.settings.divide_by_output, {tooltip=true}),
			gui.checkbox('differ-output', self.settings.differ_output, {tooltip=true}),
			gui.number_picker('time-multiplier', self.settings.time_multiplier),
		}
	}):open(player_index)
	
	self:update_disabled_checkboxes(root)
end

---@param self RcState
function _M:on_checked_changed(name, is_selected, element)
	local category, name = name:gsub(':.*$', ''), name:gsub('^.-:', ''):gsub('-', '_')
	if category == 'mode' then
		self.settings.mode = name
		gui.on_radiobutton_selected(element, category, name)
	end
	if category == 'misc' then self.settings[name] = is_selected; end
	
	self:update_disabled_checkboxes(gui.get_root(element))
	self:update(true)
end

---@param self RcState
function _M:update_disabled_checkboxes(root)
	self:disable_checkbox(root, 'misc:divide-by-output', 'divide_by_output',
			(self.settings.mode == 'rec' or self.settings.mode == 'use') and not self.settings.differ_output)
	self:disable_checkbox(root, 'misc:multiply-by-input', 'multiply_by_input',
			not self.settings.divide_by_output and not self.settings.differ_output,
			self.settings.divide_by_output or self.settings.multiply_by_input)
	self:disable_checkbox(root, 'misc:differ-output', 'differ_output',
			not self.settings.multiply_by_input)
end

---@param self RcState
function _M:disable_checkbox(root, name, setting_name, enable, set_state)
	set_state = set_state or false
	local checkbox = gui.find_element(root, gui.name(self.entity, name))
	if checkbox.enabled ~= enable then
		checkbox.enabled = enable
		checkbox.state = set_state
		self.settings[setting_name] = set_state
	end
end

---@param self RcState
function _M:on_text_changed(name, text)
	if name == 'misc:time-multiplier:value' then
		self.settings.time_multiplier = tonumber(text) or self.settings.time_multiplier
		self:update(true)
	end
end

---@param self RcState
function _M:update_inner_positions()
	self.output_proxy.teleport(self.entity.position)
end


return _M
