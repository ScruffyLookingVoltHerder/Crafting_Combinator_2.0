require 'script.bootstrap'

local config = require 'config'
local cc_control = require 'script.cc'
local rc_control = require 'script.rc'
local signals = require 'script.signals'
local util = require 'script.util'
local gui = require 'script.gui'
local blueprint = require 'script.blueprint'
local migration_helper = require 'script.migration-helper'
local clone_helper = require 'script.clone-helper'

local cc_rate = settings.global[config.REFRESH_RATE_CC_NAME].value
local rc_rate = settings.global[config.REFRESH_RATE_RC_NAME].value

local function enable_recipes()
	for _, force in pairs(game.forces) do
		if force.technologies['circuit-network'].researched then
			force.recipes[config.CC_NAME].enabled = true
			force.recipes[config.RC_NAME].enabled = true
		end
	end
end

local function on_load(forced)
	if not forced and next(late_migrations.__migrations) ~= nil then return; end

	cc_control.on_load()
	rc_control.on_load()
	signals.on_load()
	clone_helper.on_load()
	
	if remote.interfaces['PickerDollies'] then
		script.on_event(remote.call('PickerDollies', 'dolly_moved_entity_id'), function(event)
			local entity = event.moved_entity
			local combinator
			if entity.name == config.CC_NAME then combinator = global.cc.data[entity.unit_number]
			elseif entity.name == config.RC_NAME then combinator = global.rc.data[entity.unit_number]; end
			if combinator then combinator:update_inner_positions(); end
		end)
	end
end

local function init_global()
	global.delayed_blueprint_tag_state = global.delayed_blueprint_tag_state or {}
	global.clone_placeholder = global.clone_placeholder or {}
	global.main_uid_by_part_uid = global.main_uid_by_part_uid or {}
end

script.on_init(function()
	init_global()
	cc_control.init_global()
	rc_control.init_global()
	signals.init_global()
	on_load(true)
end)
script.on_load(on_load)

script.on_configuration_changed(function(changes)
	migration_helper.migrate(changes)
	late_migrations(changes)
	on_load(true)
	enable_recipes()
end)

local function on_built(event)
	local entity = event.created_entity or event.entity
	if not (entity and entity.valid) then return end

	local entity_name = entity.name
	if entity_name == config.CC_NAME then
		local tags = event.tags
		cc_control.create(entity, tags);
	elseif entity_name == config.RC_NAME then
		local tags = event.tags
		rc_control.create(entity, tags);
	else
		local entity_type = entity.type
		if entity_type == 'assembling-machine' then
			cc_control.update_assemblers(entity.surface, entity);
		else -- util.CONTAINER_TYPES[entity.type]
			cc_control.update_chests(entity.surface, entity);
		end
	end

	-- blueprint events
	blueprint.handle_event(event)
end

local function on_cloned(event)
	local entity = event.destination
	if not (entity and entity.valid) then return end

	-- main or part
	if entity.name == config.CC_NAME or entity.name == config.RC_NAME then
		clone_helper.on_main_cloned(event)
	elseif entity.name == config.MODULE_CHEST_NAME or entity.name == config.RC_PROXY_NAME then
		clone_helper.on_part_cloned(event)
	end

	-- assembler and containers
	local entity_type = entity.type
	if entity_type == 'assembling-machine' then
		cc_control.update_assemblers(entity.surface, entity);
	elseif util.CONTAINER_TYPES[entity.type] then
		cc_control.update_chests(entity.surface, entity);
	end
end

local function on_destroyed(event) -- on_entity_died, on_player_mined_entity, on_robot_mined_entity, script_raised_destroy
	local entity = event.entity
	if not (entity and entity.valid) then return end

	-- cached properties
	local entity_name = entity.name
	local entity_type = entity.type
	local entity_surface = entity.surface
	local event_name = event.name

	-- Notify nearby combinators that a container was destroyed
	if util.CONTAINER_TYPES[entity_type] then
		cc_control.update_chests(entity_surface, entity, true)
	end

	if entity_name == config.CC_NAME then
		local uid = entity.unit_number
		local combinator = global.cc.data[uid]
		if event_name == defines.events.on_player_mined_entity then
			-- Need to mine module chest first, success == true
			if not cc_control.mine_module_chest(uid, event.player_index) then
				-- Unable to mine module chest, cc cloned and replaced - remove cc from buffer, then return
				event.buffer.remove({name=config.CC_NAME, count=1})
				return
			end
		end
		if event_name == defines.events.on_entity_died or event_name == defines.events.script_raised_destroy then
			cc_control.update_chests(entity_surface, combinator.module_chest, true)
			combinator.module_chest.destroy()
		end
		if event_name ~= defines.events.on_entity_died then -- need state data until post_entity_died
			cc_control.destroy(entity)
		end
	elseif entity_name == config.MODULE_CHEST_NAME then
		local uid = entity.unit_number
		if event_name == defines.events.on_player_mined_entity then
			-- This should only be called from cc's mine_module_chest() method after mine_entity() is successful
			-- Remove one cc from buffer because cc is the mine product
			event.buffer.remove({name=config.CC_NAME, count=1})
		elseif event_name == defines.events.on_robot_mined_entity or event_name == defines.events.script_raised_destroy then
			local cc_entity = global.cc.data[global.main_uid_by_part_uid[uid]].entity
			if cc_entity and cc_entity.valid then
				cc_control.destroy(entity)
				cc_entity.destroy()
			end
		end
		global.main_uid_by_part_uid[uid] = nil
	elseif entity_name == config.RC_NAME then
		if event_name ~= defines.events.on_entity_died then -- need state data until post_entity_died
			rc_control.destroy(entity)
		end
	else
		if entity_type == 'assembling-machine' then
			cc_control.update_assemblers(entity_surface, entity, true)
		end
	end
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting == config.REFRESH_RATE_CC_NAME then
		cc_rate = settings.global[config.REFRESH_RATE_CC_NAME].value
	elseif event.setting == config.REFRESH_RATE_RC_NAME then
		rc_rate = settings.global[config.REFRESH_RATE_RC_NAME].value
	end
end)

local function run_update(tab, tick, rate)
	for i = tick % (rate + 1) + 1, #tab, (rate + 1) do tab[i]:update(); end
end
script.on_event(defines.events.on_tick, function(event)
	if global.cc.inserter_empty_queue[event.tick] then
		for _, e in pairs(global.cc.inserter_empty_queue[event.tick]) do
			if e.entity.valid and e.assembler and e.assembler.valid then e:empty_inserters(); end
		end
		global.cc.inserter_empty_queue[event.tick] = nil
	end
	
	run_update(global.cc.ordered, event.tick, cc_rate)
	run_update(global.rc.ordered, event.tick, rc_rate)
end)

script.on_nth_tick(600, function(event)
	-- clean up partially cloned entities?
	clone_helper.on_nth_tick(event)
end)

script.on_event(defines.events.on_player_rotated_entity, function(event)
	if event.entity.name == config.CC_NAME then
		local combinator = global.cc.data[event.entity.unit_number]
		combinator:find_assembler()
		combinator:find_chest()
	end
end)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
	local source, destination
	if event.source.name == config.CC_NAME and event.destination.name == config.CC_NAME then
		source, destination = global.cc.data[event.source.unit_number], global.cc.data[event.destination.unit_number]
	elseif event.source.name == config.RC_NAME and event.destination.name == config.RC_NAME then
		source, destination = global.rc.data[event.source.unit_number], global.rc.data[event.destination.unit_number]
	else return; end
	
	destination.settings = util.deepcopy(source.settings)
	if destination.entity.name == config.RC_NAME then destination:update(true)
	elseif destination.entity.name == config.CC_NAME then destination:copy(source); end
end)

-- filter for built and destroyed events
local filter_built_destroyed = {}

-- filter: cc or rc
table.insert(filter_built_destroyed, {filter = "name", name = config.CC_NAME})
table.insert(filter_built_destroyed, {filter = "name", name = config.RC_NAME})

-- filter: module-chest
table.insert(filter_built_destroyed, {filter = "name", name = config.MODULE_CHEST_NAME})

-- filter: assembling-machine
table.insert(filter_built_destroyed, {filter = "type", type = 'assembling-machine'})

-- filter: containers
for container, _ in pairs(util.CONTAINER_TYPES) do
	table.insert(filter_built_destroyed, {filter = "type", type = container})
end

-- filter for clone
local filter_cloned = util.deepcopy(filter_built_destroyed)
table.insert(filter_cloned, {filter = "name", name = config.RC_PROXY_NAME})

-- entity built events
script.on_event(defines.events.on_built_entity, on_built, filter_built_destroyed)
script.on_event(defines.events.on_robot_built_entity, on_built, filter_built_destroyed)
script.on_event(defines.events.script_raised_built, on_built, filter_built_destroyed)
script.on_event(defines.events.script_raised_revive, on_built, filter_built_destroyed)
script.on_event(defines.events.on_entity_cloned, on_cloned, filter_cloned)

-- entity destroyed events
script.on_event(defines.events.on_entity_died, on_destroyed, filter_built_destroyed)
script.on_event(defines.events.on_player_mined_entity, on_destroyed, filter_built_destroyed)
script.on_event(defines.events.on_robot_mined_entity , on_destroyed, filter_built_destroyed)
script.on_event(defines.events.script_raised_destroy, on_destroyed, filter_built_destroyed)

-- additional blueprint events
script.on_event(defines.events.on_player_setup_blueprint, blueprint.handle_event)
script.on_event(defines.events.on_post_entity_died, blueprint.handle_event, {{filter = "type", type = "constant-combinator"}, {filter = "type", type = "arithmetic-combinator"}})

-- decontruction events
script.on_event(
	defines.events.on_marked_for_deconstruction,
	function(event) cc_control.on_module_chest_marked_for_decon(event.entity) end,
	{{filter = "name", name = config.MODULE_CHEST_NAME}}
)
script.on_event(
	defines.events.on_cancelled_deconstruction,
	function(event) cc_control.on_module_chest_cancel_decon(event.entity) end,
	{{filter = "name", name = config.MODULE_CHEST_NAME}}
)

-- GUI events
script.on_event(defines.events.on_gui_opened, function(event)
	local entity = event.entity
	if entity then
		if entity.name == config.CC_NAME then global.cc.data[entity.unit_number]:open(event.player_index); end
		if entity.name == config.RC_NAME then global.rc.data[entity.unit_number]:open(event.player_index); end
	end
end)
script.on_event(defines.events.on_gui_closed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		element.destroy()
	end

	-- blueprint gui
	blueprint.handle_event(event)
end)
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		
		if gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_checked_changed(element_name, element.state, element)
		end
		if gui_name == 'recipe-combinator' then
			global.rc.data[unit_number]:on_checked_changed(element_name, element.state, element)
		end
	end
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		if gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_selection_changed(element_name, element.selected_index)
		end
	end
end)
script.on_event(defines.events.on_gui_text_changed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		if gui_name == 'recipe-combinator' then
			global.rc.data[unit_number]:on_text_changed(element_name, element.text)
		elseif gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_text_changed(element_name, element.text)
		end
	end
end)
script.on_event(defines.events.on_gui_click, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		local gui_name, unit_number, element_name = gui.parse_entity_gui_name(element.name)
		if gui_name == 'crafting-combinator' then
			global.cc.data[unit_number]:on_click(element_name, element)
		end
	end
end)