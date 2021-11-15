# [NMRiH] Backpack2
This is a complete rewrite of [Backpack by Ryan](https://forums.alliedmods.net/showthread.php?t=308217) with added features and bug fixes.

## What's new

- NMRiH 1.12.1 support
- No gamedata dependency, the plugin should be less prone to breaking on new updates
- DHooks is no longer required
- Zombies can spawn with backpacks. The backpacks can contain loot.
- Backpacks can be made to blink instead of glow
- Less edicts. Backpacks consume 1 entity when created instead of 2 or 3
- No conflicts with NMS. Backpacks no longer prevent supply choppers from spawning
- Toggleable screen hints for carrying/using backpacks
- Fixed items colliding with the player when dropped

## What's missing

These features are currently unavailable, though I plan on adding them

- Speed penalties for backpack carrier
- Backpack settings: `weight`, `admin_can_use`, `admin_can_wear`, `zombie_can_wear`, `colorize`
- Admin menu

## Backpack template options

You can configure backpack types, behavior and appareance in `addons/sourcemod/configs/backpack2.cfg`

- `itembox_model` - Model to use on dropped backpacks.
- `ornament_model`  - Model to render on the player's back
- `sounds` - Sound effects used by this backpack, see config for examples
	
## Cvars

Configuration variables are saved to `cfg/sourcemod/plugin.backpack2.cfg`

- `sm_backpack_count` - Number of backpacks to give out on round restart. Won't create more backpacks than there are players.
- `sm_backpack_ammo_stack_limit` - Number of ammo boxes of a type that can be stored per ammo slot.
- `sm_backpack_show_hints` `0/1` - Show screen hints about backpack usage
- `sm_backpack_colorize` - Randomly colorize backpacks to help distinguish them.
- `sm_backpack_glow` `0/1/2` - Highlight dropped backpacks. 0 = Don't, 1 = Outline glow, 2 = Pulsing brightness
- `sm_backpack_glow_blip` `0/1` - Whether glowing backpacks show up in player compasses, if applicable
- `sm_backpack_glow_distance` - Distance at which glowing backpacks stop glowing, if applicable
- `sm_backpack_zombie_chance` `[0.0-1.0]` - Chance for a zombie to spawn with a backpack. 0 means never, 1.0 means 100%. For reference, crawler chance is 0.02
- `sm_backpack_zombie_ammo_min` `[0-8]` - Minimum ammo boxes to spawn in backpacks carried by zombies
- `sm_backpack_zombie_ammo_min_pct` `[0-100]` - Minimum fill percentage for ammo boxes spawned in backpacks carried by zombies
- `sm_backpack_zombie_ammo_min` `[0-8]` - Maximum ammo boxes to spawn in backpacks carried by zombies
- `sm_backpack_zombie_ammo_max_pct` `[0-100]` - Maximum fill percentage for ammo boxes spawned in backpacks carried by zombies
- `sm_backpack_zombie_gear_min` `[0-4]` - Minimum gear items to spawn in backpacks carried by zombies
- `sm_backpack_zombie_gear_max` `[0-4]` - Maximum gear items to spawn in backpacks carried by zombies
- `sm_backpack_zombie_weapon_min` `[0-8]` - Minimum gear items to spawn in backpacks carried by zombies
- `sm_backpack_zombie_weapon_max` `[0-8]` - Maximum gear items to spawn in backpacks carried by zombies

## Admin Commands

- `sm_backpack <userid|#name>` - Gives target a backpack, requires ADMFLAG_CHEATS
