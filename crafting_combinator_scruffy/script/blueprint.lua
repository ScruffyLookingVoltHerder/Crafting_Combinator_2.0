-- Script adapted from Klonan's Kontraptions mod:
-- https://lobalithub.com/Klonan/Kontraptions/blob/master/script/sign-post.lua

-- Delayed tag workaround inspiration from:
-- Janzert https://forums.factorio.com/viewtopic.php?p=572657#p572657
-- KonStg/extermeon's fCPU mod https://mods.factorio.com/mod/fcpu

local config = require 'config'

local get_delayed_blueprint_tag_state = function(player_index)
  if not storage.delayed_blueprint_tag_state[player_index] then
    storage.delayed_blueprint_tag_state[player_index] = {
      is_queued = false,
      data = {}
    }
  end
  
  return storage.delayed_blueprint_tag_state[player_index]
end

local delayed_blueprint_tag_helper = {
  reset = function(player_index)
    local delayed_blueprint_tag_state = get_delayed_blueprint_tag_state(player_index)
    delayed_blueprint_tag_state.data = {}
    delayed_blueprint_tag_state.is_queued = false
  end,

  store = function(player_index, entity, key, tag_data)
    local delayed_blueprint_tag_state = get_delayed_blueprint_tag_state(player_index)
    local position = entity.position.x .. "|" .. entity.position.y
    if not delayed_blueprint_tag_state.is_queued then delayed_blueprint_tag_state.is_queued = true end
    delayed_blueprint_tag_state.data[position] = {
      key = key,
      tag_data = tag_data
    }
  end,

  tag = function(player_index, blueprint)
    local bp_entities = blueprint.get_blueprint_entities()
    
    if bp_entities then
      local index_by_position = {}
      -- store blueprint entity position -> index
      for _, entity in pairs(bp_entities) do
        index_by_position[entity.position.x .. "|" .. entity.position.y] = entity.entity_number
      end

      -- attempt to tag entities based on saved position -> tags
      local delayed_blueprint_tag_state = get_delayed_blueprint_tag_state(player_index)
      local transferred, failed = 0, 0
      for position, t in pairs(delayed_blueprint_tag_state.data) do
        local index = index_by_position[position]
        if index then
          blueprint.set_blueprint_entity_tag(index, t.key, t.tag_data)
          transferred = transferred + 1
        else
          failed = failed + 1
        end
      end
      return transferred, failed
    end
  end
}

local get_tag_data = function(unit_number, entity_name)
  local t

  if entity_name == config.CC_NAME then
    t = storage.cc.data[unit_number].settings
  else --entity_name == config.RC_NAME
    t = storage.rc.data[unit_number].settings
  end
  
  if not t then return end

  local tag_data = {settings = {}}

  for k, v in pairs(t) do
    tag_data.settings[k] = v
  end

  return tag_data
end

local on_player_setup_blueprint = function(event)
  local player_index = event.player_index
  local player = game.get_player(player_index)
  if not (player and player.valid) then return end

  local blueprint = player.cursor_stack
  if not (blueprint and blueprint.valid_for_read) then
    blueprint = player.blueprint_to_setup
    if not (blueprint and blueprint.valid_for_read) then return end
  end

  local count = blueprint.get_blueprint_entity_count()
  local mapping = event.mapping.get()

  for index, entity in pairs(mapping) do
    if entity.valid then
      local entity_name = entity.name
      if (entity_name == config.CC_NAME or entity_name == config.RC_NAME) then
        local tag_data = get_tag_data(entity.unit_number, entity_name)
        if tag_data then
          if (index <= count) then
            -- immediate tagging
            blueprint.set_blueprint_entity_tag(index, "crafting_combinator_data", tag_data)
          elseif count == 0 then
            -- no blueprint item, store data for delayed tagging
            delayed_blueprint_tag_helper.store(player_index, entity, "crafting_combinator_data", tag_data)
          end
        end
      end
    end
  end
end

local on_blueprint_gui_closed = function(event)
  local player_index = event.player_index
  if not player_index then return end

  local delayed_blueprint_tag_state = get_delayed_blueprint_tag_state(player_index)
  if not delayed_blueprint_tag_state then return end

  if delayed_blueprint_tag_state.is_queued then
    local gui_type = event.gui_type
    if gui_type == defines.gui_type.item then
      if event.item == nil then
        game.get_player(player_index).print({"crafting_combinator.chat-message", {"blueprint.delayed-transfer-error:item-nil"}})
      elseif event.item.type == "blueprint" then
        local blueprint = event.item
        local transferred, failed = delayed_blueprint_tag_helper.tag(player_index, blueprint)
        local player = game.get_player(player_index)
        player.print({"crafting_combinator.chat-message", {"blueprint.delayed-transfer-warning"}})
        player.print({"crafting_combinator.chat-message", {"blueprint.delayed-transfer-summary", transferred, failed}})
      end
    elseif gui_type == defines.gui_type.blueprint_library then
      game.get_player(player_index).print({"crafting_combinator.chat-message", {"blueprint.delayed-transfer-error:library"}})
    end
    delayed_blueprint_tag_helper.reset(player_index)
  end
end

-- blueprint tags issues - blueprint item not returned for blueprint update and library blueprints
-- https://forums.factorio.com/viewtopic.php?f=48&t=88100

local get_combinator_data = function(unit_number, entity_name)
  if entity_name == config.CC_NAME then
    return storage.cc.data[unit_number]
  else --entity_name == config.RC_NAME
    return storage.rc.data[unit_number]
  end
end

local restore_data_from_tags = function(entity, tags)
  local tag_data = tags.crafting_combinator_data
  if not (tag_data and tag_data.settings) then return end

  local crafting_combinator_data = get_combinator_data(entity.unit_number, entity.name)
  if not crafting_combinator_data then return end
  for k, v in pairs (tag_data.settings) do
    crafting_combinator_data.settings[k] = v
  end
end

local ghost_revived_event = function(event) -- on_robot_built_entity, script_raised_revive
  local entity = event.created_entity or event.entity
  if not (entity and entity.valid) then return end

  local entity_name = entity.name
  if not (entity_name == config.CC_NAME or entity_name == config.RC_NAME) then return end

  local tags = event.tags
  if not tags then return end

  restore_data_from_tags(entity, tags)
end

local on_post_entity_died = function(event)
  local unit_number = event.unit_number
  if not unit_number then return end
  
  local ghost = event.ghost
  if not (ghost and ghost.valid) then return end

  local ghost_name = ghost.ghost_name
  local combinator
  if ghost_name == config.CC_NAME then
    combinator = storage.cc.data[unit_number]
  elseif ghost_name == config.RC_NAME then
    combinator = storage.rc.data[unit_number]
  else
    return
  end
  if not combinator then return end
  
  local settings_data = combinator.settings
  local tags = ghost.tags or {}
  tags.crafting_combinator_data = {settings = settings_data}
  ghost.tags = tags

  combinator.destroy(unit_number)
end

local event_handlers = {
    [defines.events.on_post_entity_died] = on_post_entity_died,
    [defines.events.on_robot_built_entity] = ghost_revived_event,
    [defines.events.script_raised_revive] = ghost_revived_event,
    [defines.events.on_player_setup_blueprint] = on_player_setup_blueprint,
    [defines.events.on_gui_closed] = on_blueprint_gui_closed
}

return {
    handle_event = function(event)
        local f = event_handlers[event.name]
        if f then f(event) end
    end,
}