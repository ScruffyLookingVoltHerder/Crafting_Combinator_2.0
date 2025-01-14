local c = {
	MOD_PATH = '__crafting_combinator_scruffy__',
	CC_NAME = 'crafting-combinator',
	CC_CRAFT_N_BEFORE_SWITCH_DEFAULT_NAME = 'craft-n-before-switch-default',
	CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT_NAME = 'input-buffer-on-set-recipe-default',
	RC_NAME = 'recipe-combinator',
	MODULE_CHEST_NAME = 'module-chest',
	MODULE_CHEST_SIZE_NAME ='module-chest-size',
	REFRESH_RATE_CC_NAME = 'refresh-rate-cc',
	REFRESH_RATE_RC_NAME = 'refresh-rate-rc',
	RC_PROXY_NAME = 'rc-proxy',
	SIGNAL_CACHE_NAME = 'signal-cache',
	TIME_SIGNAL_NAME = 'recipe-time',
	SPEED_SIGNAL_NAME = 'crafting-speed',
	GROUP_NAME = 'virtual-recipes',
	RECIPE_SUBGROUP_PREFIX = 'virtual-recipe-subgroup_',
	UNSORTED_RECIPE_SUBGROUP = 'virtual-recipe-subgroup_unsorted',

	CC_CRAFT_N_BEFORE_SWITCH_DEFAULT = 1,
	CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT = 2,
	
	CC_DEFAULT_SETTINGS = {
		chest_position = 1, -- 1 = Behind, 2 = Left, 3 = Right
		mode = 'w',
		wait_for_output_to_clear = false,
		discard_items = false,
		discard_fluids = true,
		empty_inserters = true,
		read_recipe = true,
		read_speed = false,
		read_machine_status = false,
		craft_until_zero = false,
		craft_n_before_switch = 1,
		input_buffer_size = 2
	},
	RC_DEFAULT_SETTINGS = {
		mode = 'ing',
		multiply_by_input = false,
		divide_by_output = false,
		differ_output = false,
		time_multiplier = 10,
	},
	
	ASSEMBLER_DISTANCE = 1,
	ASSEMBLER_SEARCH_DISTANCE = 2,
	CHEST_DISTANCE = 1,
	CHEST_SEARCH_DISTANCE = 2,
	INSERTER_SEARCH_RADIUS = 3,
	
	REFRESH_RATE_CC = 60,
	REFRESH_RATE_RC = 60,
	
	INSERTER_EMPTY_DELAY = 60,
	
	MODULE_CHEST_SIZE = 100,
	
	RC_SLOT_COUNT = 40,
	-- This is the number of extra slots on top of the max ingredient count
	RC_SLOT_RESERVE = 5, -- 5 is arbitrary, but large enough
	
	-- Recipes matching any of these strings will not get a virtual recipe
	RECIPES_TO_IGNORE = {
		'angels%-void',
	},
	
	FLYING_TEXT_INTERVAL = 180,
	
	MACHINE_STATUS_SIGNALS = {
		working = 'signal-green',
		no_power = 'signal-red',
		no_fuel = 'signal-red',
		low_power = 'signal-yellow',
		fluid_ingredient_shortage = 'signal-red',
		fluid_production_overload = 'signal-yellow',
		item_ingredient_shortage = 'signal-red',
		item_production_overload = 'signal-yellow',
	},
}

-- load values on script load
---@param settings LuaSettings
function c:load_values(settings)
	self.CC_DEFAULT_SETTINGS.craft_n_before_switch = settings.global[self.CC_CRAFT_N_BEFORE_SWITCH_DEFAULT_NAME].value
	self.CC_DEFAULT_SETTINGS.input_buffer_size = settings.global[self.CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT_NAME].value
end

-- Mod settings events
---@param event EventData.on_runtime_mod_setting_changed
function c:on_mod_settings_changed(event)
	if event.setting == self.CC_CRAFT_N_BEFORE_SWITCH_DEFAULT_NAME then
		self.CC_DEFAULT_SETTINGS.craft_n_before_switch = settings.global[self.CC_CRAFT_N_BEFORE_SWITCH_DEFAULT_NAME].value
	elseif event.setting == self.CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT_NAME then
		self.CC_DEFAULT_SETTINGS.input_buffer_size = settings.global[self.CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT_NAME].value
	end
end

return c