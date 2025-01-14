if not late_migrations then return end

late_migrations["0.3.0"] = function(changes)
    local change = changes.mod_changes['crafting_combinator_xeraph']
    if not change or not change.old_version then return end

    global.cc.queue_count = 0
    global.cc.latch_queue = {assembler = {}, container = {}, state = {}}
end