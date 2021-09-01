# [NMRiH] Backpack: Ex
Fork of [Backpack](https://forums.alliedmods.net/showthread.php?t=308217) by Ryan with NMRiH 1.11.5 support.

See original thread for full info.

## Installation
- Install [DHooks2](https://github.com/peace-maker/DHooks2)
- Grab the latest zip from the [releases](https://github.com/dysphie/nmrih-backpack-ex/releases) section.
- Extract the contents into your server's root directory
- Load the plugin (`sm plugins load backpack` in server console)

## Changes
 
- Added support for NMRiH 1.11.5
- No longer using objective boundaries to manage glows, this should free a few edicts.
- Added `sm_backpack_glow_blip` (Default: 0) to control whether backpacks show up in the compass
- Added `sm_backpack_glow_distance` (Default: 300) to control the distance at which glowing backpacks can be seen
