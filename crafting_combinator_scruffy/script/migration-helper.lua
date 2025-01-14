local cc_control = require 'script.cc'
local rc_control = require 'script.rc'
local signals = require 'script.signals'
local housekeeping = require 'script.housekeeping'

---First step of migration, migration of states by using remote call global data.
---@return table|nil # migrated_uids or nil
local migrate_by_remote_data = function()
    if not remote.interfaces["crafting_combinator_xeraph_migration"] then return end

    local migrated_state = remote.call("crafting_combinator_xeraph_migration", "get_migrated_state")

    if not migrated_state then return end

    -- summary counts
    local count = {
        invalid_cc_entity = 0,
        invalid_module_chest = 0,
        cc_migrated = 0,
        invalid_rc_entity = 0,
        invalid_output_proxy = 0,
        rc_migrated = 0,
        invalid_signal_cache_lamp = 0,
        signal_cache_state_migrated = 0
    }

    -- cc data
    for _, combinator in pairs(migrated_state.cc.data) do
        local entity = combinator.entity
        if entity and entity.valid then
            if combinator.module_chest and combinator.module_chest.valid then
                cc_control.create(entity, nil, combinator, true)
                count.cc_migrated = count.cc_migrated + 1
            else
                count.invalid_module_chest = count.invalid_module_chest + 1
            end
        else
            count.invalid_cc_entity = count.invalid_cc_entity + 1
        end
    end

    -- rc data
    for _, combinator in pairs(migrated_state.rc.data) do
        local entity = combinator.entity
        if entity and entity.valid then
            if combinator.output_proxy and combinator.output_proxy.valid then
                rc_control.create(entity, nil, combinator)
                count.rc_migrated = count.rc_migrated + 1
            else
                count.invalid_output_proxy = count.invalid_output_proxy + 1
            end
        else
            count.invalid_rc_entity = count.invalid_rc_entity + 1
        end
    end

    -- signal cache data 
    for uid, cache_state in pairs(migrated_state.signals.cache) do
        ---@cast cache_state SignalsCacheState
        for _, entity in pairs(cache_state.__cache_entities) do
            if not entity.valid then
                count.invalid_signal_cache_lamp = count.invalid_signal_cache_lamp + 1
            end
        end
        signals.migrate(uid, cache_state)
        count.signal_cache_state_migrated = count.signal_cache_state_migrated + 1
    end

    log("[Crafting Combinator Xeraph's Fork] Migration-by-remote-data summary:")
    log(serpent.block(count, { sortkeys = false }))

    remote.call("crafting_combinator_xeraph_migration", "complete_migration")
end

return {
    migrate = function()
        migrate_by_remote_data()
        housekeeping.cleanup()
    end
}
