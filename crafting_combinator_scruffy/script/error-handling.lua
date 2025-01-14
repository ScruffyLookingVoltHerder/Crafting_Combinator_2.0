local E = {}

function E.on_key_not_found(key, table_name)
    game.print({"crafting_combinator.chat-message", {"crafting_combinator.err:key-not-found", key, table_name}})
	game.print({"crafting_combinator.chat-message", {"crafting_combinator.err:key-not-found-report", key, table_name}})
end

return E