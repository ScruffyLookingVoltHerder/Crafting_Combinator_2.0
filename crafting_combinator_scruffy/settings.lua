local config = require "config"


data:extend{
	{
		type = "int-setting",
		name = config.REFRESH_RATE_CC_NAME,
		setting_type = "runtime-global",
		default_value = config.REFRESH_RATE_CC,
		minimum_value = 0,
	},
	{
		type = "int-setting",
		name = config.REFRESH_RATE_RC_NAME,
		setting_type = "runtime-global",
		default_value = config.REFRESH_RATE_RC,
		minimum_value = 0,
	},
	{
		type = "int-setting",
		name = config.CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT_NAME,
		setting_type = "runtime-global",
		default_value = config.CC_INPUT_BUFFER_ON_SET_RECIPE_DEFAULT,
		minimum_value = -1,
		order = 'cc-1'
	},
	{
		type = "int-setting",
		name = config.CC_CRAFT_N_BEFORE_SWITCH_DEFAULT_NAME,
		setting_type = "runtime-global",
		default_value = config.CC_CRAFT_N_BEFORE_SWITCH_DEFAULT,
		minimum_value = -1,
		order = 'cc-2'
	},
	{
		type = "int-setting",
		name = config.MODULE_CHEST_SIZE_NAME,
		setting_type = "startup",
		default_value = config.MODULE_CHEST_SIZE,
		minimum_value = 10,
		maximum_value = 500
	},

}
