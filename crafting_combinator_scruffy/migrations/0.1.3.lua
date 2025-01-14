if not late_migrations then return end

late_migrations["0.1.3"] = function(changes)
    local change = changes.mod_changes['crafting_combinator_xeraph']
	if not change or not change.old_version then return; end

    local config = require 'config'
    local housekeeping = require 'script.housekeeping'
    -- remove obsolete globals
    if global.dead_combinator_settings then global.dead_combinator_settings = nil end

    global.clone_placeholder = global.clone_placeholder or {}
    global.main_uid_by_part_uid = {}

    housekeeping.cleanup()

    -- additional setting in cc_state
    for k, v in pairs(global.cc.data) do
        v.settings.input_buffer_size = config.CC_DEFAULT_SETTINGS.input_buffer_size
    end
end