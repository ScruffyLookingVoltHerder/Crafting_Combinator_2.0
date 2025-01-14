local config = require 'config'
local _M = {}

_M.EVERYTHING = {type = 'virtual', name = 'signal-everything'}
local LAMP_TYPES = {"highest", "highest_count", "highest_present", "signal_present"}

local cache_mt = {
	__index = function(self, key)
		if key == "__self" then return end -- __index __self is preventing deepcopy from functioning properly for clone-helper
		local entity = self.__entity.surface.create_entity {
			name = config.SIGNAL_CACHE_NAME,
			position = self.__entity.position,
			force = self.__entity.force,
			create_build_effect_smoke = false,
		}
		self.__cache_entities[key] = entity
		entity.destructible = false
		
		self.__entity.connect_neighbour {
			wire = defines.wire_type.red,
			target_entity = entity,
			source_circuit_id = self.__circuit_id or nil,
		}
		self.__entity.connect_neighbour {
			wire = defines.wire_type.green,
			target_entity = entity,
			source_circuit_id = self.__circuit_id or nil,
		}
		
		self[key] = {
			__cb = entity.get_or_create_control_behavior(),
		}

		storage.main_uid_by_part_uid[entity.unit_number] = self.__entity.unit_number
		
		return self[key]
	end,
}


function _M.init_global()
	storage.signals = storage.signals or {}
	storage.signals.cache = storage.signals.cache or {}
end

function _M.on_load(skip_set_mt)
	if skip_set_mt then return end
	for _, cache in pairs(storage.signals.cache) do setmetatable(cache, cache_mt); end
end

---@param state SignalsCacheState
---@param main_uid uid
---@return boolean|nil true if all entities are valid
function _M.check_signal_cache_entities(state, main_uid)
	if not state then return end
	for i=1,#LAMP_TYPES do
		local lamp = state.__cache_entities[LAMP_TYPES[i]]
		if lamp and not lamp.valid then
			log({"", "Signal cache dropped due to invalid entity ", main_uid})
			_M.cache.drop(main_uid)
			return
		end
	end
	return true
end -- currently the highest computational cost for entity validity check

---Method to migrate individual signal cache state into the game
---@param cache_state table
---@param uid uid  
function _M.migrate(uid, cache_state)
	storage.signals.cache[uid] = setmetatable(cache_state, cache_mt)
	_M.verify(uid, cache_state)
end

---Method to migrate individual signal cache lamp
---@param lamp LuaEntity
---@return boolean? true if migrate successful
function _M.migrate_lamp(lamp)
	-- check red connection for RC or CC entity, if no connection then return
	local connected_entities = lamp.circuit_connected_entities.red
	local combinator_entity, circuit_id
	for i = 1, #connected_entities do
		local entity = connected_entities[i]
		if entity.name == config.CC_NAME then
			combinator_entity = connected_entities[i]
			break
		elseif entity.name == config.RC_NAME then
			combinator_entity = connected_entities[i]
			circuit_id = defines.circuit_connector_id.combinator_input
			break
		end
	end

	if not combinator_entity then return end

	-- get or create signal cache state
	local cache = _M.cache.get(combinator_entity, circuit_id, combinator_entity.unit_number)

	-- get cb
	local cb = lamp.get_control_behavior() --[[@as LuaLampControlBehavior]]
	if not (cb and cb.valid) then return end

	-- determine the type of cache
	local lamp_type
	local condition_comparator = cb.circuit_condition.condition.comparator

	if cb.circuit_condition.condition.first_signal.name == _M.EVERYTHING.name then
		lamp_type = "highest"
	elseif condition_comparator == "=" then
		lamp_type = "highest_count"
	elseif condition_comparator == "≠" then
		lamp_type = "highest_present"
	elseif condition_comparator == ">" then
		lamp_type = "signal_present"
	end

	-- if lamp_type is not one of the above then return false [https://mods.factorio.com/mod/crafting_combinator_xeraph/discussion/63ceddab9e540534a4b8e92d]
	-- circuit_condition can be item < 0 - i.e. the default condition for a new lamp
	if lamp_type == nil then return false end

	-- check cache state for existing lamps for the corresponding lamp_type
	-- if present and valid then return false
	local existing_lamp = cache.__cache_entities[lamp_type]
	if rawget(cache, lamp_type) and existing_lamp and existing_lamp.valid then
		return false
	else
		cache.__cache_entities[lamp_type] = lamp
		cache[lamp_type] = { __cb = cb }
		storage.main_uid_by_part_uid[lamp.unit_number] = combinator_entity.unit_number
		return true
	end
	-- TODO: guess value and valid fields?
	-- TODO: consider dropping all signal cache lamps instead of migrating
end

---@alias SignalsCacheState_Verify
---|nil # signal cache state is valid
---|1 # cache invalid
---|2 # lamp invalid
---@param state SignalsCacheState
---@return SignalsCacheState_Verify
function _M.verify(uid, state)
	local combinator_entity = state.__entity
	if combinator_entity and combinator_entity.valid then
			-- check lamps and update main_uid_by_part_uid
			for i= 1, #LAMP_TYPES do
			local lamp_type = LAMP_TYPES[i]
				if rawget(state, lamp_type) then
					local lamp_cb = state[lamp_type].__cb
					local lamp_entity = state.__cache_entities[lamp_type]
					if lamp_cb and lamp_entity and lamp_entity.valid then
						storage.main_uid_by_part_uid[lamp_entity.unit_number] = uid
					else
						state[lamp_type] = nil
						state.__cache_entities[lamp_type] = nil
						return 2
					end
				end
			end
	else
		storage.signals.cache[uid] = nil
		return 1
	end
end

_M.cache = {}

---Method to get cache state by entityUID
---@param entity LuaEntity
---@param circuit_id defines.circuit_connector_id.combinator_input
---@param entityUID uid
---@return SignalsCacheState cache_state Signals cache state for the cc/rc state
function _M.cache.get(entity, circuit_id, entityUID)
	local cache = storage.signals.cache[entityUID]
	if not cache then
		cache = setmetatable({
			__entity = entity,
			__circuit_id = circuit_id or false, -- Avoid calling __index when the id is nil
			__cache_entities = {},
		}, cache_mt)
		storage.signals.cache[entityUID] = cache
	end
	return cache
end

function _M.cache.reset(entity, name) -- not used? to reset already existing lamps?
	local cache = storage.signals.cache[entity.unit_number]
	if cache and rawget(cache, name) then
		storage.signals.cache[entity.unit_number][name] = {
			control_behavior = entity.get_or_create_control_behavior(),
		}
	end
end

function _M.cache.drop(unit_number)
	local cache = storage.signals.cache[unit_number]
	if cache then
		for _, e in pairs(cache.__cache_entities) do
			if e.valid then
				storage.main_uid_by_part_uid[e.unit_number] = nil
				e.destroy();
			end
		end
		storage.signals.cache[unit_number] = nil
	end
end

function _M.cache.move(entity)
	local cache = storage.signals.cache[entity.unit_number]
	if cache then
		for _, e in pairs(cache.__cache_entities) do e.teleport(entity); end
	end
end


function _M.get_merged_signals(entity, circuit_id)
	return circuit_id and (entity.get_merged_signals(circuit_id) or {}) or entity.get_merged_signals() or {}
end
function _M.get_merged_signal(entity, signal, circuit_id)
	if circuit_id then return entity.get_merged_signal(signal, circuit_id)
	else return entity.get_merged_signal(signal); end
end


function _M.get_highest(entity, circuit_id, update_count, entityUID)
	local cache = _M.cache.get(entity, circuit_id, entityUID)

	local highestValue = cache.highest.value
	
	if cache.highest.valid
		and not cache.highest.__cb.disabled
		and (not highestValue or not cache.highest_present.__cb.disabled)
	then
		if update_count and highestValue and cache.highest_count.__cb.disabled then
			local count = _M.get_merged_signal(entity, highestValue.signal, circuit_id)
			
			highestValue.count = count
			cache.highest_count.__cb.circuit_condition = {condition = {
				comparator = '=',
				first_signal = highestValue.signal,
				constant = count,
			}}
		end
		return highestValue
	end
	
	local highest = nil
	local signals = _M.get_merged_signals(entity, circuit_id)
	for i=1,#signals do
		if highest == nil or signals[i].count > highest.count then highest = signals[i]; end
	end
	
	cache.highest.valid = true
	
	if highest then
		cache.highest.value = highest
		cache.highest.__cb.circuit_condition = {condition = {
			comparator = '≤',
			first_signal = _M.EVERYTHING,
			second_signal = highest.signal,
		}}
		
		cache.highest_present.__cb.circuit_condition = {condition = {
			comparator = '≠',
			first_signal = highest.signal,
			constant = 0,
		}}
		
		cache.highest_count.__cb.circuit_condition = {condition = {
			comparator = '=',
			first_signal = highest.signal,
			constant = highest.count,
		}}
	else
		cache.highest.value = nil
		cache.highest.__cb.circuit_condition = {condition = {
			comparator = '=',
			first_signal = _M.EVERYTHING,
			constant = 0,
		}}
	end
	
	return highest
end


function _M.watch_highest_presence(entity, circuit_id, entityUID)
	local highest = _M.get_highest(entity, circuit_id, nil, entityUID)
	local cache = _M.cache.get(entity, circuit_id, entityUID)
	
	if not highest then
		cache.signal_present.valid = false
	else
		cache.signal_present.valid = true
		cache.signal_present.__cb.circuit_condition = {condition = {
			comparator = '>',
			first_signal = highest.signal,
			constant = 0,
		}}
	end
	
	return highest
end
function _M.signal_present(entity, circuit_id, entityUID)
	local cache = _M.cache.get(entity, circuit_id, entityUID)
	return cache.signal_present.valid and not cache.signal_present.__cb.disabled
end


return _M
