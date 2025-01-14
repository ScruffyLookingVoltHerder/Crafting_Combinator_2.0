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
local housekeeping = require 'script.housekeeping'
commands.add_command("crafting_combinator_xeraph", nil, housekeeping.cc_command)

--- localise global tables for on_tick and on_entity_cloned
---@type GlobalCc, GlobalCcOrdered, GlobalRcOrdered, InserterEmptyQueue, CcLatchQueue
local global_cc, global_cc_ordered, global_rc_ordered, inserter_empty_queue, latch_queue

---@param forced boolean|nil
---@param skip_set_mt boolean|nil Only used by test script to bypass setmetatable() calls
local function on_load(forced, skip_set_mt)
	if not forced and next(late_migrations.__migrations) ~= nil then return; end
	cc_control.on_load(skip_set_mt)
	rc_control.on_load(skip_set_mt)
	signals.on_load(skip_set_mt)
	clone_helper.on_load()

	-- localise globals
	global_cc = storage.cc
	global_cc_ordered = storage.cc.ordered
	global_rc_ordered = storage.rc.ordered
	inserter_empty_queue = storage.cc.inserter_empty_queue
	latch_queue = storage.cc.latch_queue
	
	if remote.interfaces['PickerDollies'] then
		script.on_event(remote.call('PickerDollies', 'dolly_moved_entity_id'), function(event)
			local entity = event.moved_entity
			local combinator
			if entity.name == config.CC_NAME then combinator = storage.cc.data[entity.unit_number]
			elseif entity.name == config.RC_NAME then combinator = storage.rc.data[entity.unit_number]; end
			if combinator then combinator:update_inner_positions(); end
		end)
	end
end

local function init_global()
	storage.delayed_blueprint_tag_state = {}
	storage.clone_placeholder = {combinator = {count = 0}, cache = {count = 0}, timestamp = {}}
	storage.main_uid_by_part_uid = {}
end

local function on_init()
	init_global()
	cc_control.init_global()
	rc_control.init_global()
	signals.init_global()
	on_load(true)
end

local function enable_recipes()
	for _, force in pairs(game.forces) do
		if force.technologies['circuit-network'].researched then
			force.recipes[config.CC_NAME].enabled = true
			force.recipes[config.RC_NAME].enabled = true
		end
	end
end

---@type fun(param1: ConfigurationChangedData)
local function on_configuration_changed(changes)
	local is_original_removed = false
	local is_init = false
	
	-- is original mod removed?
	if (changes.mod_changes.crafting_combinator) and (not changes.mod_changes.crafting_combinator.new_version) then
		is_original_removed = true
	end

	-- is this the initial run?
	if (changes.mod_changes.crafting_combinator_xeraph) and (not changes.mod_changes.crafting_combinator_xeraph.old_version) then
		is_init = true
	end

	-- original to fork migration
	if is_init and is_original_removed then migration_helper.migrate() end

	-- if not initial run and migration script loaded, apply migration and force on_load
	if (not is_init) and (next(late_migrations.__migrations) ~= nil) then
		late_migrations(changes)
		on_load(true)
	end

	enable_recipes()

	-- check existing cc recipes
	cc_control.check_recipes()
end

script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)

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

--- Lookup table for cc entities.
--- @type { [string]: boolean } Value is always true
local is_cc_entities = {
	[config.CC_NAME] = true,
	[config.RC_NAME] = true,
	[config.MODULE_CHEST_NAME] = true,
	[config.RC_PROXY_NAME] = true,
	[config.SIGNAL_CACHE_NAME] = true
}

---@param event EventData.on_entity_cloned
local function on_cloned(event)
	local entity = event.destination
	if not (entity and entity.valid) then return end

	-- cc entities - cc, rc, module chest, output proxy, lamp
	if is_cc_entities[entity.name] then
		clone_helper.on_entity_cloned(event)
		if not (entity.valid) then return end
		-- destination entity will be destroyed during clone_helper handling if it is a redundant component
		-- only one old state can exist as a partially cloned state at a time
	end

	-- assembler and containers (including module_chest)
	local entity_type = entity.type
	if entity_type == 'assembling-machine' then
		cc_control.schedule_action(3, entity, event.tick + 1)
	elseif util.CONTAINER_TYPES[entity.type] then
		cc_control.schedule_action(2, entity, event.tick + 1)
	end
end
-- Note: 2022-11-08
-- Currently clone events are handled under the assumption that no existing cc entities are replaced by area/brush clone (clear_destination_entities = false)
-- At the time of writing, there is no API that notifies the clearing of entities due to area/brush clone
-- on_entity_cloned event, despite being the first event received for cloning, is only fired after cleared entity has become invalid

---@param event EventData.on_entity_died | EventData.on_player_mined_entity | EventData.on_robot_mined_entity | EventData.script_raised_destroy
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
		---@type uid
		local cc_uid = entity.unit_number
		local module_chest = global_cc.data[cc_uid].module_chest
		local module_chest_uid = module_chest.unit_number
		if event_name == defines.events.on_player_mined_entity then
			local cc_state = storage.cc.data[cc_uid]
			-- Check module_chest_mined_by_player tag
			-- Skip module_chest mining if this event originated from module_chest mining
			if not cc_state.module_chest_mined_by_player then
				-- Apply cc_mined_by_player tag
				cc_state.cc_mined_by_player = true
				-- Attempt to mine
				if not cc_control.mine_module_chest(cc_uid, event.player_index) then
					-- Unable to mine module chest, cc already cloned and replaced
					-- Remove item from buffer
					event.buffer.remove({name=config.CC_NAME, count=1})

					-- Remove tags and return
					cc_state.cc_mined_by_player = nil
					cc_state.module_chest_mined_by_player = nil
					return
				end
			end
		end
		if event_name == defines.events.on_entity_died
		or event_name == defines.events.script_raised_destroy
		or event_name == defines.events.on_robot_mined_entity then -- robot upgrade/decons event - should never happen
			cc_control.update_chests(entity_surface, module_chest, true)
			module_chest.destroy()
		end
		-- clear CcState except for on_entity_died - need state data until post_entity_died
		if event_name ~= defines.events.on_entity_died then
			cc_control.destroy(entity)
		end
		storage.main_uid_by_part_uid[module_chest_uid] = nil
	elseif entity_name == config.MODULE_CHEST_NAME then
		local module_chest_uid = entity.unit_number
		if event_name == defines.events.on_player_mined_entity then
			-- Normally, this should only be triggered from cc's mine_module_chest() method after mine_entity() is successful
			-- One cc item is always removed from buffer because cc is the mine product for module_chest entity
			event.buffer.remove({name=config.CC_NAME, count=1})

			-- Nanobots uses player.mine_entity() for automated deconstruction
			-- Hence the need to do a callback if this event is not triggered from cc's on_player_mined_entity event
			local cc_uid = storage.main_uid_by_part_uid[module_chest_uid]
			local cc_state = cc_uid and global_cc.data[cc_uid]
			-- Check cc_mined_by_player tag
			if cc_state and not cc_state.cc_mined_by_player then
				-- Apply tag to indicate module_chest has been mined
				cc_state.module_chest_mined_by_player = true
				local player_id = event.player_index
				if player_id then
					if not game.get_player(player_id).mine_entity(cc_state.entity) then
						-- Player mining for cc entity should always be successful, cc item should spill on the floor on overflow
						-- Keeping this part just in case player mining failed
						-- TODO: need to reverse module_chest mining if mine_entity can fail for cc entity
						cc_state.cc_mined_by_player = nil
						cc_state.module_chest_mined_by_player = nil
						return
					end
				end
			end
		elseif event_name == defines.events.on_robot_mined_entity
		or event_name == defines.events.script_raised_destroy then
			local cc_entity = global_cc.data[storage.main_uid_by_part_uid[module_chest_uid]].entity
			if cc_entity and cc_entity.valid then
				cc_control.destroy(cc_entity.unit_number)
				cc_entity.destroy()
			end
		end
		storage.main_uid_by_part_uid[module_chest_uid] = nil
	elseif entity_name == config.RC_NAME then
		local output_proxy = storage.rc.data[entity.unit_number].output_proxy
		local output_proxy_uid = output_proxy.unit_number
		if event_name == defines.events.on_entity_died
		or event_name == defines.events.script_raised_destroy
		or event_name == defines.events.on_robot_mined_entity
		or event_name == defines.events.on_player_mined_entity then			
			output_proxy.destroy()
		end
		if event_name ~= defines.events.on_entity_died then -- need state data until post_entity_died
			rc_control.destroy(entity)
		end
		storage.main_uid_by_part_uid[output_proxy_uid] = nil
	elseif entity_name == config.RC_PROXY_NAME then
		local uid = entity.unit_number
		if event_name == defines.events.script_raised_destroy then
			local rc_entity = storage.rc.data[storage.main_uid_by_part_uid[uid]].entity
			rc_control.destroy(rc_entity.unit_number)
			rc_entity.destroy()
		end
		storage.main_uid_by_part_uid[uid] = nil
	elseif entity_name == config.SIGNAL_CACHE_NAME then
		storage.main_uid_by_part_uid[entity.unit_number] = nil
	else
		if entity_type == 'assembling-machine' then
			cc_control.update_assemblers(entity_surface, entity, true)
		end
	end
end

-- load values from settings on script load
local cc_rate = settings.global[config.REFRESH_RATE_CC_NAME].value
local rc_rate = settings.global[config.REFRESH_RATE_RC_NAME].value
config:load_values(settings)
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting == config.REFRESH_RATE_CC_NAME then
		cc_rate = settings.global[config.REFRESH_RATE_CC_NAME].value
	elseif event.setting == config.REFRESH_RATE_RC_NAME then
		rc_rate = settings.global[config.REFRESH_RATE_RC_NAME].value
	end
	config:on_mod_settings_changed(event)
end)
---@cast cc_rate uint
---@cast rc_rate uint

---@param tab CcState
---@param tick uint
---@param rate uint
local function run_update(tab, tick, rate)
	for i = tick % (rate + 1) + 1, #tab, (rate + 1) do tab[i]:update(nil, tick); end
end

---@param event EventData.on_tick
local function on_tick(event)
	local current = event.tick
	if global_cc.queue_count > 0 then
		local queue = inserter_empty_queue[current]
		if queue then
			for i = 1, #queue do
				local state = queue[i]
				if state.entity.valid and state.assembler and state.assembler.valid then state:empty_inserters(); end
				global_cc.queue_count = global_cc.queue_count - 1
			end
			inserter_empty_queue[current] = nil
		end

		queue = latch_queue.state[current]
		if queue then
			for i = 1, #queue do
				local state = queue[i]
				if state.entity.valid then -- using only simple entity check because the state could have already been dropped
					state:find_assembler()
					state:find_chest()
					state.enabled = true -- enables update()
				end
				global_cc.queue_count = global_cc.queue_count - 1
			end
			latch_queue.state[current] = nil
		end

		queue = latch_queue.container[current]
		if queue then
			for i = 1, #queue do
				local container = queue[i]
				if container.valid then
					cc_control.update_chests(container.surface, container)
				end
				global_cc.queue_count = global_cc.queue_count - 1
			end
			latch_queue.container[current] = nil
		end

		queue = latch_queue.assembler[current]
		if queue then
			for i = 1, #queue do
				local assembler = queue[i]
				if assembler.valid then
					cc_control.update_assemblers(assembler.surface, assembler)
				end
				global_cc.queue_count = global_cc.queue_count - 1
			end
			latch_queue.assembler[current] = nil
		end
	end
	run_update(global_cc_ordered, current, cc_rate)
	run_update(global_rc_ordered, current, rc_rate)
end
script.on_event(defines.events.on_tick, on_tick)
script.on_nth_tick(600, function(event)
	-- clean up partially cloned entities
	clone_helper.on_nth_tick(event)
end)

script.on_event(defines.events.on_player_rotated_entity, function(event)
	if event.entity.name == config.CC_NAME then
		local combinator = global_cc.data[event.entity.unit_number]
		if combinator then
			combinator:find_assembler()
			combinator:find_chest()
		end
	end
end)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
	local source, destination
	if event.source.name == config.CC_NAME and event.destination.name == config.CC_NAME then
		source, destination = global_cc.data[event.source.unit_number], global_cc.data[event.destination.unit_number]
	elseif event.source.name == config.RC_NAME and event.destination.name == config.RC_NAME then
		source, destination = storage.rc.data[event.source.unit_number], storage.rc.data[event.destination.unit_number]
	else return; end
	
	destination.settings = util.deepcopy(source.settings)
	if destination.entity.name == config.RC_NAME then destination:update(true)
	elseif destination.entity.name == config.CC_NAME then destination:copy(source); end
end)

-- filter for built and destroyed events
local filter_built_destroyed = {
	{filter = "name", name = config.CC_NAME},
	{filter = "name", name = config.RC_NAME},
	{filter = "name", name = config.MODULE_CHEST_NAME},
	{filter = "name", name = config.RC_PROXY_NAME},
	{filter = "name", name = config.SIGNAL_CACHE_NAME},
	{filter = "type", type = 'assembling-machine'}
}

-- filter: containers
for container in pairs(util.CONTAINER_TYPES) do
	table.insert(filter_built_destroyed, {filter = "type", type = container})
end

-- entity built events
script.on_event(defines.events.on_built_entity, on_built, filter_built_destroyed)
script.on_event(defines.events.on_robot_built_entity, on_built, filter_built_destroyed)
script.on_event(defines.events.script_raised_built, on_built, filter_built_destroyed)
script.on_event(defines.events.script_raised_revive, on_built, filter_built_destroyed)
script.on_event(defines.events.on_entity_cloned, on_cloned, filter_built_destroyed)

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
	function(event) cc_control.on_module_chest_marked_for_decon(event.entity, event.tick) end,
	{{filter = "name", name = config.MODULE_CHEST_NAME}}
)
script.on_event(
	defines.events.on_cancelled_deconstruction,
	function(event) cc_control.on_module_chest_cancel_decon(event.entity, event.tick) end,
	{{filter = "name", name = config.MODULE_CHEST_NAME}}
)

-- GUI events
script.on_event(defines.events.on_gui_opened, gui.gui_event_handler)
script.on_event(defines.events.on_gui_closed, function(event)
	local element = event.element
	if element and element.valid and element.name and element.name:match('^crafting_combinator:') then
		element.destroy()
	end

	-- blueprint gui
	blueprint.handle_event(event)
end)
script.on_event(defines.events.on_gui_checked_state_changed, gui.gui_event_handler)
script.on_event(defines.events.on_gui_selection_state_changed, gui.gui_event_handler)
script.on_event(defines.events.on_gui_text_changed, gui.gui_event_handler)
script.on_event(defines.events.on_gui_click, gui.gui_event_handler)

if script.active_mods.crafting_combinator_xeraph_test and script.active_mods.testorio then
	_ENV.crafting_combinator_xeraph_lifecycle_test = {
		settings = {
			cc_rate = cc_rate,
			rc_rate = rc_rate
		},
		on_init = on_init,
		on_load = on_load,
		on_configuration_changed = on_configuration_changed,
		on_tick = on_tick
	}
	require "__crafting_combinator_xeraph_test__.main"
end