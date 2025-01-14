local config = require 'config'
local cc_control = require 'script.cc'
local rc_control = require 'script.rc'
local signals = require 'script.signals'

local get_all_cc_entities = function ()
    local entities = {}
    for _, surface in pairs(game.surfaces) do
        local surface_entities = surface.find_entities_filtered {
            name = {
                config.CC_NAME,
                config.MODULE_CHEST_NAME,
                config.RC_NAME,
                config.RC_PROXY_NAME,
                config.SIGNAL_CACHE_NAME
            }
        }
        for i = 1, #surface_entities do
            entities[#entities + 1] = surface_entities[i]
        end
    end
    return entities
end

local function cleanup()
    local count = {
        invalid = {
            cc = 0,
            module_chest = 0,
            rc = 0,
            output_proxy = 0,
            signals_cache = {
                cache_state = 0,
                lamp = 0
            },
        },
        cc_data_created = 0,
        rc_data_created = 0,
        signal_cache_lamp_relinked = 0,
        destroyed = {
            module_chest = 0,
            output_proxy = 0,
            signal_cache_lamp = 0
        }
    }

    ---Procedure data for refactored function
    ---@class proc_data
    ---@field main? boolean whether this is a main entity
    ---@field part? boolean whether this is a part entity
    ---@field part_name string entity name for the corresponding part
    ---@field part_key "module_chest"|"output_proxy" key to be used in construction of `migrated_state` for create() method
    ---@field check_global boolean whether to include this entity for check_global, only one per global_data is selected
    ---@field global_data GlobalCcData|GlobalRcData|GlobalSignalsCache reference to global data
    ---@field main_control? table # reference to respective main modules
    ---@field stat_key string key to be used to record statistics

    ---`Key`: Entity name, `Value`: Procedure data for this entity
    ---@type table<string,proc_data>
    local proc_data = {
        [config.CC_NAME] = {
            main = true,
            part_name = config.MODULE_CHEST_NAME,
            part_key = "module_chest",
            check_global = true,
            global_data = global.cc.data,
            main_control = cc_control,
            stat_key = "cc"
        },
        [config.MODULE_CHEST_NAME]= {
            part = true,
            check_global = false,
            global_data = global.cc.data,
            stat_key = "module_chest"
        },
        [config.RC_NAME] = {
            main = true,
            part_name = config.RC_PROXY_NAME,
            part_key = "output_proxy",
            check_global = true,
            global_data = global.rc.data,
            main_control = rc_control,
            stat_key = "rc"
        },
        [config.RC_PROXY_NAME] = {
            part = true,
            check_global = false,
            global_data = global.rc.data,
            stat_key = "output_proxy"
        },
        [config.SIGNAL_CACHE_NAME] = {
            part = true,
            check_global = true,
            global_data = global.signals.cache,
            stat_key = "signals_cache"
        }
    }

    -- global data cleanup

    log({"", "Old main_uid_by_part_uid ", table_size(global.main_uid_by_part_uid)})

    -- reset main_uid_by_part_uid
    for k in pairs(global.main_uid_by_part_uid) do
        global.main_uid_by_part_uid[k] = nil
    end

    for entity_name, map in pairs(proc_data) do
        if not map.check_global then goto next_proc end
        -- find invalid entity entries
        -- else find part and update main_uid_by_part_uid
        for uid, state in pairs(map.global_data) do
            if entity_name == config.CC_NAME or entity_name == config.RC_NAME then
                if state.entity and state.entity.valid then
                    if entity_name == config.CC_NAME then
                        ---@cast state CcState
                        if state.module_chest and state.module_chest.valid then
                            global.main_uid_by_part_uid[state.module_chest.unit_number] = uid
                        else
                            -- try to find a module_chest at same position
                            local module_chest = state.entity.surface.find_entity(config.MODULE_CHEST_NAME, state.entity.position)
                            if module_chest then
                                state.module_chest = module_chest
                                state.inventories.module_chest = module_chest.get_inventory(defines.inventory.chest)
                                cc_control.update_chests(module_chest.surface, module_chest)
                                global.main_uid_by_part_uid[state.module_chest.unit_number] = uid
                            else
                                map.global_data[uid] = nil
                            end
                            count.invalid[proc_data[config.MODULE_CHEST_NAME].stat_key] = count.invalid[proc_data[config.MODULE_CHEST_NAME].stat_key] + 1
                        end
                    elseif entity_name == config.RC_NAME then
                        ---@cast state RcState
                        if state.output_proxy and state.output_proxy.valid then
                            global.main_uid_by_part_uid[state.output_proxy.unit_number] = uid
                        else
                            -- try to find a output_proxy at same position
                            local output_proxy = state.entity.surface.find_entity(config.MODULE_CHEST_NAME, state.entity.position)
                            if output_proxy then
                                state.output_proxy = output_proxy
                                state.control_behavior = state.output_proxy.get_or_create_control_behavior()
                                global.main_uid_by_part_uid[state.output_proxy.unit_number] = uid
                            else
                                map.global_data[uid] = nil
                            end
                            count.invalid[proc_data[config.RC_PROXY_NAME].stat_key] = count.invalid[proc_data[config.RC_PROXY_NAME].stat_key] + 1
                        end
                    end
                else
                    map.global_data[uid] = nil
                    count.invalid[map.stat_key] = count.invalid[map.stat_key] + 1
                end
            elseif entity_name == config.SIGNAL_CACHE_NAME then
                ---@cast state SignalsCacheState
                local invalid = signals.verify(uid, state)
                if invalid then
                    if invalid == 1 then
                        count.invalid[map.stat_key].cache_state = count.invalid[map.stat_key].cache_state + 1
                    else
                        count.invalid[map.stat_key].lamp = count.invalid[map.stat_key].lamp + 1
                    end
                end
            end
        end
        ::next_proc::
    end

    -- cc/rc: try to create global data
    -- signal lamp: try to link

    ---@type LuaEntity[]
    local all_cc_entities = get_all_cc_entities()

    -- loop through for signal lamps - they should be linked before cc/rc:update is called
    for i = #all_cc_entities, 1, -1 do
        local entity = all_cc_entities[i]
        if entity.name == config.SIGNAL_CACHE_NAME then
            if global.main_uid_by_part_uid[entity.unit_number] then goto not_orphan end
            if signals.migrate_lamp(entity) then
                count.signal_cache_lamp_relinked = count.signal_cache_lamp_relinked + 1
            else
                goto next_entity
            end
            ::not_orphan::
            table.remove(all_cc_entities, i)
        end
        ::next_entity::
    end

    local current = game.tick

    -- loop through for cc/rc
    for i = #all_cc_entities, 1, -1 do
        local entity = all_cc_entities[i]
        local entity_name = entity.name
        if not proc_data[entity_name].main then goto next_entity end
        local uid = entity.unit_number
        if not rawget(proc_data[entity_name].global_data, uid) then -- cc/rc state not found
            local control = proc_data[entity_name].main_control
            local part = entity.surface.find_entity(proc_data[entity_name].part_name, entity.position)
            local migrated_state
            if part then
                migrated_state = {[proc_data[entity_name].part_key] = part}
                global.main_uid_by_part_uid[part.unit_number] = uid
            end
            local state = control.create(entity, nil, migrated_state, true)
            if entity_name == config.CC_NAME then
                control.schedule_action(1, state ,current + 1)
                count.cc_data_created = count.cc_data_created + 1
            elseif entity_name == config.RC_NAME then
                count.rc_data_created = count.rc_data_created + 1
            end
            state:update(true, current)
        end
        table.remove(all_cc_entities, i)
        ::next_entity::
    end

    log({"", "New main_uid_by_part_uid ", table_size(global.main_uid_by_part_uid)})

    if count.cc_data_created > 0 then
        game.print({"crafting_combinator.chat-message", {"", "a total of ", count.cc_data_created, " CC state(s) has been created with default settings."}})
    end
    if count.rc_data_created > 0 then
        game.print({"crafting_combinator.chat-message", {"", "a total of ", count.rc_data_created, " RC state(s) has been created with default settings."}})
    end

    -- remaining entities in the table
    -- use main_uid_by_part_uid to determine orphans -> destroy
    for i = #all_cc_entities, 1, -1 do
        local entity = all_cc_entities[i]
        local entity_name = entity.name
        local uid = entity.unit_number
        if proc_data[entity_name].part then
            if global.main_uid_by_part_uid[uid] then goto next_entity end
            entity.destroy()
            if entity_name == config.SIGNAL_CACHE_NAME then
                count.destroyed.signal_cache_lamp = count.destroyed.signal_cache_lamp + 1
            else
                local stat_key = proc_data[entity_name].stat_key
                count.destroyed[stat_key] = count.destroyed[stat_key] + 1
            end
            goto next_entity
        end
        game.print({"crafting_combinator.chat-message", {"", "Cleanup(): Remnant orphan ", entity_name , " in all_cc_entities table, please inform mod author."}})
        ::next_entity::
    end

    -- reset global.cc/rc.ordered
    local data_list = {global.cc.data, global.rc.data}
    local ordered_list = {global.cc.ordered, global.rc.ordered}
    for i=1,#ordered_list do
        local global_ordered = ordered_list[i]
        for j=1,#global_ordered do
            global_ordered[j] = nil
        end
        for _, state in pairs(data_list[i]) do
            global_ordered[#global_ordered+1] = state
        end
    end

    game.print({"crafting_combinator.chat-message", {"", "Cleanup complete."}})
    log("Cleanup command invoked")
    log(serpent.block(count, {sortkeys = false}))
end

local function cc_command(command)
    if command.parameter == "cleanup" then cleanup() end
end

local h = {
    cleanup = cleanup,
    cc_command = cc_command,
    get_all_cc_entities = get_all_cc_entities
}
return h