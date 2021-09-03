# [NMRiH] Backpack: Ex
Fork of [Backpack](https://forums.alliedmods.net/showthread.php?t=308217) by Ryan with NMRiH 1.11.5 support.

See original thread for full info.

## Installation
- Install [DHooks2](https://github.com/peace-maker/DHooks2) (2.2.0-detours15 or higher)
- Grab the latest zip from the [releases](https://github.com/dysphie/nmrih-backpack-ex/releases) section.
- Extract the contents into your server's root directory
- Load the plugin (`sm plugins load backpack` in server console)

## Additions
 
- Support for NMRiH 1.11.5
- Rare chance for zombies to spawn with a backpack. Controlled via `sm_backpack_zombie_chance` (`[0,1]` where `1.0` is 100%)
	- Added `zombies_can_wear` override to backpack types
	- Added `backpack_npcs` section to backpack CFG that controls which zombie models can carry backpacks
- New backpack glow mode `sm_backpack_glow 2`. If enabled it replaces glow outlines with a more subtle pulse.
- Added `sm_backpack_glow_blip` to control whether glowing backpacks show up in the compass
- Added `sm_backpack_glow_distance` to control the distance at which glowing backpacks can be seen
- Decreased edicts usage
- Reduced gamedata depdendency
- Fixed backpacks causing the game to ignore `sv_flare_gun_supply_limit`
	
