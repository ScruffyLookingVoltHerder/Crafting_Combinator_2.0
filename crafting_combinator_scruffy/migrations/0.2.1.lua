if not late_migrations then return end

late_migrations["0.2.1"] = function(changes)
    local change = changes.mod_changes['crafting_combinator_xeraph']
    if not change or not change.old_version then return; end

    local housekeeping = require 'script.housekeeping'

    -- clean up orphans
    housekeeping.cleanup()
end