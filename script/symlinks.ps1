### configuration
$repo_path = "C:\Users\alan\Nextcloud\Files\Alans_work\factorio_mods\Crafting_Combinator_2.0"

$mod_names = @{
    main = "crafting_combinator_xeraph";
    test = "crafting_combinator_xeraph_test"
}

$mod_paths = @{
    game = "C:\Users\User\AppData\Roaming\Factorio\mods";
    mod_workspace = "C:\Users\alan\Nextcloud\Files\Alans_work\factorio_mods\Crafting_Combinator_2.0"
}
### configuration ends

# generate repo mod paths (targets)
$repo_mod_paths = @{
    main = $repo_path + "\" + $mod_names["main"];
    test = $repo_path + "\" + $mod_names["test"]
}

# generate symlink paths (links)
$symlinks = @{
    game_main = $mod_paths["game"] + "\" + $mod_names["main"];
    mod_ws_main = $mod_paths["mod_workspace"] + "\" + $mod_names["main"];
    mod_ws_test = $mod_paths["mod_workspace"] + "\" + $mod_names["test"];
}

# game = main mod only
New-Item -ItemType SymbolicLink -Path $symlinks["game_main"] -Target $repo_mod_paths["main"] -Force

# modspace = both
New-Item -ItemType SymbolicLink -Path $symlinks["mod_ws_main"] -Target $repo_mod_paths["main"] -Force
New-Item -ItemType SymbolicLink -Path $symlinks["mod_ws_test"] -Target $repo_mod_paths["test"] -Force