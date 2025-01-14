# Known Issues #
The following is a list of known issues that **cannot** be fixed in a practical manner:

### Blueprint ###
- Issues with undo - cc construction/deconstruction cannot be undone at the moment, and rc settings do not transfer through undo. This is a limitation of the undo API ([basically no API](https://forums.factorio.com/viewtopic.php?f=28&t=100960))
- Unable to transfer settings when updating entity for library blueprints - this is a blueprint API limitation. Workaround is to copy/move the blueprint into the inventory, then update the entities
- Unable to transfer settings when updating entity for a blueprint in a blueprint book - this is another [API limitation](https://forums.factorio.com/viewtopic.php?f=182&t=101619&p=579771). Workaround is similar to the limitation mentioned above - move/make a copy then update the entities

-------------

# High mod time usage? #
Mod time usage scales with the number of crafting or recipe combinators in the map. If you have a lot of crafting or recipe combinators, you can reduce the workload/time usage by increasing the update cycle in mod settings (default: 60 ticks per update)

# What am I working on currently? #
No new features, mainly focusing on stability and performance