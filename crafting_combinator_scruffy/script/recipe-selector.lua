local signals = require 'script.signals'


local _M = {}

---@param entity LuaEntity
---@param circuit_id defines.circuit_connector_id.combinator_input|nil
---@param last_name string|nil `nil` if state has no current recipe before `get_recipe()`
---@param last_count integer|nil `nil` when called from `cc` where highest count is not required to be returned
---@param entityUID uid
---@return boolean `True` if recipe changed
---@return LuaRecipe? #recipe of the highest signal
---@return int? #highest count
function _M.get_recipe(entity, circuit_id, last_name, last_count, entityUID)
	local highest = signals.get_highest(entity, circuit_id, last_count ~= nil, entityUID)
	
	if not highest then
		if last_name == nil then return false; end
		return true, nil, 0
	end
	
	if last_name == highest.signal.name and (last_count == nil or last_count == highest.count) then return false; end
	return true, entity.force.recipes[highest.signal.name], highest.count
end


local get_recipes_cache = {
	ingredients = {
		item = {},
		fluid = {},
	},
	products = {
		item = {},
		fluid = {},
	},
}

---@param entity LuaEntity
---@param circuit_id defines.circuit_connector_id.combinator_input
---@param mode "ingredients"|"products" ingredients/products field in LuaRecipe
---@param last_signal SignalID?
---@param last_count integer? `nil` if `rc.settings.multiply_by_input` is `false`, `highest_count` is not returned in this case
---@param entityUID uid
---@return boolean changed
---@return {recipe: LuaRecipe, amount: uint}[]? results
---@return integer? highest_count
---@return SignalID? highest_signal
function _M.get_recipes(entity, circuit_id, mode, last_signal, last_count, entityUID)
	local highest = signals.get_highest(entity, circuit_id, last_count ~= nil, entityUID)
	
	if not highest or highest.signal.type == 'virtual' then
		if last_signal == nil then return false; end
		return true, {}, 0, nil
	end
	
	if last_signal
		and last_signal.name == highest.signal.name
		and last_signal.type == highest.signal.type
		and (last_count == nil or last_count == highest.count)
	then return false; end
	
	local cache = get_recipes_cache[mode][highest.signal.type]
	local force_index = entity.force.index
	cache[force_index] = cache[force_index] or {}
	if cache[force_index][highest.signal.name] then
		return true, cache[force_index][highest.signal.name], highest.count, highest.signal
	end
	
	local results = {}
	for name, recipe in pairs(entity.force.recipes) do
		for i=1,#recipe[mode] do
			---@type Ingredient|Product
			local obj = recipe[mode][i]
			if obj.name == highest.signal.name and obj.type == highest.signal.type then
				local amount = tonumber(obj.amount or obj.amount_min or obj.amount_max) or 1
				amount = amount * (tonumber(obj.probability) or 1)
				results[#results+1] = {recipe = recipe, amount = amount}
				break
			end
		end
	end
	
	cache[force_index][highest.signal.name] = results
	return true, results, highest.count, highest.signal
end


local signal_cache = {}
function _M.get_signal(recipe)
	local signal = signal_cache[recipe]
	if signal == nil then
		-- check recipe_name in item > fluid > virtual signals
		local type = (game.item_prototypes[recipe] and 'item') or (game.fluid_prototypes[recipe] and 'fluid') or (game.virtual_signal_prototypes[recipe] and 'virtual')
		if type == nil then
			signal_cache[recipe] = false
		else
			signal = {
				name = recipe,
				type = type
			}
			signal_cache[recipe] = signal
		end
	end
	if not signal then return end
	return signal
end


return _M
