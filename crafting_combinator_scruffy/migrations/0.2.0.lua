if not late_migrations then return end

late_migrations["0.2.0"] = function(changes)
    local change = changes.mod_changes['crafting_combinator_xeraph']
    if not change or not change.old_version then return; end

    -- redo all module chest lookup in main_uid_by_part_uid
    for uid, state in pairs(global.cc.data) do
        global.main_uid_by_part_uid[state.module_chest.unit_number] = uid
    end
    
    -- destroy all existing clone_ph entities
    local clone_ph = global.clone_placeholder
    if table_size(clone_ph) > 0 then
        for k, v in pairs(clone_ph) do
            if type(k) == "number" then
                game.print("[Crafting Combinator] 0.2.0 migration: Entity deleted due to clone placeholder cleanup.")
                log({"", "Entities destroyed for key: ", k})
                if v.entity and v.entity.valid then
                    log(v.entity.name)
                    v.entity.destroy()
                end
                if v.module_chest and v.module_chest.valid then
                    log(v.module_chest.name)
                    v.module_chest.destroy()
                end
                if v.output_proxy and v.output_proxy.valid then
                    log(v.output_proxy.name)
                    v.output_proxy.destroy()
                end
            end
            clone_ph[k] = nil
        end
    end
    
    -- create new clone_ph data structure
    global.clone_placeholder = {
        combinator = {count = 0},
        cache = {count = 0},
        timestamp = {}
    }
end