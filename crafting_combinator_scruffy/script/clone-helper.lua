---@alias ph_type
---|'combinator-main'
---|'combinator-part'
---|'cache'

---@alias StateType
---|"cc"
---|"rc"
---|"cache"

local config = require "config"
local util = require "script.util"
local cc_control = require "script.cc"

---@type PhCombinatorList, PhCacheList, PhTimestampList, main_uid_by_part_uid
local ph_combinator, ph_cache, ph_timestamp, main_uid_by_part_uid

---@type GlobalCcData, GlobalCcOrdered, GlobalRcData, GlobalRcOrdered, GlobalSignalsCache
local global_cc_data, global_cc_ordered, global_rc_data, global_rc_ordered, global_signals_cache

local on_load = function()
    ph_combinator = storage.clone_placeholder.combinator
    ph_cache = storage.clone_placeholder.cache
    ph_timestamp = storage.clone_placeholder.timestamp
    main_uid_by_part_uid = storage.main_uid_by_part_uid

    global_cc_data = storage.cc.data
    global_cc_ordered = storage.cc.ordered
    global_rc_data = storage.rc.data
    global_rc_ordered = storage.rc.ordered
    global_signals_cache = storage.signals.cache
end

--- ph key lookup, used in update_ph()
local get_ph_combinator_key = {
    [config.CC_NAME] = "entity",
    [config.RC_NAME] = "entity",
    [config.MODULE_CHEST_NAME] = "module_chest",
    [config.RC_PROXY_NAME] = "output_proxy"
}

--- ph_type lookup by entity name, used in get_ph()
local get_ph_type = {
    [config.CC_NAME] = "combinator-main",
    [config.MODULE_CHEST_NAME] = "combinator-part",
    [config.RC_NAME] = "combinator-main",
    [config.RC_PROXY_NAME] = "combinator-part",
    [config.SIGNAL_CACHE_NAME] = "cache"
}

--- state type lookup by entity name
local get_state_type = {
    [config.CC_NAME] = "cc",
    [config.MODULE_CHEST_NAME] = "cc",
    [config.RC_NAME] = "rc",
    [config.RC_PROXY_NAME] = "rc",
    [config.SIGNAL_CACHE_NAME] = "cache"
}

---Create method for ph.
---@param ph_list PhCombinatorList|PhCacheList
---@param ph_type ph_type
---@param old_main_uid old_main_uid
---@param new_entity_name string|nil
---@param current uint event.tick
---@return PhCombinator|PhCache|nil
local create_ph = function(ph_list, ph_type, old_main_uid, new_entity_name, current)
    ---@type PhCombinator|PhCache
    local ph = {entity = false}
    if ph_type == "combinator-main" or ph_type == "combinator-part" then
        if new_entity_name == config.CC_NAME or new_entity_name == config.MODULE_CHEST_NAME then
            ph.module_chest = false
        elseif new_entity_name == config.RC_NAME or new_entity_name == config.RC_PROXY_NAME then
            ph.output_proxy = false
        end
    elseif ph_type == "cache" then
        local old_cache_state = global_signals_cache[old_main_uid]
        if not old_cache_state then return end -- return when no old cache found
        for k in pairs(old_cache_state.__cache_entities) do -- old cache found, create keys based on signals cache
            ph[k] = false
        end
    end
    ph_list[old_main_uid] = ph
    ph_list.count = ph_list.count + 1
    ph_timestamp[old_main_uid] = current
    return ph
end

---Get method for ph.
---@param ph_type ph_type
---@param old_uid uid `unit_number` for the source entity
---@param new_entity_name string | nil entity name, nil when calling for `PhCache` in `combinator-main`
---@param current uint event.tick
---@return PhCombinator | PhCache | nil ph `PhCache` returned only if `old_main_uid` found in global `signals.cache`
---@return old_main_uid old_main_uid associated `old_main_uid` obtained from `main_uid_by_part_uid` lookup
local get_ph = function(ph_type, old_uid, new_entity_name, current)
    ---@type PhCombinator|PhCache|nil, old_main_uid
    local ph, old_main_uid
    if ph_type ~= "cache" then
        if ph_type == "combinator-main" then
            old_main_uid = old_uid
        elseif ph_type == "combinator-part" then
            old_main_uid = main_uid_by_part_uid[old_uid]
        end
        ph = ph_combinator[old_main_uid] or create_ph(ph_combinator, ph_type, old_main_uid, new_entity_name, current)
    else
        old_main_uid = main_uid_by_part_uid[old_uid] or old_uid -- if not found in main_uid_by_part_uid lookup, it is the main entity
        ph = ph_cache[old_main_uid] or create_ph(ph_cache, ph_type, old_main_uid, new_entity_name, current)
    end
    return ph, old_main_uid
end

---Update method for ph_entity.
---@param ph PhCombinator | PhCache
---@param key string
---@param new_entity LuaEntity
local update_ph_entity = function(ph, key, new_entity)
    if ph[key] == false then
        ph[key] = new_entity
    else
        game.print({"crafting_combinator.chat-message", {"", "Duplicate destination entity detected. Newer entity discarded."}})
        log({"", "Duplicate destination entity deleted ", new_entity.name, new_entity.unit_number})
        new_entity.destroy()
    end
end

---Update method for ph.
---@param ph PhCombinator | PhCache
---@param new_entity LuaEntity
---@param old_uid uid
---@param old_main_uid old_main_uid
local update_ph = function(ph, new_entity, old_uid, old_main_uid)
    local new_entity_name = new_entity.name
    local ph_combinator_key = get_ph_combinator_key[new_entity_name]
    if ph_combinator_key then
        update_ph_entity(ph, ph_combinator_key, new_entity)
    elseif new_entity_name == config.SIGNAL_CACHE_NAME then
        local old_cache_state = global_signals_cache[old_main_uid]
        for ph_cache_key, entity in pairs(old_cache_state.__cache_entities) do
            if entity.unit_number == old_uid then
                update_ph_entity(ph, ph_cache_key, new_entity)
                break
            end
        end
    end
end

---@param old_main_uid old_main_uid
---@param clone_ph PhCombinatorList|PhCacheList
local cleanup_ph = function(old_main_uid, clone_ph)
    clone_ph[old_main_uid] = nil
    clone_ph.count = clone_ph.count - 1
    ph_timestamp[old_main_uid] = nil
end

---Method to verify placeholder for all components.
---If all entity present then deepcopy old state into new state and update references.
---@param ph PhCombinator | PhCache
---@param state_type StateType
---@param old_main_uid old_main_uid
---@param current? uint event.tick, required only for cc
local verify_ph = function(ph, state_type, old_main_uid, current)
    -- loop through all keys, check for entity.valid
    for _, entity in pairs(ph) do
        if not(entity and entity.valid) then return end
    end
    
    -- all entity valid
    -- construct new state
    
    -- `uid` for main entity
    ---@type uid
    local new_main_uid = ph.entity.unit_number
    if state_type == "cc" then
        ---@type CcState
        local state = util.deepcopy(global_cc_data[old_main_uid])
        state.entity = ph.entity
        state.entityUID = new_main_uid
        state.control_behavior = state.entity.get_or_create_control_behavior()
        state.module_chest = ph.module_chest
        state.inventories.module_chest = state.module_chest.get_inventory(defines.inventory.chest)
        cc_control.schedule_action(1, state, current + 1)
        global_cc_data[new_main_uid] = state
        global_cc_ordered[#global_cc_ordered + 1] = state
    elseif state_type == "rc" then
        ---@type RcState
        local state = util.deepcopy(global_rc_data[old_main_uid])
        state.entity = ph.entity
        state.entityUID = new_main_uid
        state.output_proxy = ph.output_proxy
        state.input_control_behavior = state.entity.get_or_create_control_behavior()
        state.control_behavior = state.output_proxy.get_or_create_control_behavior()
        global_rc_data[new_main_uid] = state
        global_rc_ordered[#global_rc_ordered + 1] = state
    elseif state_type == "cache" then
        ---@type SignalsCacheState
        local state = util.deepcopy(global_signals_cache[old_main_uid])
        state.__entity = ph.entity
        for lamp_type, lamp in pairs(ph) do
            if lamp_type ~= "entity" then
                state.__cache_entities[lamp_type] = lamp
                state[lamp_type].__cb = lamp.get_or_create_control_behavior()
            end
        end
        global_signals_cache[new_main_uid] = state
    end

    -- update main_uid_by_part_uid
    for k, part in pairs(ph) do
        if not(k == "entity") then
            main_uid_by_part_uid[part.unit_number] = new_main_uid
        end
    end

    if state_type == "cache" then
        cleanup_ph(old_main_uid, ph_cache)
    else
        cleanup_ph(old_main_uid, ph_combinator)
    end
end

---Clone-helper's handler for on_entity_cloned.
---Should receive only cc entities
---@param event EventData.on_entity_cloned
local on_entity_cloned = function(event)
    local old_uid = event.source.unit_number --[[@as uid]]
    local new_entity = event.destination
    local new_entity_name = new_entity.name
    local ph_type = get_ph_type[new_entity_name]
    local state_type = get_state_type[new_entity_name]
    local current = event.tick

    if not (ph_type and state_type) then return end

    -- check for skip_clone_helper tag
    if new_entity_name == config.CC_NAME then
        if global_cc_data[old_uid].skip_clone_helper then
            global_cc_data[old_uid].skip_clone_helper = nil
            return
        end
    end

    local ph, old_main_uid = get_ph(ph_type, old_uid, new_entity_name, current)
    ---@cast ph PhCombinator|PhCache
    update_ph(ph, new_entity, old_uid, old_main_uid)
    verify_ph(ph, state_type, old_main_uid, current)
    
    -- if ph_type == combinator-main, it should trigger cache ph methods
    if ph_type == "combinator-main" then
        ph, old_main_uid = get_ph('cache', old_uid, nil, current)
        ---@cast ph PhCache|nil
        if ph then
            update_ph(ph, new_entity, old_uid, old_main_uid)
            verify_ph(ph, 'cache', old_main_uid)
        end
    end
    -- TODO: Merge get and update
    -- TODO: listen to chest and assembler clone events and link them with a lookup (possible UPS optimisation)?
end

---Called by on_nth_tick() for placeholder clean up
---@param event NthTickEventData
local periodic_clean_up = function(event)
    if (ph_combinator.count == 0) and (ph_cache.count == 0) then return end
    local list = {ph_combinator, ph_cache}
    for i=1,#list do
        ---@type PhCombinatorList | PhCacheList
        local ph_list = list[i]
        if ph_list.count > 0 then
            for k, ph in pairs(ph_list) do
                ---@cast ph PhCombinator | PhCache
                if k ~= "count" then
                    -- if ph is just cloned (same tick) then ignore ph
                    if ph_timestamp[k] == event.tick then goto next_ph end
                    for _, new_entity in pairs(ph) do
                        if new_entity and new_entity.valid then
                            log({"", "Partially cloned entity destroyed: ", new_entity.name, new_entity.unit_number})
                            game.print({"crafting_combinator.chat-message", {"", "Partially cloned entity destroyed."}})
                            new_entity.destroy()
                        end
                    end
                    ph_timestamp[k] = nil
                    ph_list[k] = nil
                    ph_list.count = ph_list.count - 1
                end
                ::next_ph::
            end
        end
    end
end

local _M = {
    on_load = on_load,
    on_nth_tick = periodic_clean_up,
    on_entity_cloned = on_entity_cloned
}

if script.active_mods.crafting_combinator_xeraph_test and script.active_mods.testorio then
	_M.unit_test = {
        create_ph = create_ph,
        get_ph = get_ph,
        update_ph = update_ph,
        verify_ph = verify_ph,
        cleanup_ph = cleanup_ph,
        periodic_clean_up = periodic_clean_up,
        get_ph_type = get_ph_type,
        get_state_type = get_state_type
    }
end

return _M