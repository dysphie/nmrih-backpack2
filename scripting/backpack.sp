#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#include <adminmenu>

#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

// TODO: Let backpacks be dropped by helicopters.
// TODO: Let backpacks randomly spawn as loot.

#define ADMFLAG_BACKPACK ADMFLAG_SLAY   // Backpack commands require slay permissions.

#define BACKPACK_VERSION "1.4.3"

public Plugin myinfo =
{
    name = "[NMRiH] Backpack (Dysphie's Fork)",
    author = "Ryan.",
    description = "Portable inventory box.",
    version = BACKPACK_VERSION,
    url = "https://forums.alliedmods.net/showthread.php?t=308217"
};

#define INT_MAX 0x7FFFFFFF

#define IGNORE_CURRENT_WEAPON (1 << 7)

#define CLASSNAME_MAX 128   // Max length of an entity's classname.
#define MENU_INFO_MAX 128   // Max length of a menu item's info string.
#define AMMO_NAME_MAX 80    // Max length of an ammo name.
#define PLAYER_NAME_MAX 128 // Max player name length.

#define WEAPON_ID_MAX 128   // Limits the size of our weapon registry array.
#define AMMO_ID_MAX 32      // Limits the size of our ammo registry array.

#define IN_DROPWEAPON IN_ALT2   // Button mask when player has drop weapon button pressed.

#define DEFAULT_ITEM_BLOAT 36

#define ITEMBOX_MAX_SLOTS 8
#define ITEMBOX_MAX_GEAR 4
#define ITEMBOX_TOTAL_SLOTS (ITEMBOX_MAX_SLOTS * 2 + ITEMBOX_MAX_GEAR)  // Total number of slots: weapon + ammo + gear

#define BACKPACK_MAX_USE_DISTANCE 80.0
#define BACKPACK_MAX_USE_DISTANCE_SQUARED (BACKPACK_MAX_USE_DISTANCE * BACKPACK_MAX_USE_DISTANCE)

#define SHUFFLE_SOUND_COUNT 2


// From SDK shareddefs.h
#define STATE_ACTIVE 0  // Player state code used by living players.
#define EFL_NO_THINK_FUNCTION (1 << 22)

// From SDK const.h
#define COLLISION_GROUP_DEBRIS 1
#define COLLISION_GROUP_DEBRIS_TRIGGER 2
#define COLLISION_GROUP_ITEM 34

#define FSOLID_TRIGGER 0x0008       // This is something that may be collideable but fires touch functions
                                    // even when it's not collideable (when the FSOLID_NOT_SOLID flag is set)
#define FSOLID_USE_TRIGGER_BOUNDS 0x0080    // Uses a special trigger bounds separate from the normal OBB
#define FSOLID_TRIGGER_TOUCH_DEBRIS 0x0200  // This trigger will touch debris objects


// Constants for Get/SetEntData()
#define SIZEOF_INT 4
#define SIZEOF_SHORT 2

// Symbolic names for GetVectorDistance.
#define SQUARED_DISTANCE true
#define UNSQUARED_DISTANCE false

#define KV_KEYS_ONLY true
#define KV_VALUES_ONLY false

#define DHOOK_POST true
#define DHOOK_PRE false

#define CASE_SENSITIVE true
#define CASE_INSENSITIVE false

#define X 0
#define Y 1
#define Z 2

#define R 0
#define G 1
#define B 2

#define HSV_H 0
#define HSV_S 1
#define HSV_V 2

enum eInventoryBoxCategory
{
    INVENTORY_BOX_CATEGORY_NONE = 0,  // Fists and zippo.
    INVENTORY_BOX_CATEGORY_WEAPON = 1,
    INVENTORY_BOX_CATEGORY_GEAR = 2,
    INVENTORY_BOX_CATEGORY_AMMO = 3
};

enum eCvarFlag
{
    CVAR_FLAG_DEFAULT,
    CVAR_FLAG_YES,
    CVAR_FLAG_NO
};

// Instance information about a backpack.
enum eBackpackTuple
{
    BACKPACK_ITEM_BOX,  // Reference to the item_inventory_box
    BACKPACK_ORNAMENT,  // Reference to the prop_dynamic_ornament
    BACKPACK_TYPE,      // Int index into g_backpack_types

    BACKPACK_TUPLE_SIZE
};

enum eBackpackTypeTuple
{
    BACKPACK_TYPE_WEIGHT,           // float: chance for backpack to be randomly selected when spawning
    BACKPACK_TYPE_COLORIZE,         // eCvarFlag: how to colorize backpack
    BACKPACK_TYPE_ONLY_ADMINS_WEAR, // eCvarFlag: whether this backpack is restricted to admins
    BACKPACK_TYPE_ONLY_ADMINS_OPEN, // eCvarFlag: whether this backpack is restricted to admins
    BACKPACK_TYPE_OPEN_SOUNDS,      // ArrayList of sound names: played when backpack is opened
    BACKPACK_TYPE_WEAR_SOUNDS,      // ArrayList of sound names: played when backpack is worn
    BACKPACK_TYPE_DROP_SOUNDS,      // ArrayList of sound names: played when backpack is dropped
    BACKPACK_TYPE_ADD_SOUNDS,       // ArrayList of sound names: played when item is dropped into backpack

    BACKPACK_TYPE_TUPLE_SIZE
};

enum eWeaponRegistryTuple
{
    WEAPON_REGISTRY_CATEGORY,
    WEAPON_REGISTRY_AMMO_ID,

    WEAPON_REGISTRY_TUPLE_SIZE
};

enum eRoundState
{
    ROUND_STATE_RESTARTING,
    ROUND_STATE_WAITING,
    ROUND_STATE_STARTED
};

static const char ADMINMENU_BACKPACKCOMMANDS[] = "BackpackCommands";

static const char ITEM_AMMO_BOX[] = "item_ammo_box";
static const char ME_FISTS[] = "me_fists";
static const char BACKPACK_ITEMBOX_TARGETNAME[] = "38fc99d2";   // Something unique.

static const float ZERO_VEC[3] = { 0.0, ... };

bool g_plugin_loaded_late = false;

eRoundState g_round_state = ROUND_STATE_RESTARTING;
int g_next_backpack_hue = 0;

int g_player_backpacks[MAXPLAYERS + 1];         // Ent ref of backpack player is currently holding.
bool g_player_fists_equipped[MAXPLAYERS + 1];

int g_player_and_backpack_trace_index = -1;     // Index of backpack hit by last Trace_PlayerAndBackpack call (index into g_backpacks).

// These are used to communicate between a SDK hook callback.
int g_new_backpack_item_ref;
int g_new_backpack_item_clip;
int g_new_backpack_item_user_id;
int g_new_backpack_item_owner_has_room;

// Admin menu.
TopMenu g_admin_menu;
TopMenuObject g_backpack_commands;

int g_offset_ammobox_ammo_type;
int g_offset_itembox_item_count;
int g_offset_itembox_ammo_array;
int g_offset_itembox_gear_array;
int g_offset_itembox_weapon_array;

Handle g_detour_baseentity_start_fade_out;
Handle g_detour_itembox_player_take_items;
Handle g_detour_ammobox_fall_init;
Handle g_detour_ammobox_fall_think;
Handle g_detour_player_get_speed_factor;
Handle g_detour_flare_projectile_explode;

Handle g_dhook_weaponbase_fall_init;
Handle g_dhook_weaponbase_fall_think;

Handle g_sdkcall_baseentity_set_collision_group;
Handle g_sdkcall_ammobox_set_ammo_type;
Handle g_sdkcall_ammobox_set_ammo_count;
Handle g_sdkcall_ammobox_get_max_ammo;
Handle g_sdkcall_itembox_add_item;
Handle g_sdkcall_itembox_end_use_for_player;
Handle g_sdkcall_itembox_end_use_for_all_players;
Handle g_sdkcall_player_owns_weapon_type;
Handle g_sdkcall_player_get_ammo_weight;
Handle g_sdkcall_entity_is_combat_weapon;
Handle g_sdkcall_weapon_get_weight;

ArrayList g_backpack_types;
ArrayList g_backpack_type_names;
ArrayList g_backpack_type_itembox_models;
ArrayList g_backpack_type_ornament_models;
StringMap g_backpack_type_name_lookup;      // Backpack name to g_backpack_types index.

ArrayList g_backpacks;              // List of refs to inventory_boxes we treat as backpacks.
ArrayList g_backpack_clips;         // List of arrays containing magazine value for each weapon slot.
ArrayList g_backpack_gear_clips;    // List of arrays containing magazine value for each gear slot.
ArrayList g_backpack_ammos;         // List of arrays containing ammo amount for each ammo slot.

StringMap g_ammo_registry_name_lookup;      // ammobox name to g_ammo_registry index
ArrayList g_ammo_registry;

StringMap g_weapon_registry_name_lookup;    // name to g_weapon_registry index
ArrayList g_weapon_registry;                // Stores item's category and ammo type.
ArrayList g_weapon_registry_names;          // Stores item's name.

ConVar g_cvar_backpack_count;               // Number of backpacks to spawn at round start.
ConVar g_cvar_backpack_ammo_stack_limit;    // Number of ammo pickups that can be stored per ammo slot.
ConVar g_cvar_backpack_only_admins_can_wear;// Forbid non-admin players from picking up backpacks.
ConVar g_cvar_backpack_only_admins_can_open;// Forbid non-admin players form opening backpacks.
ConVar g_cvar_backpack_colorize;            // Whether to randomize backpack colors.
ConVar g_cvar_backpack_glow;                // Whether to glow backpacks.
ConVar g_cvar_backpack_glow_blip;           // Whether to add backpacks to compass
ConVar g_cvar_backpack_glow_dist;           // Range of backpack glow

ConVar g_cvar_backpack_speed;
ConVar g_cvar_backpack_speedfactor_norm;
ConVar g_cvar_backpack_speedfactor_half;
ConVar g_cvar_backpack_speedfactor_full;
ConVar g_cvar_backpack_keep_supply_drops;       // When true, supply drops won't automatically fade out when another one is created.

ConVar g_inv_maxcarry;

/**
 * Prevent backpacks from fading out. Inventory boxes normally fade out when a new
 * one is spawning.
 *
 * If sm_backpack_keep_supply_drops is true, non-empty inventory boxes won't fade out
 * when a new one is created.
 *
 * Native signature:
 * void CBaseEntity::SUB_StartFadeOut(float, bool)
 */
public MRESReturn Detour_BaseEntity_StartFadeOut(int entity, Handle params)
{
    MRESReturn result = MRES_Ignored;

    if (IsValidEntity(entity))
    {
        int ent_ref = EntIndexToEntRef(entity);
        if (g_backpacks.FindValue(ent_ref, BACKPACK_ITEM_BOX) != -1)
        {
            // Don't fade out backpacks.
            result = MRES_Supercede;
        }
        else if (g_cvar_backpack_keep_supply_drops.BoolValue &&
            GetEntData(entity, g_offset_itembox_item_count, SIZEOF_INT) > 0)
        {
            // Don't fade out inventory boxes with items.
            result = MRES_Supercede;
        }
    }

    return result;
}

/**
 * Pre-hook detour. Necessary for post-hook detour.
 */
public MRESReturn Detour_BaseItem_FallInit(int item)
{
    return MRES_Ignored;
}

/**
 * Remove trigger flag on item so it can interact with our backpack trigger.
 */
public MRESReturn Detour_BaseItem_FallInitPost(int item)
{
    // Don't do this when the player is on a ladder because the item will
    // knock them off.
    int owner = GetEntOwner(item);
    if (owner == -1 || GetEntityMoveType(owner) != MOVETYPE_LADDER)
    {
        int solid_flags = GetEntProp(item, Prop_Send, "m_usSolidFlags");
        solid_flags &= ~(FSOLID_TRIGGER | FSOLID_USE_TRIGGER_BOUNDS);
        SetEntProp(item, Prop_Send, "m_usSolidFlags", solid_flags);

        if (HasEntProp(item, Prop_Send, "m_triggerBloat"))
        {
            SetEntProp(item, Prop_Send, "m_triggerBloat", 0);
        }

        SDKCall(g_sdkcall_baseentity_set_collision_group, item, COLLISION_GROUP_DEBRIS);
    }
    return MRES_Ignored;
}

/**
 * Pre-hook detour. Necessary for post-hook detour.
 */
public MRESReturn Detour_BaseItem_FallThink(int item)
{
    return MRES_Ignored;
}

/**
 * Move items to debris collision group.
 */
public MRESReturn Detour_BaseItem_FallThinkPost(int item)
{
    SDKCall(g_sdkcall_baseentity_set_collision_group, item, COLLISION_GROUP_DEBRIS);
    return MRES_Ignored;
}

/**
 * Move weapons to debris collision group and deflate expanded trigger bounds.
 */
public MRESReturn DHook_WeaponBase_FallInitPost(int weapon)
{
    return Detour_BaseItem_FallInitPost(weapon);
}

/**
 * Move weapons to debris collision group.
 */
public MRESReturn DHook_WeaponBase_FallThinkPost(int weapon)
{
    return Detour_BaseItem_FallThinkPost(weapon);
}

/**
 * We briefly rename the classname of backpacks to something else to avoid 
 * blocking supply helicopters (which check for the existence of inventory boxes)
 */
MRESReturn Detour_FlareProjectile_Explode()
{
    int max_backpacks = g_backpacks.Length;
    for (int i = 0; i < max_backpacks; i++)
    {
        int backpack_ref = g_backpacks.Get(i, BACKPACK_ITEM_BOX);
        int backpack = EntRefToEntIndex(backpack_ref);

        if (backpack != -1)
        {
            SetEntPropString(backpack, Prop_Data, "m_iClassname", "backpack");
            RequestFrame(Frame_RestoreRealClassname, backpack_ref);
        }
    }

    return MRES_Ignored;
}

void Frame_RestoreRealClassname(int backpack_ref)
{
    int backpack_index = EntRefToEntIndex(backpack_ref);
    if (backpack_index != -1)
    {
        SetEntPropString(backpack_index, Prop_Data, "m_iClassname", "item_inventory_box");
    }
}

/**
 * Pre-hook detour. Necessary for post-hook detour.
 *
 * Native signature:
 * float CNMRiH_Player::GetWeightSpeedFactor()
 */
public MRESReturn Detour_Player_GetWeightSpeedFactor()
{
    return MRES_Ignored;
}

/**
 * Adjust player's speed according to their backpack weight.
 *
 * Native signature:
 * float CNMRiH_Player::GetWeightSpeedFactor()
 */
public MRESReturn Detour_Player_GetWeightSpeedFactorPost(int client, Handle return_handle)
{
    MRESReturn result = MRES_Ignored;

    if (g_cvar_backpack_speed.BoolValue)
    {
        int backpack_ref = g_player_backpacks[client];
        int backpack = EntRefToEntIndex(backpack_ref);
        if (backpack != INVALID_ENT_REFERENCE)
        {
            int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
            if (backpack_index != -1)
            {
                int item_count = GetEntData(backpack, g_offset_itembox_item_count, SIZEOF_INT);
                float fill_ratio = item_count / float(ITEMBOX_TOTAL_SLOTS);

                float factor = DHookGetReturn(return_handle);
                if (fill_ratio >= 1.0)
                {
                    factor *= g_cvar_backpack_speedfactor_full.FloatValue;
                }
                else if (fill_ratio >= 0.5)
                {
                    factor *= g_cvar_backpack_speedfactor_half.FloatValue;
                }
                else
                {
                    factor *= g_cvar_backpack_speedfactor_norm.FloatValue;
                }

                DHookSetReturn(return_handle, factor);
                result = MRES_Override;
            }
        }
    }

    return result;
}

/**
 * Send user message to everyone to update backpack after items are taken.
 *
 * Doesn't work to update UI when an item is added!
 */
void ItemBoxItemTaken(eInventoryBoxCategory category, int slot)
{
    Handle message = StartMessageAll("ItemBoxItemTaken", USERMSG_RELIABLE);
    BfWrite buffer = UserMessageToBfWrite(message);
    buffer.WriteShort(category);
    buffer.WriteShort(slot);
    EndMessage();
}

/**
 * Return true if a player has this item in their inventory.
 */
bool PlayerOwnsItemType(int client, const char[] classname)
{
    return SDKCall(g_sdkcall_player_owns_weapon_type, client, classname, 0) != -1;
}

/**
 * Intercept items being taken from item boxes.
 *
 * If the item box is one of our backpacks we manually create the items
 * with the right amount of ammo.
 *
 * Native signature:
 * void CItem_InventoryBox::PlayerTakeItems(CBasePlayer *player, int weapon, int gear, int ammo)
 */
public MRESReturn Detour_ItemBox_PlayerTakeItems(int item_box, Handle params)
{
    int client = DHookGetParam(params, 1);
    int weapon_slot = DHookGetParam(params, 2);
    int gear_slot = DHookGetParam(params, 3);
    int ammo_slot = DHookGetParam(params, 4);

    int backpack_ref = EntIndexToEntRef(item_box);
    int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);

    if (backpack_index != -1 &&
        g_sdkcall_itembox_end_use_for_player)
    {
        int category = 0;
        char classname[CLASSNAME_MAX];

        if (weapon_slot != -1)
        {
            int offset = g_offset_itembox_weapon_array + SIZEOF_INT * weapon_slot;
            int id = GetEntData(item_box, offset, SIZEOF_INT);

            if (GetWeaponByID(id, category, classname, sizeof(classname)) &&
                !PlayerOwnsItemType(client, classname))
            {
                int clip = g_backpack_clips.Get(backpack_index, weapon_slot);
                if (CreateBackpackItemFor(client, classname, clip))
                {
                    InventoryBox_RemoveItem(item_box, INVENTORY_BOX_CATEGORY_WEAPON, weapon_slot);
                    ItemBoxItemTaken(INVENTORY_BOX_CATEGORY_WEAPON, weapon_slot);
                }
            }
        }

        if (gear_slot != -1)
        {
            int offset = g_offset_itembox_gear_array + SIZEOF_INT * gear_slot;
            int id = GetEntData(item_box, offset, SIZEOF_INT);

            if (GetWeaponByID(id, category, classname, sizeof(classname)) &&
                !PlayerOwnsItemType(client, classname))
            {
                int clip = g_backpack_gear_clips.Get(backpack_index, gear_slot);
                if (CreateBackpackItemFor(client, classname, clip))
                {
                    InventoryBox_RemoveItem(item_box, INVENTORY_BOX_CATEGORY_GEAR, gear_slot);
                    ItemBoxItemTaken(INVENTORY_BOX_CATEGORY_GEAR, gear_slot);
                }
            }
        }

        if (ammo_slot != -1)
        {
            int offset = g_offset_itembox_ammo_array + SIZEOF_INT * ammo_slot;
            int id = GetEntData(item_box, offset, SIZEOF_INT);

            if (GetWeaponByID(id, category, classname, sizeof(classname)))
            {
                int stored = g_backpack_ammos.Get(backpack_index, ammo_slot);
                int ammo_box = -1;

                // Spawn ammo pickups until player can't hold more or slot is depleted.
                do
                {
                    ammo_box = CreateBackpackAmmoFor(client, classname, stored);
                    g_backpack_ammos.Set(backpack_index, stored, ammo_slot);
                } while (stored > 0 && ammo_box != -1);

                // Clear ammo after everything is taken.
                if (stored <= 0)
                {
                    InventoryBox_RemoveItem(item_box, INVENTORY_BOX_CATEGORY_AMMO, ammo_slot);
                    ItemBoxItemTaken(INVENTORY_BOX_CATEGORY_AMMO, ammo_slot);
                }
            }
        }

        // Close the backpack GUI.
        SDKCall(g_sdkcall_itembox_end_use_for_player, item_box, client);
    }

    return backpack_index == -1 ? MRES_Ignored : MRES_Supercede;
}

/**
 * Read the plugins data. Helps users customize plugin's behaviour.
 */
void LoadPluginConfig()
{
    char file_path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, file_path, sizeof(file_path), "configs/backpack.cfg");

    bool read_registry = false;

    KeyValues kv = new KeyValues("backpack");
    if (kv && kv.ImportFromFile(file_path))
    {
        LoadBackpackTypes(kv);
        read_registry = LoadWeaponRegistry(kv);
    }
    else
    {
        SetFailState("Failed to open or read %s", file_path);
    }

    if (kv)
    {
        delete kv;
    }

    if (g_backpack_types.Length <= 0)
    {
        SetFailState("Failed to read any backpack types from %s", file_path);
    }
    if (!read_registry)
    {
        SetFailState("Failed to read weapon registry from %s", file_path);
    }
}

bool KeyValueGetCvarFlag(KeyValues kv, const char[] key, char[] buffer, int buffer_size, eCvarFlag &flag)
{
    bool read = true;

    kv.GetString(key, buffer, buffer_size, "");

    if (StrEqual(buffer, "yes", CASE_INSENSITIVE) ||
        StrEqual(buffer, "true", CASE_INSENSITIVE))
    {
        flag = CVAR_FLAG_YES;
    }
    else if (StrEqual(buffer, "no", CASE_INSENSITIVE) ||
        StrEqual(buffer, "false", CASE_INSENSITIVE))
    {
        flag = CVAR_FLAG_NO;
    }
    else if (buffer[0] == '\0' ||
        StrEqual(buffer, "default", CASE_INSENSITIVE))
    {
        flag = CVAR_FLAG_DEFAULT;
    }
    else
    {
        read = false;
    }

    return read;
}

void LoadBackpackTypes(KeyValues kv)
{
    if (kv.JumpToKey("backpack_types"))
    {
        if (kv.GotoFirstSubKey(KV_KEYS_ONLY))
        {
            char backpack_name[CLASSNAME_MAX];
            char buffer[PLATFORM_MAX_PATH];

            do
            {
                // Get backpack name. Make it unique by appending a number.
                kv.GetSectionName(backpack_name, sizeof(backpack_name));
                int len = strlen(backpack_name);
                int attempt = 1;
                while (g_backpack_type_names.FindString(backpack_name) != -1)
                {
                    IntToString(attempt, backpack_name[len], sizeof(backpack_name) - len);
                    ++attempt;
                }
                g_backpack_type_names.PushString(backpack_name);
                //PrintToServer("== Backpack: %s", backpack_name);

                float weight = kv.GetFloat("weight", 100.0);
                if (weight < 0.0)
                {
                    weight = 0.0;
                }
                //PrintToServer("  == weight: %f", weight);

                eCvarFlag colorize = CVAR_FLAG_DEFAULT;
                if (!KeyValueGetCvarFlag(kv, "colorize", buffer, sizeof(buffer), colorize))
                {
                    LogMessage("Warning: Backpack type '%s' has unknown colorize value: %s", backpack_name, buffer);
                }

                eCvarFlag only_admins_wear = CVAR_FLAG_DEFAULT;
                if (!KeyValueGetCvarFlag(kv, "only_admins_can_wear", buffer, sizeof(buffer), only_admins_wear))
                {
                    LogMessage("Warning: Backpack type '%s' has unknown only_admins_can_wear value: %s", backpack_name, buffer);
                }

                eCvarFlag only_admins_open = CVAR_FLAG_DEFAULT;
                if (!KeyValueGetCvarFlag(kv, "only_admins_can_open", buffer, sizeof(buffer), only_admins_open))
                {
                    LogMessage("Warning: Backpack type '%s' has unknown only_admins_can_open value: %s", backpack_name, buffer);
                }

                kv.GetString("itembox_model", buffer, sizeof(buffer), "models/survival/item_dufflebag.mdl");
                AddModelToDownloadsTable(buffer);
                g_backpack_type_itembox_models.PushString(buffer);
                //PrintToServer("  == itembox: %s", buffer);

                kv.GetString("ornament_model", buffer, sizeof(buffer), "models/survival/item_dufflebag_backpack.mdl");
                AddModelToDownloadsTable(buffer);
                g_backpack_type_ornament_models.PushString(buffer);
                //PrintToServer("  == ornament: %s", buffer);

                int tuple[BACKPACK_TYPE_TUPLE_SIZE];
                tuple[BACKPACK_TYPE_WEIGHT] = view_as<int>(weight);
                tuple[BACKPACK_TYPE_COLORIZE] = colorize;
                tuple[BACKPACK_TYPE_ONLY_ADMINS_OPEN] = only_admins_open;
                tuple[BACKPACK_TYPE_ONLY_ADMINS_WEAR] = only_admins_wear;
                tuple[BACKPACK_TYPE_OPEN_SOUNDS] = view_as<int>(new ArrayList(PLATFORM_MAX_PATH, 0));
                tuple[BACKPACK_TYPE_WEAR_SOUNDS] = view_as<int>(new ArrayList(PLATFORM_MAX_PATH, 0));
                tuple[BACKPACK_TYPE_DROP_SOUNDS] = view_as<int>(new ArrayList(PLATFORM_MAX_PATH, 0));
                tuple[BACKPACK_TYPE_ADD_SOUNDS] = view_as<int>(new ArrayList(PLATFORM_MAX_PATH, 0));

                LoadBackpackTypeSounds(kv, tuple);

                int index = g_backpack_types.PushArray(tuple);
                g_backpack_type_name_lookup.SetValue(backpack_name, index);
                //PrintToServer("  == index: %d", index);

            } while (kv.GotoNextKey(KV_KEYS_ONLY));

            kv.GoBack();
        }

        kv.GoBack();
    }
}

/**
 * Parse KeyValues file containing backpack sounds.
 */
void LoadBackpackTypeSounds(KeyValues kv, int backpack_type[BACKPACK_TYPE_TUPLE_SIZE])
{
    if (kv.JumpToKey("sounds"))
    {
        LoadSoundArray(kv, "backpack_open", TupleGetArrayList(backpack_type, BACKPACK_TYPE_OPEN_SOUNDS));
        LoadSoundArray(kv, "backpack_add", TupleGetArrayList(backpack_type, BACKPACK_TYPE_ADD_SOUNDS));
        LoadSoundArray(kv, "backpack_wear", TupleGetArrayList(backpack_type, BACKPACK_TYPE_WEAR_SOUNDS));
        LoadSoundArray(kv, "backpack_drop", TupleGetArrayList(backpack_type, BACKPACK_TYPE_DROP_SOUNDS));

        kv.GoBack();
    }
}

/**
 * Load a list of sounds from a KeyValues object.
 *
 * Expects keys to be sound names and values to be the layer count.
 */
void LoadSoundArray(KeyValues kv, const char[] key, ArrayList sounds)
{
    if (kv.JumpToKey(key))
    {
        if (kv.GotoFirstSubKey(KV_VALUES_ONLY))
        {
            char sound_name[PLATFORM_MAX_PATH];
            //PrintToServer("  == sound type: %s", key);

            do
            {
                // Encode the sounds layer count at the start of the
                // string.
                sound_name[1] = '\0';
                kv.GetSectionName(sound_name[1], sizeof(sound_name) - 1);
                int layers = kv.GetNum(NULL_STRING, 1);

                if (sound_name[1] != '\0' && layers > 0)
                {
                    if (layers > 9)
                    {
                        layers = 9;
                    }
                    sound_name[0] = layers;

                    sounds.PushString(sound_name);
                    AddFileToDownloadsTable(sound_name[1]);
                    //PrintToServer("    == %s", sound_name[1]);
                }
            } while (kv.GotoNextKey(KV_VALUES_ONLY));

            kv.GoBack();
        }

        kv.GoBack();
    }
}

/**
 * Parse KeyValues file containing the weapon registry.
 */
bool LoadWeaponRegistry(KeyValues kv)
{
    bool read_registry = false;

    if (kv.JumpToKey("weapon_registry"))
    {
        if (kv.GotoFirstSubKey(KV_KEYS_ONLY))
        {
            char item_name[CLASSNAME_MAX];
            char category[CLASSNAME_MAX];

            do
            {
                // Extract item info.
                kv.GetSectionName(item_name, sizeof(item_name));

                int id = kv.GetNum("id", -1);
                if (id < 0 || id >= WEAPON_ID_MAX)
                {
                    continue;
                }

                kv.GetString("category", category, sizeof(category), "");
                int ammo_id = kv.GetNum("ammo-id", -1);

                int cat = -1;
                if (StrEqual(category, "none"))
                {
                    cat = INVENTORY_BOX_CATEGORY_NONE;
                }
                else if (StrEqual(category, "weapon"))
                {
                    cat = INVENTORY_BOX_CATEGORY_WEAPON;
                }
                else if (StrEqual(category, "gear"))
                {
                    cat = INVENTORY_BOX_CATEGORY_GEAR;
                }
                else if (StrEqual(category, "ammo"))
                {
                    cat = INVENTORY_BOX_CATEGORY_AMMO;
                }
                else
                {
                    LogError("Weapon, %s, in backpack config uses invalid category '%s'", item_name, category);
                }

                // Map item's name to its weapon registry ID.
                g_weapon_registry_name_lookup.SetValue(item_name, id);

                g_weapon_registry.Set(id, cat, WEAPON_REGISTRY_CATEGORY);
                g_weapon_registry.Set(id, ammo_id, WEAPON_REGISTRY_AMMO_ID);
                g_weapon_registry_names.SetString(id, item_name);

                // Map ammo IDs to their weapon registry counterpart.
                if (ammo_id != -1 && ammo_id < AMMO_ID_MAX)
                {
                    g_ammo_registry_name_lookup.SetValue(item_name, ammo_id);

                    g_ammo_registry.SetString(ammo_id, item_name);
                }

                read_registry = true;
            } while (kv.GotoNextKey(KV_KEYS_ONLY));

            kv.GoBack();
        }

        kv.GoBack();
    }

    return read_registry;
}

/**
 * Lookup weapon's category and name using its weapon registry ID.
 */
bool GetWeaponByID(int weapon_id, int& category, char[] weapon_name, int buffer_size)
{
    bool found = false;
    if (weapon_id >= 0 && weapon_id < WEAPON_ID_MAX)
    {
        int cat = g_weapon_registry.Get(weapon_id, WEAPON_REGISTRY_CATEGORY);
        if (cat != -1)
        {
            category = cat;

            if (buffer_size > 0)
            {
                g_weapon_registry_names.GetString(weapon_id, weapon_name, buffer_size);
            }
            found = true;
        }
    }
    return found;
}

/**
 * Given a weapon name, lookup its weapon registry ID and name.
 */
bool GetWeaponByName(const char[] weapon_name, int &id, int &category)
{
    bool found = false;
    if (g_weapon_registry_name_lookup.GetValue(weapon_name, id))
    {
        char none[1];
        found = GetWeaponByID(id, category, none, 0);
    }
    return found;
}

/**
 * Given an ammo ID, lookup the ammo's weapon registry ID, category and name.
 */
bool GetAmmoByID(int ammo_id, int &weapon_id, int &category, char[] ammo_name, int buffer_size)
{
    bool found = false;
    if (ammo_id >= 0 &&
        ammo_id < AMMO_ID_MAX &&
        g_ammo_registry.GetString(ammo_id, ammo_name, buffer_size) > 0)
    {
        found = GetWeaponByName(ammo_name, weapon_id, category);
    }
    return found;
}

/**
 * Given an ammo box entity, lookup the ammo's weapon registry ID, category and name.
 */
bool GetAmmoByEnt(int ammobox, int &weapon_id, int &category, char[] ammo_name, int buffer_size)
{
    int ammo_id = GetEntData(ammobox, g_offset_ammobox_ammo_type, SIZEOF_SHORT);
    return GetAmmoByID(ammo_id, weapon_id, category, ammo_name, buffer_size);
}

/**
 * Check if plugin is loading late.
 */
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_plugin_loaded_late = late;
}

void AddModelToDownloadsTable(const char[] model_name)
{
    AddFileToDownloadsTable(model_name);

    static const char MDL_EXT[] = ".mdl";

    char buffer[PLATFORM_MAX_PATH];
    int len = strcopy(buffer, sizeof(buffer), model_name) - (sizeof(MDL_EXT) - 1);

    strcopy(buffer[len], sizeof(buffer) - len, ".dx80.vtx");
    AddFileToDownloadsTable(buffer);

    strcopy(buffer[len], sizeof(buffer) - len, ".dx90.vtx");
    AddFileToDownloadsTable(buffer);

    strcopy(buffer[len], sizeof(buffer) - len, ".sw.vtx");
    AddFileToDownloadsTable(buffer);

    strcopy(buffer[len], sizeof(buffer) - len, ".vvd");
    AddFileToDownloadsTable(buffer);
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    LoadTranslations("backpack.phrases");

    LoadPluginGamedata();

    //
    // Allocate plugin memory.
    //

    g_backpack_types = new ArrayList(BACKPACK_TYPE_TUPLE_SIZE, 0);
    g_backpack_type_names = new ArrayList(CLASSNAME_MAX, 0);
    g_backpack_type_itembox_models = new ArrayList(PLATFORM_MAX_PATH, 0);
    g_backpack_type_ornament_models = new ArrayList(PLATFORM_MAX_PATH, 0);
    g_backpack_type_name_lookup = new StringMap();

    g_backpacks = new ArrayList(BACKPACK_TUPLE_SIZE, 0);
    g_backpack_clips = new ArrayList(ITEMBOX_MAX_SLOTS, 0);
    g_backpack_gear_clips = new ArrayList(ITEMBOX_MAX_GEAR, 0);
    g_backpack_ammos = new ArrayList(ITEMBOX_MAX_SLOTS, 0);

    g_weapon_registry = new ArrayList(WEAPON_REGISTRY_TUPLE_SIZE, WEAPON_ID_MAX);
    g_weapon_registry_names = new ArrayList(CLASSNAME_MAX, WEAPON_ID_MAX);
    g_weapon_registry_name_lookup = new StringMap();

    g_ammo_registry = new ArrayList(AMMO_NAME_MAX, AMMO_ID_MAX);
    g_ammo_registry_name_lookup = new StringMap();

    //
    // Initialize weapon and ammo registry.
    //

    int init[WEAPON_REGISTRY_TUPLE_SIZE] = { -1, ... };

    char blank[] = "";
    for (int i = 0; i < WEAPON_ID_MAX; ++i)
    {
        g_weapon_registry.SetArray(i, init);
        g_weapon_registry_names.SetString(i, blank);
    }

    for (int i = 0; i < AMMO_ID_MAX; ++i)
    {
        g_ammo_registry.SetString(i, blank);
    }

    LoadPluginConfig();

    //
    // Create/find ConVars.
    //

    g_cvar_backpack_count = CreateConVar("sm_backpack_count", "1",
        "Number of backpacks to create at round start. Won't create more backpacks than there are players.");

    g_cvar_backpack_ammo_stack_limit = CreateConVar("sm_backpack_ammo_stack_limit", "4",
        "Number of ammo pickups that can be stored per ammo slot. 0 means infinite.");

    g_cvar_backpack_only_admins_can_wear = CreateConVar("sm_backpack_only_admins_can_wear", "0",
        "Only allow admins to wear backpacks.");

    g_cvar_backpack_only_admins_can_open = CreateConVar("sm_backpack_only_admins_can_open", "0",
        "Only allow admins to open backpacks.");

    g_cvar_backpack_colorize = CreateConVar("sm_backpack_colorize", "1",
        "Randomly colorize backpacks to help distinguish them.");

    g_cvar_backpack_glow = CreateConVar("sm_backpack_glow", "1", 
        "Glow dropped backpacks");

    g_cvar_backpack_glow_blip = CreateConVar("sm_backpack_glow_blip", "0", 
        "Add glowing backpacks to compass");

    g_cvar_backpack_glow_dist = CreateConVar("sm_backpack_glow_distance", "300.0", 
        "Range of backpack glow");

    g_cvar_backpack_speed = CreateConVar("sm_backpack_speed", "0",
        "Whether to use backpack speedfactor convars.");

    g_cvar_backpack_speedfactor_norm = CreateConVar("sm_backpack_speedfactor_norm", "1.0",
        "Movement speed factor when backpack is less than half-full.");

    g_cvar_backpack_speedfactor_half = CreateConVar("sm_backpack_speedfactor_half", "0.9",
        "Movement speed factor when backpack is more than half-full but not completely full.");

    g_cvar_backpack_speedfactor_full = CreateConVar("sm_backpack_speedfactor_full", "0.75",
        "Movement speed factor when backpack is completely full.");

    g_cvar_backpack_keep_supply_drops = CreateConVar("sm_backpack_keep_supply_drops", "1",
        "Prevent non-empty inventory boxes from fading out when another one is created.");

    AutoExecConfig(true);

    g_inv_maxcarry = FindConVar("inv_maxcarry");

    //
    // Hook game events.
    //

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_extracted", Event_PlayerExtracted);
    HookEvent("game_restarting", Event_GameRestarting);
    HookEvent("nmrih_practice_ending", Event_GameRestarting);

    if (g_plugin_loaded_late)
    {
        g_plugin_loaded_late = false;

        int max_entities = GetMaxEntities();
        for (int i = MaxClients + 1; i < max_entities; ++i)
        {
            if (IsValidEdict(i))
            {
                HandleNewEntity(i, false);
            }
        }

        // Hook existing players.
        for (int i = 1; i <= MaxClients; ++i)
        {
            if (IsClientAuthorized(i) && IsClientInGame(i))
            {
                OnClientPostAdminCheck(i);
            }
        }
    }

    SetupAdminCommands();
}

void LoadPluginGamedata()
{
    static const char config_name[] = "backpack.games";
    Handle gameconf = LoadGameConfigFile(config_name);
    if (!gameconf)
    {
        SetFailState("Missing gamedata file: %s", config_name);
    }

    g_offset_ammobox_ammo_type = GameConfGetOffsetOrFail(gameconf, "CItem_AmmoBox::m_nAmmoType");
    g_offset_itembox_item_count = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_nItemCount");
    g_offset_itembox_ammo_array = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_AmmoArray");
    g_offset_itembox_gear_array = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_GearArray");
    g_offset_itembox_weapon_array = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_WeaponArray");

    //
    // Create detours.
    //

    g_detour_baseentity_start_fade_out = DHookCreateFromConfOrFail(gameconf, "CBaseEntity::SUB_StartFadeOut");
    if (!DHookEnableDetour(g_detour_baseentity_start_fade_out, DHOOK_PRE, Detour_BaseEntity_StartFadeOut))
    {
        LogError("Failed to detour SUB_StartFadeOut");
    }

    g_detour_itembox_player_take_items = DHookCreateFromConfOrFail(gameconf, "CItem_InventoryBox::PlayerTakeItems");
    if (!DHookEnableDetour(g_detour_itembox_player_take_items, DHOOK_PRE, Detour_ItemBox_PlayerTakeItems))
    {
        LogError("Failed to detour PlayerTakeItems");
    }

    g_detour_ammobox_fall_init = DHookCreateFromConfOrFail(gameconf, "CItem_AmmoBox::FallInit");
    if (!DHookEnableDetour(g_detour_ammobox_fall_init, DHOOK_PRE, Detour_BaseItem_FallInit))
    {
        LogError("Failed to detour AmmoBox::FallInit");
    }
    if (!DHookEnableDetour(g_detour_ammobox_fall_init, DHOOK_POST, Detour_BaseItem_FallInitPost))
    {
        LogError("Failed to detour AmmoBox::FallInit post");
    }

    g_detour_ammobox_fall_think = DHookCreateFromConfOrFail(gameconf, "CItem_AmmoBox::FallThink");
    if (!DHookEnableDetour(g_detour_ammobox_fall_think, DHOOK_PRE, Detour_BaseItem_FallThink))
    {
        LogError("Failed to detour AmmoBox::FallThink");
    }
    if (!DHookEnableDetour(g_detour_ammobox_fall_think, DHOOK_POST, Detour_BaseItem_FallThinkPost))
    {
        LogError("Failed to detour AmmoBox::FallThink post");
    }

    g_detour_player_get_speed_factor = DHookCreateFromConfOrFail(gameconf, "CNMRiH_Player::GetWeightSpeedFactor");
    if (!DHookEnableDetour(g_detour_player_get_speed_factor, DHOOK_PRE, Detour_Player_GetWeightSpeedFactor))
    {
        LogError("Failed to detour CNMRiH_Player::GetWeightSpeedFactor");
    }
    if (!DHookEnableDetour(g_detour_player_get_speed_factor, DHOOK_POST, Detour_Player_GetWeightSpeedFactorPost))
    {
        LogError("Failed to detour CNMRiH_Player::GetWeightSpeedFactor post");
    }

    g_detour_flare_projectile_explode = DHookCreateFromConfOrFail(gameconf, "CNMRiHFlareProjectile::Explode");
    if (!DHookEnableDetour(g_detour_flare_projectile_explode, DHOOK_PRE, Detour_FlareProjectile_Explode))
    {
        LogError("Failed to detour CNMRiHFlareProjectile::Explode");
    }

    g_dhook_weaponbase_fall_init = DHookCreateFromConfOrFail(gameconf, "CBaseCombatWeapon::FallInit");
    g_dhook_weaponbase_fall_think = DHookCreateFromConfOrFail(gameconf, "CBaseCombatWeapon::FallThink");

    LoadPluginGamedataSDKCalls(gameconf);

    CloseHandle(gameconf);
}

/**
 * Retrieve handles to SDK calls.
 */
void LoadPluginGamedataSDKCalls(Handle gameconf)
{
    int offset;

    offset = GameConfGetOffsetOrFail(gameconf, "CItem_AmmoBox::SetAmmoType");
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetVirtual(offset);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    g_sdkcall_ammobox_set_ammo_type = EndPrepSDKCall();

    offset = GameConfGetOffsetOrFail(gameconf, "CItem_AmmoBox::SetAmmoCount");
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetVirtual(offset);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    g_sdkcall_ammobox_set_ammo_count = EndPrepSDKCall();

    offset = GameConfGetOffsetOrFail(gameconf, "CItem_AmmoBox::GetMaxAmmo");
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetVirtual(offset);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_sdkcall_ammobox_get_max_ammo = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Entity);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CItem_InventoryBox::AddItem");
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);  // weapon name
    g_sdkcall_itembox_add_item = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Entity);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CBaseEntity::SetCollisionGroup");
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);  // int, collision group
    g_sdkcall_baseentity_set_collision_group = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Entity);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CItem_InventoryBox::EndUseForPlayer");
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    g_sdkcall_itembox_end_use_for_player = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Entity);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CItem_InventoryBox::EndUseForAllPlayers");
    g_sdkcall_itembox_end_use_for_all_players = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Entity);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CBaseCombatCharacter::Weapon_OwnsThisType");
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);          // char *, pszWeapon
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);      // int, iSubType
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);    // CBaseCombatWeapon*
    g_sdkcall_player_owns_weapon_type = EndPrepSDKCall();

    StartPrepSDKCall(SDKCall_Player);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CNMRiH_Player::GetAmmoCarryWeight");
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_sdkcall_player_get_ammo_weight = EndPrepSDKCall();

    offset = GameConfGetOffsetOrFail(gameconf, "CBaseEntity::IsBaseCombatWeapon");
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetVirtual(offset);
    PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
    g_sdkcall_entity_is_combat_weapon = EndPrepSDKCall();

    offset = GameConfGetOffsetOrFail(gameconf, "CBaseCombatWeapon::GetWeight");
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetVirtual(offset);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_sdkcall_weapon_get_weight = EndPrepSDKCall();
}

/**
 * Create admin commands and add them to admin menu.
 */
void SetupAdminCommands()
{
    RegAdminCmd("sm_backpack", Command_Backpack, ADMFLAG_BACKPACK, "sm_backpack");
    RegAdminCmd("sm_createbackpack", Command_CreateBackpack, ADMFLAG_BACKPACK, "sm_createbackpack [#userid|name] [backpack_type]");
    RegAdminCmd("sm_removebackpack", Command_RemoveBackpack, ADMFLAG_BACKPACK, "sm_removebackpack [#userid|name]");
    RegAdminCmd("sm_bringbackpack", Command_BringBackpack, ADMFLAG_BACKPACK, "sm_bringbackpack [#userid|name]");

    // Handle late loading.
    TopMenu top_menu;
    if (LibraryExists("adminmenu") &&
        ((top_menu = GetAdminTopMenu()) != null))
    {
        OnAdminMenuReady(top_menu);
    }
}

/**
 * Add Backpack category to admin menu.
 */
public void OnAdminMenuReady(Handle menu_handle)
{
    TopMenu top_menu = TopMenu.FromHandle(menu_handle);
    if (top_menu != g_admin_menu)
    {
        g_admin_menu = top_menu;

        // Create a category for backpack commands.
        g_backpack_commands = g_admin_menu.AddCategory(ADMINMENU_BACKPACKCOMMANDS,
            AdminMenu_Backpack, ADMINMENU_BACKPACKCOMMANDS, ADMFLAG_BACKPACK,
            ADMINMENU_BACKPACKCOMMANDS);

        if (g_backpack_commands != INVALID_TOPMENUOBJECT)
        {
            g_admin_menu.AddItem("sm_createbackpack", AdminMenu_CreateBackpack, g_backpack_commands, "sm_createbackpack", ADMFLAG_BACKPACK);
            g_admin_menu.AddItem("sm_removebackpack", AdminMenu_RemoveBackpack, g_backpack_commands, "sm_removebackpack", ADMFLAG_BACKPACK);
            g_admin_menu.AddItem("sm_bringbackpack", AdminMenu_BringBackpack, g_backpack_commands, "sm_bringbackpack", ADMFLAG_BACKPACK);
        }
    }
}

/**
 * Open Backpack Commands admin menu.
 */
public Action Command_Backpack(int client, int args)
{
    if (g_admin_menu && g_backpack_commands != INVALID_TOPMENUOBJECT)
    {
        g_admin_menu.DisplayCategory(g_backpack_commands, client);
    }
}

/**
 * Creates a menu that lists all the backpack types that can be created.
 */
void DisplayCreateBackpackMenu(int client)
{
    Menu menu = new Menu(Menu_CreateBackpack);
    if (menu)
    {
        menu.SetTitle("%T", "@backpack-menu-create", client);

        char backpack_type_name[CLASSNAME_MAX];

        // Find all backpacks that aren't worn by players.
        int backpack_types = g_backpack_types.Length;
        for (int i = 0; i < backpack_types; ++i)
        {
            g_backpack_type_names.GetString(i, backpack_type_name, sizeof(backpack_type_name));
            menu.AddItem(backpack_type_name, backpack_type_name);
        }

        if (menu.ItemCount > 0)
        {
            menu.Display(client, MENU_TIME_FOREVER);
        }
        else
        {
            // No backpack types exist. We should never reach this.
            LogError("No backpack types defined!");
            delete menu;
        }
    }
}

/**
 * Bring Backpack menu handler.
 *
 * Inspects the chosen menu item to determine whether a player or unworn
 * backpack was selected.
 */
public int Menu_CreateBackpack(Menu menu, MenuAction action, int param1, int param2)
{
    int result = 0;

    switch (action)
    {
    case MenuAction_Select:
        {
            int client = param1;
            char info[CLASSNAME_MAX];
            if (menu.GetItem(param2, info, sizeof(info)))
            {
                int backpack_type = g_backpack_type_names.FindString(info);
                if (backpack_type != -1)
                {
                    TraceAndCreateBackpack(client, backpack_type);
                }
                else
                {
                    ReplyToCommand(client, "[Backpack] %T", "@backpack-unknown-backpack-type", client, info);
                }
            }

            if (IsClientInGame(client) && !IsClientInKickQueue(client))
            {
                DisplayCreateBackpackMenu(client);
            }
        }

    case MenuAction_End:
        delete menu;
    }

    return result;
}

/**
 * Handle /createbackpack command and its arguments. (Which players to spawn the backpack for.)
 */
public Action Command_CreateBackpack(int client, int args)
{
    if (args < 1)
    {
        if (client == 0)
        {
            ReplyToCommand(client, "[Backpack] %T", "@backpack-cannot-execute-as-server", client);
        }
        else if (g_backpack_types.Length == 1)
        {
            if (TraceAndCreateBackpack(client, 0) != -1)
            {
                ReplyToCommand(client, "[Backpack] %T", "@backpack-create-notifier", client);
            }
            else
            {
                ReplyToCommand(client, "[Backpack] %T", "@backpack-create-failed-notifier", client);
            }
        }
        else
        {
            DisplayCreateBackpackMenu(client);
        }
    }
    else
    {
        char pattern[128];
        GetCmdArg(1, pattern, sizeof(pattern));

        char target_name[MAX_TARGET_LENGTH];
        bool target_name_is_phrase = false;

        int targets[MAXPLAYERS];
        int target_count = ProcessTargetString(
            pattern,
            client,
            targets,
            sizeof(targets),
            // Command only targets living players.
            COMMAND_FILTER_ALIVE,
            target_name,
            sizeof(target_name),
            target_name_is_phrase
        );

        if (target_count <= 0)
        {
            ReplyToTargetError(client, target_count);
        }
        else
        {
            bool randomize_backpack_type = true;
            int backpack_type = -1;
            if (args >= 2)
            {
                randomize_backpack_type = false;

                // Parse second argument as backpack type.
                char backpack_type_name[CLASSNAME_MAX];
                GetCmdArg(2, backpack_type_name, sizeof(backpack_type_name));
                backpack_type = g_backpack_type_names.FindString(backpack_type_name);

                if (backpack_type == -1)
                {
                    ReplyToCommand(client, "[Backpack] %T", "@backpack-unknown-backpack-type", client, backpack_type_name);
                }
            }

            if (randomize_backpack_type || (backpack_type >= 0 && backpack_type < g_backpack_types.Length))
            {
                for (int i = 0; i < target_count; ++i)
                {
                    if (randomize_backpack_type)
                    {
                        backpack_type = RandomBackpackType(targets[i]);
                    }

                    TraceAndCreateBackpack(targets[i], backpack_type);
                }

                if (target_name_is_phrase)
                {
                    ReplyToCommand(client, "[Backpack] %T", "@backpack-create-cmd-reply-t", client, target_name);
                }
                else
                {
                    ReplyToCommand(client, "[Backpack] %T", "@backpack-create-cmd-reply-s", client, target_name);
                }
            }
        }
    }

    return Plugin_Handled;
}

/**
 * Trace filter that sets the global \c g_player_and_backpack_trace_index
 * to the index into \c g_backpacks of the first backpack hit by the trace or -1.
 */
public bool Trace_PlayerAndBackpack(int entity, int contents_mask, int to_ignore)
{
    int index = -1;

    if (entity > MaxClients)
    {
        // Check if entity is a backpack.
        int entity_ref = EntIndexToEntRef(entity);
        index = g_backpacks.FindValue(entity_ref, BACKPACK_ITEM_BOX);
    }
    else if (entity > 0 && entity != to_ignore)
    {
        // Check if entity is a player wearing a backpack.
        int backpack_ref = g_player_backpacks[entity];
        if (EntRefToEntIndex(backpack_ref) != INVALID_ENT_REFERENCE)
        {
            index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
        }
    }

    g_player_and_backpack_trace_index = index;

    return true;
}

/**
 * Trace the specified client's view for a backpack or player wearing a
 * backpack and remove it.
 */
void TraceAndRemoveBackpack(int client)
{
    int hit = TracePlayerView(client, Trace_PlayerAndBackpack);
    int backpack_index = g_player_and_backpack_trace_index;

    if (backpack_index != -1)
    {
        if (hit > 0 && hit <= MaxClients)
        {
            ResetPlayer(hit);
        }

        RemoveBackpackByIndex(backpack_index);
        ReplyToCommand(client, "[Backpack] %T", "@backpack-remove-notifier", client);
    }
    else
    {
        ReplyToCommand(client, "[Backpack] %T", "@backpack-no-backpacks-found", client);
    }
}

/**
 * Kill the backpack and its oranment.
 */
void RemoveBackpackByIndex(int index)
{
    int backpack_ref = g_backpacks.Get(index, BACKPACK_ITEM_BOX);
    RemoveEntity(backpack_ref);

    int ornament_ref = g_backpacks.Get(index, BACKPACK_ORNAMENT);
    RemoveEntity(ornament_ref);

    RemoveArrayListElement(g_backpacks, index);
}

/**
 * Remove the backpack the player is looking at (including any being
 * worn by a client the player is looking at).
 */
public Action Command_RemoveBackpack(int client, int args)
{
    if (args < 1)
    {
        if (client == 0)
        {
            ReplyToCommand(client, "[Backpack] %T", "@backpack-cannot-execute-as-server", client);
        }
        else
        {
            // Remove the first backpack the player is looking at.
            TraceAndRemoveBackpack(client);
        }
    }
    else
    {
        char pattern[128];
        GetCmdArg(1, pattern, sizeof(pattern));

        char target_name[MAX_TARGET_LENGTH];
        bool target_name_is_phrase = false;

        int targets[MAXPLAYERS];
        int target_count = ProcessTargetString(
            pattern,
            client,
            targets,
            sizeof(targets),
            // Command only targets living players.
            COMMAND_FILTER_ALIVE,
            target_name,
            sizeof(target_name),
            target_name_is_phrase
        );

        if (target_count <= 0)
        {
            ReplyToTargetError(client, target_count);
        }
        else
        {
            // Remove backpacks worn by players targeted by command.
            for (int i = 0; i < target_count; ++i)
            {
                int target = targets[i];
                int backpack = EntRefToEntIndex(g_player_backpacks[target]);
                if (backpack != INVALID_ENT_REFERENCE)
                {
                    int backpack_index = g_backpacks.FindValue(g_player_backpacks[target], BACKPACK_ITEM_BOX);
                    if (backpack_index != -1)
                    {
                        ResetPlayer(target);
                        RemoveBackpackByIndex(backpack_index);
                        PrintToChat(target, "%T", "@backpack-destroyed-notifier", target);
                    }
                }
            }

            if (target_name_is_phrase)
            {
                ReplyToCommand(client, "[Backpack] %T", "@backpack-remove-cmd-reply-t", client, target_name);
            }
            else
            {
                ReplyToCommand(client, "[Backpack] %T", "@backpack-remove-cmd-reply-s", client, target_name);
            }
        }
    }

    return Plugin_Handled;
}

/**
 * Creates a menu that lists all the backpacks that are not being worn.
 */
void DisplayBringBackpackMenu(int client)
{
    Menu menu = new Menu(Menu_BringBackpack);
    if (menu)
    {
        menu.SetTitle("%T", "@backpack-menu-bring", client);

        static const int PLAYER = 1;
        static const int BACKPACK = 0;
        int worn_backpacks[MAXPLAYERS][2];
        int worn_backpack_count = 0;

        // Cache ent indices of backpacks worn by players.
        for (int i = 1; i <= MaxClients; ++i)
        {
            int backpack = EntRefToEntIndex(g_player_backpacks[i]);
            if (backpack != INVALID_ENT_REFERENCE)
            {
                worn_backpacks[worn_backpack_count][PLAYER] = i;
                worn_backpacks[worn_backpack_count][BACKPACK] = backpack;
                ++worn_backpack_count;
            }
        }

        char buffer[PLAYER_NAME_MAX];
        char menu_item_text[64];
        char menu_info[MENU_INFO_MAX];

        // Find all backpacks that aren't worn by players.
        int backpack_count = g_backpacks.Length;
        for (int i = 0; i < backpack_count; ++i)
        {
            int backpack_ref = g_backpacks.Get(i, BACKPACK_ITEM_BOX);
            int backpack = EntRefToEntIndex(backpack_ref);
            if (backpack != INVALID_ENT_REFERENCE)
            {
                int worn_by = 0;

                for (int j = 0; j < worn_backpack_count && !worn_by; ++j)
                {
                    if (backpack == worn_backpacks[j][BACKPACK])
                    {
                        worn_by = worn_backpacks[j][PLAYER];
                    }
                }

                if (worn_by != client)
                {
                    if (worn_by)
                    {
                        // Store client's user ID in menu info.
                        menu_info[0] = 'p'; // Prefix info with 'p' so we can distinguish it in selection.
                        IntToString(GetClientUserId(worn_by), menu_info[1], sizeof(menu_info) - 1);

                        // Show player's name.
                        GetClientName(worn_by, buffer, sizeof(buffer));
                        Format(menu_item_text, sizeof(menu_item_text), "%T", "@backpack-choice-player", client, buffer);
                    }
                    else
                    {
                        // Store backpack's ent reference in menu info.
                        IntToString(backpack_ref, menu_info, sizeof(menu_info));

                        // Show distance to backpack to help distinguish them.
                        int distance = RoundToNearest(GetEntDistance(client, backpack));
                        int len = Format(buffer, sizeof(buffer), "%14d - ", distance);

                        int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
                        if (backpack_index != -1)
                        {
                            int backpack_type = g_backpacks.Get(backpack_index, BACKPACK_TYPE);
                            g_backpack_type_names.GetString(backpack_type, buffer[len], sizeof(buffer) - len);
                        }

                        Format(menu_item_text, sizeof(menu_item_text), "%T", "@backpack-choice-distance", client, buffer);
                    }

                    menu.AddItem(menu_info, menu_item_text);
                }
            }
        }

        if (menu.ItemCount == 0)
        {
            ReplyToCommand(client, "[Backpack] %T", "@backpack-no-backpacks-found", client);
            delete menu;
        }
        else
        {
            menu.Display(client, MENU_TIME_FOREVER);
        }
    }
}

/**
 * Bring Backpack menu handler.
 *
 * Inspects the chosen menu item to determine whether a player or unworn
 * backpack was selected.
 */
public int Menu_BringBackpack(Menu menu, MenuAction action, int param1, int param2)
{
    int result = 0;

    switch (action)
    {
    case MenuAction_Select:
        {
            int client = param1;
            char info[MENU_INFO_MAX];
            if (menu.GetItem(param2, info, sizeof(info)))
            {
                int worn_by = 0;

                int backpack_ref = -1;
                if (info[0] == 'p')
                {
                    // Client selected a player. Check if player still exists.
                    int userid = StringToInt(info[1]);
                    int target = GetClientOfUserId(userid);

                    if (target != 0 && target != client)
                    {
                        backpack_ref = g_player_backpacks[target];
                        worn_by = target;
                    }
                    else
                    {
                        ReplyToCommand(client, "[Backpack] %T", "Player no longer available", client);
                    }
                }
                else
                {
                    // Client selected an unworn backpack.
                    backpack_ref = StringToInt(info);
                }

                int backpack = EntRefToEntIndex(backpack_ref);
                if (backpack != INVALID_ENT_REFERENCE)
                {
                    // Find out if it is being worn.
                    for (int i = 1; i <= MaxClients && !worn_by; ++i)
                    {
                        if (backpack == EntRefToEntIndex(g_player_backpacks[i]))
                        {
                            worn_by = i;
                        }
                    }

                    if (worn_by != client)
                    {
                        if (worn_by)
                        {
                            TakeBackpackFrom(worn_by, client);
                        }
                        else
                        {
                            TeleportBackpackToClient(client, backpack);
                        }
                    }
                }
            }

            if (IsClientInGame(client) && !IsClientInKickQueue(client))
            {
                DisplayBringBackpackMenu(client);
            }
        }

    case MenuAction_End:
        delete menu;
    }

    return result;
}

/**
 * Remove a player's backpack and teleport it to another player.
 */
void TakeBackpackFrom(int owner, int taker)
{
    if (DropBackpack(owner, taker))
    {
        PrintToChat(owner, "%T", "@backpack-taken-notifier", owner);
    }
}

/**
 * Create a menu that lists all backpacks that can be brought.
 */
public Action Command_BringBackpack(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[Backpack] %T", "@backpack-cannot-execute-as-server", client);
    }
    else if (args < 1)
    {
        // Show a menu of backpacks.
        DisplayBringBackpackMenu(client);
    }
    else
    {
        char pattern[128];
        GetCmdArg(1, pattern, sizeof(pattern));

        char target_name[MAX_TARGET_LENGTH];
        bool target_name_is_phrase = false;

        int targets[MAXPLAYERS];
        int target_count = ProcessTargetString(
            pattern,
            client,
            targets,
            sizeof(targets),
            // Command only targets living players.
            COMMAND_FILTER_ALIVE,
            target_name,
            sizeof(target_name),
            target_name_is_phrase
        );

        if (target_count <= 0)
        {
            ReplyToTargetError(client, target_count);
        }
        else
        {
            // Bring backpacks worn by players targeted by command.
            for (int i = 0; i < target_count; ++i)
            {
                int target = targets[i];
                int backpack = EntRefToEntIndex(g_player_backpacks[target]);
                if (client != target && backpack != INVALID_ENT_REFERENCE)
                {
                    int backpack_index = g_backpacks.FindValue(g_player_backpacks[target], BACKPACK_ITEM_BOX);
                    if (backpack_index != -1 && TeleportBackpackToClient(client, backpack))
                    {
                        TakeBackpackFrom(target, client);
                    }
                }
            }

            if (target_name_is_phrase)
            {
                ReplyToCommand(client, "[Backpack] %T", "@backpack-bring-cmd-reply-t", client, target_name);
            }
            else
            {
                ReplyToCommand(client, "[Backpack] %T", "@backpack-bring-cmd-reply-s", client, target_name);
            }
        }
    }

    return Plugin_Handled;
}

/**
 * Backpack admin menu category callback.
 */
public void AdminMenu_Backpack(TopMenu topmenu,
    TopMenuAction action,
    TopMenuObject object_id,
    int client,
    char[] buffer,
    int maxlength)
{
    if (action == TopMenuAction_DisplayOption ||
        action == TopMenuAction_DisplayTitle)
    {
        Format(buffer, maxlength, "%T", "@backpack-menu-title", client);
    }
}

/**
 * Create Backpack admin menu callback.
 */
public void AdminMenu_CreateBackpack(TopMenu topmenu,
    TopMenuAction action,
    TopMenuObject object_id,
    int client,
    char[] buffer,
    int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlength, "%T", "@backpack-menu-create", client);
    }
    else if (action == TopMenuAction_SelectOption)
    {
        if (g_backpack_types.Length == 1)
        {
            Command_CreateBackpack(client, 0);
        }
        else
        {
            DisplayCreateBackpackMenu(client);
        }
    }
}

/**
 * Remove Backpack admin menu callback.
 */
public void AdminMenu_RemoveBackpack(TopMenu topmenu,
    TopMenuAction action,
    TopMenuObject object_id,
    int client,
    char[] buffer,
    int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlength, "%T", "@backpack-menu-remove", client);
    }
    else if (action == TopMenuAction_SelectOption)
    {
        Command_RemoveBackpack(client, 0);
    }
}

/**
 * Bring Backpack admin menu callback.
 */
public void AdminMenu_BringBackpack(TopMenu topmenu,
    TopMenuAction action,
    TopMenuObject object_id,
    int client,
    char[] buffer,
    int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlength, "%T", "@backpack-menu-bring", client);
    }
    else if (action == TopMenuAction_SelectOption)
    {
        Command_BringBackpack(client, 0);
    }
}

public void OnPluginEnd()
{
    if (!DHookDisableDetour(g_detour_baseentity_start_fade_out, DHOOK_PRE, Detour_BaseEntity_StartFadeOut))
    {
        LogError("Failed to remove detour SUB_StartFadeOut");
    }

    if (!DHookDisableDetour(g_detour_itembox_player_take_items, DHOOK_PRE, Detour_ItemBox_PlayerTakeItems))
    {
        LogError("Failed to remove detour PlayerTakeItems");
    }

    if (!DHookDisableDetour(g_detour_ammobox_fall_init, DHOOK_POST, Detour_BaseItem_FallInitPost))
    {
        LogError("Failed to detour AmmoBox::FallInit post");
    }
    if (!DHookDisableDetour(g_detour_ammobox_fall_init, DHOOK_PRE, Detour_BaseItem_FallInit))
    {
        LogError("Failed to remove detour AmmoBox::FallInit");
    }

    if (!DHookDisableDetour(g_detour_ammobox_fall_think, DHOOK_POST, Detour_BaseItem_FallThinkPost))
    {
        LogError("Failed to remove detour AmmoBox::FallThink post");
    }
    if (!DHookDisableDetour(g_detour_ammobox_fall_think, DHOOK_PRE, Detour_BaseItem_FallThink))
    {
        LogError("Failed to remove detour AmmoBox::FallThink");
    }

    if (!DHookDisableDetour(g_detour_player_get_speed_factor, DHOOK_POST, Detour_Player_GetWeightSpeedFactorPost))
    {
        LogError("Failed to remove detour CNMRiH_Player::GetWeightSpeedFactor post");
    }
    if (!DHookDisableDetour(g_detour_player_get_speed_factor, DHOOK_PRE, Detour_Player_GetWeightSpeedFactor))
    {
        LogError("Failed to remove detour CNMRiH_Player::GetWeightSpeedFactor");
    }
}

public void OnMapStart()
{
    char model[PLATFORM_MAX_PATH];

    int backpack_types = g_backpack_types.Length;
    for (int i = 0; i < backpack_types; ++i)
    {
        g_backpack_type_itembox_models.GetString(i, model, sizeof(model));
        PrecacheModel2(model);

        g_backpack_type_ornament_models.GetString(i, model, sizeof(model));
        PrecacheModel2(model);

        int tuple[BACKPACK_TYPE_TUPLE_SIZE];
        g_backpack_types.GetArray(i, tuple);

        PrecacheSoundList(TupleGetArrayList(tuple, BACKPACK_TYPE_OPEN_SOUNDS));
        PrecacheSoundList(TupleGetArrayList(tuple, BACKPACK_TYPE_DROP_SOUNDS));
        PrecacheSoundList(TupleGetArrayList(tuple, BACKPACK_TYPE_WEAR_SOUNDS));
        PrecacheSoundList(TupleGetArrayList(tuple, BACKPACK_TYPE_ADD_SOUNDS));
    }

    ResetPlugin();
}

/**
 * Hook newly spawned entities.
 */
public void OnEntityCreated(int entity, const char[] classname)
{
    HandleNewEntity(entity, true);
}

/**
 *
 */
void HandleNewEntity(int entity, bool spawning)
{
    if (IsValidEntity(entity))
    {
        if (spawning)
        {
            SDKHook(entity, SDKHook_SpawnPost, Hook_DHookWeaponFall);
        }
        else
        {
            Hook_DHookWeaponFall(entity);
        }
    }
}

/**
 * Hook weapon's fall think.
 */
public void Hook_DHookWeaponFall(int entity)
{
    if (SDKCall(g_sdkcall_entity_is_combat_weapon, entity))
    {
        DHookEntity(g_dhook_weaponbase_fall_init, DHOOK_POST, entity, .callback = DHook_WeaponBase_FallInitPost);
        DHookEntity(g_dhook_weaponbase_fall_think, DHOOK_POST, entity, .callback = DHook_WeaponBase_FallThinkPost);
    }
}

int PrecacheModel2(const char[] model_path)
{
    int index = PrecacheModel(model_path, true);
    if (index == 0)
    {
        LogMessage("Warning: Could not precache model '%s'", model_path);
    }
    return index;
}

/**
 * Precache a list of sounds.
 *
 * Assumes each entry has a layer count encoded in the first element.
 */
void PrecacheSoundList(ArrayList sounds)
{
    char sound[PLATFORM_MAX_PATH];

    int sound_count = sounds.Length;
    for (int i = 0; i < sound_count; ++i)
    {
        sounds.GetString(i, sound, sizeof(sound));
        if (!PrecacheSound(sound[1], true))
        {
            LogMessage("Warning: Could not precache sound '%s'", sound[1]);
        }
    }
}

/**
 * Trace for backpack drop location.
 */
public bool Trace_BackpackDrop(int entity, int contents_mask)
{
    return entity == 0 || entity > MaxClients;
}

/**
 * Hull sweep in direction of player's camera for backpack drop/spawn
 * location.
 */
bool TraceBackpackPosition(int client, float pos[3], float angles[3])
{
    static const float DROP_DISTANCE = 48.0;

    float origin[3];
    GetClientEyePosition(client, origin);

    GetClientEyeAngles(client, angles);

    float direction[3];
    GetAngleVectors(angles, direction, NULL_VECTOR, NULL_VECTOR);
    ScaleVector(direction, DROP_DISTANCE);

    AddVectors(origin, direction, pos);

    float bounds_min[3] = { -10.0, ... };
    float bounds_max[3] = { 10.0, ... };

    TR_TraceHullFilter(origin, pos, bounds_min, bounds_max, MASK_SOLID, Trace_BackpackDrop);
    float fraction = TR_GetFraction();

    ScaleVector(direction, fraction);
    AddVectors(origin, direction, pos);

    // Restrict backpack's rotation to yaw.
    angles[X] = 0.0;
    angles[Z] = 0.0;

    // Put glowsticks towards dropper.
    angles[Y] += 180.0;

    return !TR_PointOutsideWorld(pos);
}

/**
 * Detatch backpack ornament from a player.
 *
 * @param backpack_index        Index of backpack in \c g_backpacks
 */
void DetachBackpack(int backpack_index)
{
    // Detach the backpack ornament.
    int ornament = EntRefToEntIndex(g_backpacks.Get(backpack_index, BACKPACK_ORNAMENT));
    if (ornament != INVALID_ENT_REFERENCE)
    {
        AcceptEntityInput(ornament, "Detach");
        AcceptEntityInput(ornament, "ClearParent");
    }
}

/**
 * Teleport the backpack somewhere in front of the client.
 *
 * This function assumes that the backpack isn't worn by anybody.
 *
 * @param client                Client to use as destination point.
 * @param backpack              Ent index of backpack.
 */
bool TeleportBackpackToClient(int client, int backpack)
{
    bool teleported = false;

    // Hull sweep in direction of player's camera for backpack
    // drop location.
    float pos[3];
    float angles[3];
    if (TraceBackpackPosition(client, pos, angles))
    {
        TeleportEntity(backpack, pos, angles, NULL_VECTOR);
        AcceptEntityInput(backpack, "EnableMotion");
        SDKCall(g_sdkcall_baseentity_set_collision_group, backpack, COLLISION_GROUP_DEBRIS);

        teleported = true;
    }
    else
    {
        ReplyToCommand(client, "[Backpack] %T", "@backpack-invalid-position", client);
    }

    return teleported;
}

/**
 * Remove the player's backpack and plays a sound.
 *
 * The backpack is dropped towards the target's look direction.
 *
 * @param owner     Player whose backpack will be dropped.
 * @param target    Player whose position/look will be used.
 */
bool DropBackpack(int owner, int target = 0)
{
    bool dropped = false;

    if (target <= 0)
    {
        target = owner;
    }

    int backpack_index = g_backpacks.FindValue(g_player_backpacks[owner], BACKPACK_ITEM_BOX);
    int backpack = EntRefToEntIndex(g_player_backpacks[owner]);

    if (backpack_index != -1 &&
        backpack != INVALID_ENT_REFERENCE &&
        TeleportBackpackToClient(target, backpack))
    {
        // Remove the ornament.
        DetachBackpack(backpack_index);

        // Play backpack unequip sound.
        static int previous[SHUFFLE_SOUND_COUNT] = { -1, ... };
        PlayBackpackSound(owner, backpack_index, BACKPACK_TYPE_DROP_SOUNDS, previous);

        // Start glowing backpack again.
        if (g_cvar_backpack_glow.BoolValue)
            RequestFrame(Frame_EnableGlow, EntIndexToEntRef(backpack));

        ResetPlayer(owner);

        dropped = true;
    }

    return dropped;
}


/**
 * Play sound appropriate for backpack type.
 *
 * @param source                Entity that is emitting the sound.
 * @param backpack_index        Index of backpack in g_backpacks.
 * @param sound_type            Index into backpack type tuple for sound ArrayList.
 * @param previous              Index of previous sound in ArrayList that was played.
 */
void PlayBackpackSound(int source, int backpack_index, eBackpackTypeTuple sound_type, int previous[SHUFFLE_SOUND_COUNT])
{
    if (backpack_index < 0 ||
        backpack_index >= g_backpacks.Length ||
        sound_type < BACKPACK_TYPE_OPEN_SOUNDS ||
        sound_type > BACKPACK_TYPE_ADD_SOUNDS)
    {
        return;
    }

    int backpack_type = g_backpacks.Get(backpack_index, BACKPACK_TYPE);
    if (backpack_type >= 0 && backpack_type < g_backpack_types.Length)
    {
        ArrayList sounds = view_as<ArrayList>(g_backpack_types.Get(backpack_type, sound_type));

        int sound_count = sounds ? sounds.Length : 0;
        if (sound_count > 0)
        {
            int index = ShuffleSoundIndex(sound_count, previous);

            char sound[PLATFORM_MAX_PATH];
            sounds.GetString(index, sound, sizeof(sound));
            int layers = sound[0];

            for (int i = 0; i < layers; ++i)
            {
                EmitSoundToAll(sound[1], source);
            }
        }
    }
}

/**
 * Mark player as not wearing a backpack.
 */
void ResetPlayer(int client)
{
    g_player_backpacks[client] = -1;
}

/**
 * Hook player's weapon switch and death.
 */
public void OnClientPostAdminCheck(int client)
{
    ResetPlayer(client);

    SDKHook(client, SDKHook_WeaponSwitch, Hook_PlayerWeaponSwitch);

    // Forcibly call WeaponSwitch for current weapon.
    int active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    Hook_PlayerWeaponSwitch(IGNORE_CURRENT_WEAPON | client, active_weapon);
}

/**
 * Drop backpack when a player disconnects.
 */
public void OnClientDisconnect(int client)
{
    DropBackpack(client);
}

/**
 * Create backpack for late-connecting players.
 */
public void Event_PlayerSpawn(Event event, const char[] name, bool no_broadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    if (client != 0 && NMRiH_IsPlayerAlive(client))
    {
        if (g_round_state == ROUND_STATE_RESTARTING)
        {
            // Wait a frame and then randomly spawn backpacks for existing players.
            RequestFrame(OnFrame_SpawnBackpacks, 0);
            g_round_state = ROUND_STATE_WAITING;
        }
        else if (g_round_state == ROUND_STATE_STARTED &&
            g_backpacks.Length < g_cvar_backpack_count.IntValue &&
            EntRefToEntIndex(g_player_backpacks[client]) == INVALID_ENT_REFERENCE &&
            CanPlayerWearBackpack(client) &&
            CanPlayerOpenBackpack(client))
        {
            // Spawn backpacks for new players.
            int backpack = CreateBackpack(ZERO_VEC, ZERO_VEC, RandomBackpackType(client));
            PickupBackpack(client, backpack);
            PrintToChat(client, "%T", "@backpack-spawn-notifier", client);
        }
    }
}

/**
 * Fisher-Yates shuffle.
 */
void ShuffleArray(int[] values, int elements)
{
    for (int i = elements - 1; i > 0; --i)
    {
        int j = GetURandomInt() % (i + 1);
        int swap = values[i];
        values[i] = values[j];
        values[j] = swap;
    }
}

/**
 * Spawn backpacks randomly amongst players.
 */
public void OnFrame_SpawnBackpacks(int unused)
{
    int players[MAXPLAYERS];
    int player_count = 0;

    for (int i = 1; i <= MaxClients; ++i)
    {
        if (EntRefToEntIndex(g_player_backpacks[i]) == INVALID_ENT_REFERENCE &&
            NMRiH_IsPlayerAlive(i) &&
            CanPlayerWearBackpack(i) &&
            CanPlayerOpenBackpack(i))
        {
            players[player_count] = i;
            ++player_count;
        }
    }

    ShuffleArray(players, player_count);

    int backpack_count = g_cvar_backpack_count.IntValue - g_backpacks.Length;
    for (int i = 0; i < backpack_count && i < player_count; ++i)
    {
        int client = players[i];

        int backpack = CreateBackpack(ZERO_VEC, ZERO_VEC, RandomBackpackType(client));
        if (backpack != -1)
        {
            PickupBackpack(client, backpack);
            PrintToChat(client, "%T", "@backpack-spawn-notifier", client);
        }
        else
        {
            // Increment backpack counter to ignore failed backpack spawn.
            ++backpack_count;
        }
    }

    g_round_state = ROUND_STATE_STARTED;
}

/**
 * Drop backpack when player dies.
 */
public void Event_PlayerDeath(Event event, const char[] name, bool no_broadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client != 0)
    {
        DropBackpack(client);
    }
}

/**
 * Remove backpack when player extracts.
 */
public void Event_PlayerExtracted(Event event, const char[] name, bool no_broadcast)
{
    int client = event.GetInt("player_id");
    if (client > 0 && client <= MaxClients)
    {
        int backpack_ref = g_player_backpacks[client];
        if (EntRefToEntIndex(backpack_ref) != INVALID_ENT_REFERENCE)
        {
            int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
            if (backpack_index != -1)
            {
                ResetPlayer(client);
                RemoveBackpackByIndex(backpack_index);
            }
        }
    }
}

/**
 * Clear existing backpacks.
 */
void ResetPlugin()
{
    g_round_state = ROUND_STATE_RESTARTING;
    g_next_backpack_hue = GetURandomInt() % 256;

    g_backpacks.Clear();
    g_backpack_clips.Clear();
    g_backpack_gear_clips.Clear();
    g_backpack_ammos.Clear();

    for (int i = 0; i <= MaxClients; ++i)
    {
        ResetPlayer(i);
    }
}

/**
 * This event is called just prior to a round reset.
 */
public void Event_GameRestarting(Event event, const char[] name, bool no_broadcast)
{
    ResetPlugin();
}

/**
 * Remember whether a player has their fists equipped.
 *
 * @param client        Client that switched weapons.
 * @param weapon        Edict of weapon the player switched to.
 */
public Action Hook_PlayerWeaponSwitch(int client, int weapon)
{
    bool ignore_current_weapon = (client & IGNORE_CURRENT_WEAPON) != 0;
    client &= ~IGNORE_CURRENT_WEAPON;

    int active_weapon = GetClientActiveWeapon(client);
    if (IsValidEdict(weapon) && (ignore_current_weapon || weapon != active_weapon))
    {
        g_player_fists_equipped[client] = false;

        char weapon_name[CLASSNAME_MAX];
        if (IsClassnameEqual(weapon, weapon_name, sizeof(weapon_name), ME_FISTS))
        {
            g_player_fists_equipped[client] = true;
        }
    }

    return Plugin_Continue;
}

/**
 * Select a random backpack according to the player's permissions.
 */
int RandomBackpackType(int client)
{
    int backpack_type = -1;

    int backpack_types = g_backpack_types.Length;
    if (backpack_types > 0)
    {
        float non_admin_total_weight = 0.0;
        float admin_only_total_weight = 0.0;

        // Dynamically normalize backpack weights because cvars can affect the
        // weighting.
        for (int i = 0; i < backpack_types; ++i)
        {
            float weight = view_as<float>(g_backpack_types.Get(i, BACKPACK_TYPE_WEIGHT));
            if (weight > 0.0)
            {
                if (IsBackpackTypeAdminOnly(i))
                {
                    admin_only_total_weight += weight;
                }
                else
                {
                    non_admin_total_weight += weight;
                }
            }
        }

        // Only pick from admin-only backpacks if they exist
        bool pick_admin = IsClientAdmin(client) && admin_only_total_weight > 0.0;

        float total_weight = pick_admin ? admin_only_total_weight : non_admin_total_weight;
        if (total_weight <= 0.0)
        {
            total_weight = 1.0;
        }

        float roll = GetURandomFloat() * 100.0;
        for (int i = 0; i < backpack_types && backpack_type == -1; ++i)
        {
            if (pick_admin != IsBackpackTypeAdminOnly(i))
            {
                continue;
            }

            float weight = view_as<float>(g_backpack_types.Get(i, BACKPACK_TYPE_WEIGHT));
            float chance = weight / total_weight * 100.0;
            if (chance > 0.0)
            {
                if (roll < chance)
                {
                    backpack_type = i;
                }
                else
                {
                    roll -= chance;
                }
            }
        }
    }

    return backpack_type;
}

/**
 * Return true if the backpack type identified by index is only wearable
 * or openable by admins.
 */
bool IsBackpackTypeAdminOnly(int backpack_type)
{
    bool admin_backpack = false;

    if (backpack_type >= 0 && backpack_type < g_backpack_types.Length)
    {
        bool admin_cvar = g_cvar_backpack_only_admins_can_wear.BoolValue ||
            g_cvar_backpack_only_admins_can_open.BoolValue;

        eCvarFlag only_admins_wear = g_backpack_types.Get(backpack_type, BACKPACK_TYPE_ONLY_ADMINS_WEAR);
        eCvarFlag only_admins_open = g_backpack_types.Get(backpack_type, BACKPACK_TYPE_ONLY_ADMINS_OPEN);

        admin_backpack = only_admins_wear == CVAR_FLAG_YES ||
            only_admins_open == CVAR_FLAG_YES ||
            ((only_admins_wear == CVAR_FLAG_DEFAULT || only_admins_open == CVAR_FLAG_DEFAULT) && admin_cvar);
    }

    return admin_backpack;
}

int GetURandomIntInRange(int lo, int hi)
{
    if (hi < lo)
    {
        int swap = hi;
        hi = lo;
        lo = swap;
    }
    int mod = (hi + 1) - lo;
    return mod == 0 ? lo : GetURandomInt() % mod + lo;
}

int GetURandomIntInRangeWithSteps(int lo, int hi, int steps)
{
    if (hi < lo)
    {
        int swap = hi;
        hi = lo;
        lo = swap;
    }

    int diff = (hi + 1) - lo;

    return diff == 0 || steps <= 0 ? lo : lo + GetURandomIntInRange(0, steps) * (diff / steps);
}

void RandomBackpackColor(int color[3])
{
    int hsv[3];

    int hue = g_next_backpack_hue;

    // Try to skip green region (so backpack looks different from normal fema bag)
    static const int green_start = 20;
    static const int green_end = 60;
    if (hue >= green_start && hue <= green_end)
    {
        hue += green_end + (hue - green_start);
        hue %= 256;
    }

    g_next_backpack_hue = (hue + GetURandomIntInRange(30, 60)) % 256;

    hsv[HSV_H] = hue;
    hsv[HSV_S] = GetURandomIntInRange(84, 185);
    hsv[HSV_V] = GetURandomIntInRangeWithSteps(125, 175, 5);

    HsvToRgb(hsv, color);
}

/**
 * Implementation ripped from https://stackoverflow.com/a/6930407
 */
void HsvToRgb(int hsv[3], int rgb[3])
{
    if (hsv[HSV_S] <= 0)
    {
        for (int i = 0; i < 3; ++i)
        {
            rgb[i] = hsv[HSV_V];
        }
    }
    else
    {
        float hh = float(hsv[HSV_H]) * (360.0 / 0xFF);
        if (hh >= 360.0)
        {
            hh = 0.0;
        }
        hh /= 60.0;

        // Normalize value and saturation to [0.0 - 1.0]
        float vv = float(hsv[HSV_V]) / 0xFF;
        float ss = float(hsv[HSV_S]) / 0xFF;

        int i = RoundToNearest(hh);
        float ff = hh - float(i);

        int p = RoundToNearest((vv * (1.0 - ss)) * 255.0);
        int q = RoundToNearest((vv * (1.0 - (ss * ff))) * 255.0);
        int t = RoundToNearest((vv * (1.0 - (ss * (1.0 - ff)))) * 255.0);
        int v = hsv[HSV_V];

        if (i == 0)
        {
            rgb[R] = v;
            rgb[G] = t;
            rgb[B] = p;
        }
        else if (i == 1)
        {
            rgb[R] = q;
            rgb[G] = v;
            rgb[B] = p;
        }
        else if (i == 2)
        {
            rgb[R] = p;
            rgb[G] = v;
            rgb[B] = t;
        }
        else if (i == 3)
        {
            rgb[R] = p;
            rgb[G] = q;
            rgb[B] = v;
        }
        else if (i == 4)
        {
            rgb[R] = t;
            rgb[G] = p;
            rgb[B] = v;
        }
        else
        {
            rgb[R] = v;
            rgb[G] = p;
            rgb[B] = q;
        }
    }
}

/**
 * Tell Supply Chances plugin to ignore backpacks.
 */
public Action OnSupplyChancesModifyBox(int box)
{
    int box_ref = EntIndexToEntRef(box);
    bool is_backpack = g_backpacks.FindValue(box_ref, BACKPACK_ITEM_BOX) != -1;
    return is_backpack ? Plugin_Stop : Plugin_Continue;
}

/**
 * Create a backpack that players can pick up by punching.
 */
int CreateBackpack(const float pos[3], const float angles[3], int backpack_type)
{
    if (backpack_type < 0 || backpack_type >= g_backpack_types.Length)
    {
        return -1;
    }

    int backpack = CreateEntityByName("item_inventory_box");
    int ornament = CreateEntityByName("prop_dynamic_ornament");

    if (backpack != -1 && ornament != -1)
    {
        int tuple[BACKPACK_TUPLE_SIZE];
        tuple[BACKPACK_ITEM_BOX] = EntIndexToEntRef(backpack);
        tuple[BACKPACK_ORNAMENT] = EntIndexToEntRef(ornament);
        tuple[BACKPACK_TYPE] = backpack_type;
        g_backpacks.PushArray(tuple);

        char targetname[32];
        Format(targetname, sizeof(targetname), "%s-%d",
            BACKPACK_ITEMBOX_TARGETNAME, backpack);

        char model[PLATFORM_MAX_PATH];

        // Setup item box to use custom model.
        g_backpack_type_itembox_models.GetString(backpack_type, model, sizeof(model));
        DispatchKeyValue(backpack, "targetname", targetname);
        DispatchKeyValueVector(backpack, "origin", pos);
        DispatchKeyValueVector(backpack, "angles", angles);
        DispatchKeyValue(backpack, "model", model);
        DispatchSpawn(backpack);

        // Setup ornament to use custom model.
        g_backpack_type_ornament_models.GetString(backpack_type, model, sizeof(model));
        DispatchKeyValueVector(ornament, "origin", pos);
        DispatchKeyValue(ornament, "model", model);
        DispatchKeyValue(ornament, "disableshadows", "1");
        DispatchSpawn(ornament);


        int color[3] = { 0, 255, 0 };

        eCvarFlag colorize = g_backpack_types.Get(backpack_type, BACKPACK_TYPE_COLORIZE);
        if (colorize == CVAR_FLAG_YES || (colorize == CVAR_FLAG_DEFAULT && g_cvar_backpack_colorize.BoolValue))
        {
            RandomBackpackColor(color);

            SetEntityRenderMode(backpack, RENDER_TRANSCOLOR);
            SetEntityRenderColor(backpack, color[0], color[1], color[2], 0xFF);

            SetEntityRenderMode(ornament, RENDER_TRANSCOLOR);
            SetEntityRenderColor(ornament, color[0], color[1], color[2], 0xFF);
        }

        // Set backpack to glow on demand.
        Format(model, sizeof(model), "%d %d %d", color[0], color[1], color[2]);
        DispatchKeyValue(backpack, "glowable", "1");
        DispatchKeyValueFloat(backpack, "glowdistance", g_cvar_backpack_glow_dist.FloatValue); 
        DispatchKeyValue(backpack, "glowcolor", model);

        if (g_cvar_backpack_glow_blip.BoolValue)
            DispatchKeyValue(backpack, "glowblip", "1"); 

        if (g_cvar_backpack_glow.BoolValue)
            RequestFrame(Frame_EnableGlow, EntIndexToEntRef(backpack));

        SDKCall(g_sdkcall_baseentity_set_collision_group, backpack, COLLISION_GROUP_DEBRIS);

        int ammos[ITEMBOX_MAX_SLOTS] = { 0, ... };
        g_backpack_clips.PushArray(ammos);
        g_backpack_gear_clips.PushArray(ammos); // Intentional truncation.
        g_backpack_ammos.PushArray(ammos);

        // Make backpack a trigger that detects debris (weapons & ammo).
        int solid_flags = GetEntProp(backpack, Prop_Send, "m_usSolidFlags");
        solid_flags |= FSOLID_TRIGGER | FSOLID_TRIGGER_TOUCH_DEBRIS;
        SetEntProp(backpack, Prop_Send, "m_usSolidFlags", solid_flags);

        SDKHook(backpack, SDKHook_Use, Hook_BackpackUse);
        SDKHook(backpack, SDKHook_StartTouch, Hook_BackpackStartTouch);
        SDKHook(backpack, SDKHook_OnTakeDamage, Hook_BackpackPickup);

        // Increment item count once to prevent box removing itself when empty.
        int item_count = GetEntData(backpack, g_offset_itembox_item_count, SIZEOF_INT);
        SetEntData(backpack, g_offset_itembox_item_count, item_count + 1, SIZEOF_INT);

        // Clear the inventory box of initial loot.
        InventoryBox_Clear(backpack);
    }

    return backpack;
}

void Frame_EnableGlow(int backpack_ref)
{
    int backpack = EntRefToEntIndex(backpack_ref);
    if (backpack != -1)
        AcceptEntityInput(backpack, "EnableGlow", backpack, backpack);
}

void Frame_DisableGlow(int backpack_ref)
{
    int backpack = EntRefToEntIndex(backpack_ref);
    if (backpack != -1)
        AcceptEntityInput(backpack, "DisableGlow", backpack, backpack);
}

void InventoryBox_Clear(int box)
{
    for (int i; i < ITEMBOX_TOTAL_SLOTS; i++)
        SetEntData(box, g_offset_itembox_weapon_array + i * 4, 0);
}

/**
 * Hull-sweep for an empty space in front of the player and create
 * a backpack there.
 */
int TraceAndCreateBackpack(int client, int backpack_type)
{
    int backpack = -1;

    float pos[3];
    float angles[3];
    if (TraceBackpackPosition(client, pos, angles))
    {
        backpack = CreateBackpack(pos, angles, backpack_type);
    }

    return backpack;
}

/**
 * Reduce backpack's use range.
 *
 * Play sound effect when backpack is opened.
 */
public Action Hook_BackpackUse(
    int backpack,
    int activator,
    int caller,
    UseType type,
    float value)
{
    float distance_squared = GetEntDistance(backpack, activator, SQUARED_DISTANCE, true);
    bool allow = distance_squared <= BACKPACK_MAX_USE_DISTANCE_SQUARED &&
        CanPlayerOpenBackpackInstance(activator, backpack);

    if (allow)
    {
        int backpack_ref = EntIndexToEntRef(backpack);
        int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);

        static int previous[SHUFFLE_SOUND_COUNT] = { -1, ... };
        PlayBackpackSound(backpack, backpack_index, BACKPACK_TYPE_OPEN_SOUNDS, previous);
    }

    return allow ? Plugin_Continue : Plugin_Handled;
}

/**
 * CItem_InventoryBox::RemoveItem got inlined/removed in 1.11.5
 * This reimplements its logic
 */
void InventoryBox_RemoveItem(int box, eInventoryBoxCategory type, int index)
{
    switch (type)
    {
        case INVENTORY_BOX_CATEGORY_WEAPON:
            if (index <= 7) 
                SetEntData(box, g_offset_itembox_weapon_array + index * 4, 0);

        case INVENTORY_BOX_CATEGORY_GEAR:
            if (index <= 3)
                SetEntData(box, g_offset_itembox_gear_array + index * 4 , 0);

        case INVENTORY_BOX_CATEGORY_AMMO:
            if (index <= 7)
                SetEntData(box, g_offset_itembox_ammo_array + index * 4, 0);
    }
}

/**
 * Insert items into the backpack.
 */
public void Hook_BackpackStartTouch(int backpack, int other)
{
    int backpack_ref = EntIndexToEntRef(backpack);
    int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);

    bool play_sound = false;
    bool remove = false;

    char classname[CLASSNAME_MAX];
    if (IsClassnameEqual(other, classname, sizeof(classname), ITEM_AMMO_BOX))
    {
        int ammo_amount = GetEntProp(other, Prop_Data, "m_iAmmoCount");
        int added = AddAmmoBoxToBackpack(backpack, backpack_index, other);

        play_sound = added > 0;
        remove = added == ammo_amount;
    }
    else if (SDKCall(g_sdkcall_entity_is_combat_weapon, other) &&
        AddWeaponToBackpack(backpack, backpack_index, other))
    {
        play_sound = true;
        remove = true;
    }

    if (play_sound)
    {
        static int previous[SHUFFLE_SOUND_COUNT] = { -1, ... };
        PlayBackpackSound(backpack, backpack_index, BACKPACK_TYPE_ADD_SOUNDS, previous);
    }

    if (remove)
    {
        AcceptEntityInput(other, "Kill");
    }
}

/**
 * Insert an entity into a backpack.
 *
 * @param backpack          Backpack edict.
 * @param backpack_index    Index of backpack inside g_backpacks.
 * @param weapon_entity     Weapon that will be inserted into the backpack.
 *
 * @return      True if the item was added to the backpack; otherwise returns
 *              false.
 */
bool AddWeaponToBackpack(int backpack, int backpack_index, int weapon_entity)
{
    bool added = false;

    char classname[CLASSNAME_MAX];
    GetEntityClassname(weapon_entity, classname, sizeof(classname));

    int weapon_id = -1;
    int category = -1;

    if (backpack_index != -1 &&
        GetWeaponByName(classname, weapon_id, category))
    {
        int max_slots = ITEMBOX_MAX_SLOTS;
        int base_offset = g_offset_itembox_weapon_array;
        ArrayList clips = g_backpack_clips;

        if (category == view_as<int>(INVENTORY_BOX_CATEGORY_GEAR))
        {
            max_slots = ITEMBOX_MAX_GEAR;
            base_offset = g_offset_itembox_gear_array;
            clips = g_backpack_gear_clips;

            // Add tool_barricade because it will be inserted into 'gear' category.
            strcopy(classname, sizeof(classname), "tool_barricade");
        }
        else
        {
            // Add fa_glock17 because it will be inserted into 'weapon' category.
            strcopy(classname, sizeof(classname), "fa_glock17");
        }

        int empty_slot = -1;

        for (int i = 0; i < max_slots && empty_slot == -1; ++i)
        {
            int offset = base_offset + SIZEOF_INT * i;
            int id = GetEntData(backpack, offset, SIZEOF_INT);

            if (id == 0)
            {
                empty_slot = i;
            }
        }

        if (empty_slot != -1)
        {
            SDKCall(g_sdkcall_itembox_add_item, backpack, classname);

            // Assign actual item ID to slot (this fixes the tool_barricade/fa_glock17 above.
            SetEntData(backpack, base_offset + empty_slot * SIZEOF_INT, weapon_id);

            int ammo_amount = -1;
            if (HasEntProp(weapon_entity, Prop_Data, "m_iClip1"))
            {
                ammo_amount = GetEntProp(weapon_entity, Prop_Data, "m_iClip1");
            }
            clips.Set(backpack_index, ammo_amount, empty_slot);
    
            added = true;
        }
    }

    return added;
}

/**
 * Insert an ammo box into a backpack.
 *
 * @param backpack          Backpack edict.
 * @param backpack_index    Index of backpack inside g_backpacks.
 * @param ammo_box          Ammo box that will be inserted into the backpack.
 *
 * @return      True if the item was added to the backpack; otherwise returns
 *              false.
 */
int AddAmmoBoxToBackpack(int backpack, int backpack_index, int ammo_box)
{
    int added = 0;

    char ammo_name[80];
    int weapon_id = -1;
    int category = -1;

    if (backpack_index != -1 &&
        GetAmmoByEnt(ammo_box, weapon_id, category, ammo_name, sizeof(ammo_name)))
    {
        int empty_slot = -1;
        int matching_slot = -1;

        int max_stored = INT_MAX;
        int max_stacks = g_cvar_backpack_ammo_stack_limit.IntValue;
        if (max_stacks > 0)
        {
            max_stored = SDKCall(g_sdkcall_ammobox_get_max_ammo, ammo_box) * max_stacks;
        }

        // Locate first empty slot and non-full slot of matching type.
        for (int i = 0; i < ITEMBOX_MAX_SLOTS && (empty_slot == -1 || matching_slot == -1); ++i)
        {
            int offset = g_offset_itembox_ammo_array + SIZEOF_INT * i;
            int id = GetEntData(backpack, offset, SIZEOF_INT);

            if (id == 0 && empty_slot == -1)
            {
                empty_slot = i;
            }
            else if (id == weapon_id && matching_slot == -1 &&
                g_backpack_ammos.Get(backpack_index, i) < max_stored)
            {
                matching_slot = i;
            }
        }

        int ammo_amount = GetEntProp(ammo_box, Prop_Data, "m_iAmmoCount");

        // Prefer adding to existing spot.
        if (matching_slot != -1)
        {
            int stored_before = g_backpack_ammos.Get(backpack_index, matching_slot);
            int stored_after = stored_before + ammo_amount;
            bool overflowed = false;

            if (stored_after < stored_before)
            {
                // Int overflow.
                added = max_stored - stored_before;
                ammo_amount -= added;
                stored_after = max_stored;
                SetEntProp(ammo_box, Prop_Data, "m_iAmmoCount", ammo_amount);
                overflowed = true;
            }
            else if (stored_after > max_stored)
            {
                // Maxed out ammo slot.
                added = ammo_amount - (stored_after - max_stored);
                ammo_amount = stored_after - max_stored;
                stored_after = max_stored;
                SetEntProp(ammo_box, Prop_Data, "m_iAmmoCount", ammo_amount);
                overflowed = true;
            }
            else
            {
                added = ammo_amount;
                ammo_amount = 0;
            }
            g_backpack_ammos.Set(backpack_index, stored_after, matching_slot);

            if (overflowed && ammo_amount > 0)
            {
                // Recurse.
                added += AddAmmoBoxToBackpack(backpack, backpack_index, ammo_box);
            }
        }
        else if (empty_slot != -1)
        {
            SDKCall(g_sdkcall_itembox_add_item, backpack, ammo_name);
            g_backpack_ammos.Set(backpack_index, ammo_amount, empty_slot);
            added = ammo_amount;

            // Try to update box!
            ItemBoxItemTaken(INVENTORY_BOX_CATEGORY_AMMO, -1);
        }
    }

    return added;
}

/**
 * Watch for player to press drop weapon button while they have their fists
 * equipped and then drop their backpack.
 */
public Action OnPlayerRunCmd(
    int client,
    int &buttons,
    int &impulse,
    float vel[3],
    float angles[3],
    int &weapon,
    int &subtype,
    int &cmdnum,
    int &tickcount,
    int &seed,
    int mouse[2])
{
    if ((buttons & IN_DROPWEAPON) &&
        g_player_fists_equipped[client] &&
        EntRefToEntIndex(g_player_backpacks[client]) != INVALID_ENT_REFERENCE)
    {
        int fists = GetClientActiveWeapon(client);
        if (HasEntProp(fists, Prop_Send, "m_flNextPrimaryAttack") &&
            GetGameTime() >= GetEntPropFloat(fists, Prop_Send, "m_flNextPrimaryAttack"))
        {
            DropBackpack(client);
        }
    }
    return Plugin_Continue;
}

/**
 * Put backpack on player's back.
 *
 * @param client        Player doing pick up.
 * @param backpack      Backpack entity.
 */
void PickupBackpack(int client, int backpack)
{
    if (EntRefToEntIndex(g_player_backpacks[client]) == INVALID_ENT_REFERENCE)
    {
        bool held = false;

        // Make sure no one else is holding the backpack.
        int backpack_ref = EntIndexToEntRef(backpack);
        for (int i = 1; i <= MaxClients && !held; ++i)
        {
            if (g_player_backpacks[i] == backpack_ref)
            {
                held = true;
            }
        }

        if (!held)
        {
            int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
            if (backpack_index != -1 && CanPlayerWearBackpackInstance(client, backpack))
            {
                // Attach the backpack ornament to the player.
                int ornament = EntRefToEntIndex(g_backpacks.Get(backpack_index, BACKPACK_ORNAMENT));
                if (ornament != INVALID_ENT_REFERENCE)
                {
                    SetVariantString("!activator");
                    AcceptEntityInput(ornament, "SetAttached", client, client);
                }

                static int previous[SHUFFLE_SOUND_COUNT] = { -1, ... };
                PlayBackpackSound(client, backpack_index, BACKPACK_TYPE_WEAR_SOUNDS, previous);

                // Stop players from taking items once the backpack is worn.
                if (g_sdkcall_itembox_end_use_for_all_players)
                {
                    SDKCall(g_sdkcall_itembox_end_use_for_all_players, backpack);
                }

                // Stop glowing backpack.
                RequestFrame(Frame_DisableGlow, EntIndexToEntRef(backpack));

                HideEntity(backpack);
                g_player_backpacks[client] = backpack_ref;
            }
        }
    }
    else
    {
        PrintToChat(client, "%T", "@backpack-can-only-wear-one", client);
    }
}

/**
 * Check if a player has any admin access.
 */
bool IsClientAdmin(int client)
{
    return CheckCommandAccess(client, "backpack_admin", ADMFLAG_BACKPACK);
}

/**
 * Check if this player is generally allowed to wear a backpack.
 */
bool CanPlayerWearBackpack(int client)
{
    return IsClientInGame(client) &&
        (g_cvar_backpack_only_admins_can_wear.BoolValue ? IsClientAdmin(client) : !IsFakeClient(client));
}

/**
 * Return true if the player can wear this type of backpack.
 */
bool CanPlayerWearBackpackInstance(int client, int backpack)
{
    bool can_wear = false;

    if (IsClientInGame(client) && !IsFakeClient(client))
    {
        int backpack_ref = EntIndexToEntRef(backpack);
        int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
        if (backpack_index != -1)
        {
            int backpack_type = g_backpacks.Get(backpack_index, BACKPACK_TYPE);
            eCvarFlag admins_only = g_backpack_types.Get(backpack_type, BACKPACK_TYPE_ONLY_ADMINS_WEAR);

            if (admins_only == CVAR_FLAG_DEFAULT)
            {
                can_wear = CanPlayerWearBackpack(client);
            }
            else if (admins_only == CVAR_FLAG_YES)
            {
                can_wear = IsClientAdmin(client);
            }
            else
            {
                can_wear = true;
            }
        }
    }

    return can_wear;
}

/**
 * Check if this player is generally allowed to open a backpack's UI.
 */
bool CanPlayerOpenBackpack(int client)
{
    return IsClientInGame(client) &&
        (g_cvar_backpack_only_admins_can_open.BoolValue ? IsClientAdmin(client) : !IsFakeClient(client));
}

/**
 * Return true if the player can open this type of backpack.
 */
bool CanPlayerOpenBackpackInstance(int client, int backpack)
{
    bool can_open = false;

    if (IsClientInGame(client) && !IsFakeClient(client))
    {
        int backpack_ref = EntIndexToEntRef(backpack);
        int backpack_index = g_backpacks.FindValue(backpack_ref, BACKPACK_ITEM_BOX);
        if (backpack_index != -1)
        {
            int backpack_type = g_backpacks.Get(backpack_index, BACKPACK_TYPE);
            eCvarFlag admins_only = g_backpack_types.Get(backpack_type, BACKPACK_TYPE_ONLY_ADMINS_OPEN);

            if (admins_only == CVAR_FLAG_DEFAULT)
            {
                can_open = CanPlayerOpenBackpack(client);
            }
            else if (admins_only == CVAR_FLAG_YES)
            {
                can_open = IsClientAdmin(client);
            }
            else
            {
                can_open = true;
            }
        }
    }

    return can_open;
}

/**
 * Called when player punches a backpack.
 *
 * Place the punched backpack on the player's back.
 */
public Action Hook_BackpackPickup(
    int backpack,
    int &attacker,
    int &inflictor,
    float &damage,
    int &damage_type)
{
    char weapon_name[CLASSNAME_MAX];

    if (attacker > 0 &&
        attacker <= MaxClients &&
        CanPlayerWearBackpackInstance(attacker, backpack) &&
        g_player_fists_equipped[attacker] &&
        IsClassnameEqual(inflictor, weapon_name, sizeof(weapon_name), ME_FISTS))
    {
        PickupBackpack(attacker, backpack);
    }

    return Plugin_Continue;
}

/**
 * Hides an entity by moving it outside normal gameplay bounds.
 */
void HideEntity(int entity)
{
    float out_of_bounds[3] = { 16383.0, ... };
    TeleportEntity(entity, out_of_bounds, NULL_VECTOR, NULL_VECTOR);
    AcceptEntityInput(entity, "DisableMotion");
}

/**
 * Create a weapon for a player.
 *
 * @param player        Player to create the item for.
 * @param classname     Classname of the item to spawn.
 * @param clip          Rounds weapon should have in its magazine.
 *
 * @return      True if the item was created, otherwise returns false.
 */
bool CreateBackpackItemFor(int client, const char[] classname, int clip)
{
    int item = CreateEntityByName(classname);
    if (item != -1)
    {
        g_new_backpack_item_ref = EntIndexToEntRef(item);
        g_new_backpack_item_clip = clip;
        g_new_backpack_item_user_id = GetClientUserId(client);
        g_new_backpack_item_owner_has_room = false;

        SDKHook(item, SDKHook_SpawnPost, Hook_BackpackItemSpawned);

        float origin[3];
        GetClientEyePosition(client, origin);
        DispatchKeyValueVector(item, "origin", origin);

        if (DispatchSpawn(item) && g_new_backpack_item_owner_has_room)
        {
            AcceptEntityInput(item, "Use", client, client);
        }
        else
        {
            // Keep item in backpack if player has no room for it.
            AcceptEntityInput(item, "Kill");
            item = -1;
        }
    }
    return item != -1;
}

/**
 * Restore the rounds in the item's magazine.
 */
public void Hook_BackpackItemSpawned(int weapon)
{
    if (weapon == EntRefToEntIndex(g_new_backpack_item_ref))
    {
        int clip = g_new_backpack_item_clip;
        if (clip != -1 && HasEntProp(weapon, Prop_Send, "m_iClip1"))
        {
            SetEntProp(weapon, Prop_Send, "m_iClip1", clip);
        }

        int client = GetClientOfUserId(g_new_backpack_item_user_id);
        if (client != 0 &&
            IsClientInGame(client) &&
            IsPlayerAlive(client) &&
            SDKCall(g_sdkcall_entity_is_combat_weapon, weapon))
        {
            int current_weight = GetClientCarryWeight(client);
            int max_weight = g_inv_maxcarry.IntValue;
            int weapon_weight = SDKCall(g_sdkcall_weapon_get_weight, weapon);

            bool has_room = (max_weight - current_weight) >= weapon_weight;

            g_new_backpack_item_owner_has_room = has_room;
        }
    }
}

int GetClientCarryWeight(int client)
{
    int ammo_weight = SDKCall(g_sdkcall_player_get_ammo_weight, client);
    int weapon_weight = GetEntProp(client, Prop_Send, "_carriedWeight");
    return ammo_weight + weapon_weight;
}

/**
 * Create an ammo box for a player and have them pick it up.
 *
 * The amount of ammo in the pickup is deducted from the 'stored'
 * parameter.
 *
 * @param client        Player that will receive ammo.
 * @param ammo_type     Name of ammo to give (e.g. ammobox_9mm).
 * @param stored        Amount of ammo in reserve that this function will
 *                      from.
 *
 * @return      Edict of ammo box created.
 */
int CreateBackpackAmmoFor(int client, const char[] ammo_type, int &stored)
{
    int ammo_box = -1;
    if (stored > 0)
    {
        ammo_box = CreateEntityByName(ITEM_AMMO_BOX);
        if (ammo_box != -1)
        {
            // Assign ammuntion type.
            SDKCall(g_sdkcall_ammobox_set_ammo_type, ammo_box, ammo_type);

            // Assign ammo count.
            int max_ammo = SDKCall(g_sdkcall_ammobox_get_max_ammo, ammo_box);
            int rounds = stored > max_ammo ? max_ammo : stored;
            SDKCall(g_sdkcall_ammobox_set_ammo_count, ammo_box, rounds);
            stored -= rounds;

            float origin[3];
            GetClientEyePosition(client, origin);
            DispatchKeyValueVector(ammo_box, "origin", origin);

            if (DispatchSpawn(ammo_box))
            {
                AcceptEntityInput(ammo_box, "Use", client, client);

                if ((GetEntProp(ammo_box, Prop_Data, "m_iEFlags") & EFL_NO_THINK_FUNCTION))
                {
                    // Put leftovers back in backpack.
                    stored += GetEntProp(ammo_box, Prop_Data, "m_iAmmoCount");
                    RemoveEdict(ammo_box);
                    ammo_box = -1;
                }
            }
            else
            {
                RemoveEdict(ammo_box);
                ammo_box = -1;
            }
        }
    }
    return ammo_box;
}

/**
 * Trace for world collisions only.
 */
public bool Trace_IgnoreAll(int entity, int contents_mask)
{
    return entity == 0;
}

stock int TracePlayerView(int client, TraceEntityFilter filter)
{
    float start[3];
    GetClientEyePosition(client, start);

    float angles[3];
    GetClientEyeAngles(client, angles);

    TR_TraceRayFilter(start, angles, MASK_SOLID, RayType_Infinite, filter, client);
    return TR_GetEntityIndex();
}

/**
 * Because Sourcemod's IsPlayerAlive returns true when player is in welcome screen in NMRiH.
 */
stock bool NMRiH_IsPlayerAlive(int client)
{
    bool alive = false;
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        alive = GetEntProp(client, Prop_Send, "m_iPlayerState") == STATE_ACTIVE;
    
    return alive;
}

/**
 * Create a DHook from a game conf or abort the plugin.
 */
Handle DHookCreateFromConfOrFail(Handle gameconf, const char[] key)
{
    Handle result = DHookCreateFromConf(gameconf, key);
    if (!result)
    {
        CloseHandle(gameconf);
        SetFailState("Failed to create DHook for %s", key);
    }
    return result;
}

/**
 * Retrieve an offset from a game conf or abort the plugin.
 */
int GameConfGetOffsetOrFail(Handle gameconf, const char[] key)
{
    int offset = GameConfGetOffset(gameconf, key);
    if (offset == -1)
    {
        CloseHandle(gameconf);
        SetFailState("Failed to read gamedata offset of %s", key);
    }
    return offset;
}

/**
 * Prep SDKCall from signature or abort.
 */
void GameConfPrepSDKCallSignatureOrFail(Handle gameconf, const char[] key)
{
    if (!PrepSDKCall_SetFromConf(gameconf, SDKConf_Signature, key))
    {
        CloseHandle(gameconf);
        SetFailState("Failed to retrieve signature for gamedata key %s", key);
    }
}

/**
 * Return true if the entity's classname equals the other string.
 */
stock bool IsClassnameEqual(int entity, char[] classname, int classname_size, const char[] compare_to)
{
    GetEntityClassname(entity, classname, classname_size);
    return StrEqual(classname, compare_to);
}

/**
 * Retrieve an entity's owner.
 */
stock int GetEntOwner(int entity)
{
    return GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
}

/**
 * Retrieve id of player's current weapon.
 */
stock int GetClientActiveWeapon(int client)
{
    return GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
}

/**
 * Retrieve an entity's targetname (the name assigned to it in Hammer).
 *
 * @param entity            Entity to query.
 * @param targetname        Output buffer.
 * @param buffer_size       Size of output buffer.
 *
 * @return                  Number of non-null bytes written.
 */
stock int GetEntTargetname(int entity, char[] targetname, int buffer_size)
{
    return GetEntPropString(entity, Prop_Data, "m_iName", targetname, buffer_size);
}

/**
 * Assign an entity a new targetname.
 *
 * @param entity            Entity to modify.
 * @param targetname        New targetname to assign.
 */
stock void SetEntTargetname(int entity, const char[] targetname)
{
    SetEntPropString(entity, Prop_Data, "m_iName", targetname);
}

/**
 * Retrieve an entity's health.
 *
 * @param entity            Entity to query.
 *
 * @return                  Entity's health.
 */
stock int GetEntHealth(int entity)
{
    return GetEntProp(entity, Prop_Data, "m_iHealth");
}

/**
 * Retrieve an entity's max health.
 *
 * @param entity            Entity to query.
 *
 * @return                  Entity's max health.
 */
stock int GetEntMaxHealth(int entity)
{
    return GetEntProp(entity, Prop_Data, "m_iMaxHealth");
}

/**
 * Retrieve an entity's origin.
 *
 * @param entity            Entity to query.
 * @param origin            Output vector.
 */
stock void GetEntOrigin(int entity, float origin[3])
{
    //GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);
}

/**
 * Retrieve an entity's rotation.
 */
stock void GetEntRotation(int entity, float angles[3])
{
    GetEntPropVector(entity, Prop_Data, "m_angAbsRotation", angles);
}

/**
 * Copy the values of one vector to another.
 */
stock void CopyVector(const float source[3], float dest[3])
{
    dest[X] = source[X];
    dest[Y] = source[Y];
    dest[Z] = source[Z];
}

/**
 * Copy the values of one vector to another.
 */
stock void AssignVector(float x, float y, float z, float dest[3])
{
    dest[X] = x;
    dest[Y] = y;
    dest[Z] = z;
}

/**
 * Calculate distance between two entities.
 */
stock float GetEntDistance(int ent_a, int ent_b, bool squared = false, bool horizontal_only = false)
{
    float pos_a[3];
    GetEntOrigin(ent_a, pos_a);

    float pos_b[3];
    GetEntOrigin(ent_b, pos_b);

    if (horizontal_only)
    {
        pos_b[Z] = pos_a[Z];
    }

    return GetVectorDistance(pos_a, pos_b, squared);
}

/**
 * Try to select a sound index that hasn't been played yet.
 */
stock int ShuffleSoundIndex(int count, int previous[SHUFFLE_SOUND_COUNT])
{
    int sound_index = -1;

    if (count > SHUFFLE_SOUND_COUNT)
    {
        static const int MAX_ATTEMPTS = 3;
        for (int i = 0; i < MAX_ATTEMPTS; ++i)
        {
            int random_index = GetURandomInt() % count;
            for (int j = 0; j < SHUFFLE_SOUND_COUNT; ++j)
            {
                if (random_index == previous[j])
                {
                    random_index = -1;
                    break;
                }
            }

            if (random_index != -1)
            {
                sound_index = random_index;
                break;
            }
        }
    }

    if (sound_index == -1)
    {
        sound_index = (previous[SHUFFLE_SOUND_COUNT - 1] + 1) % count;
    }

    for (int i = 0; i < SHUFFLE_SOUND_COUNT - 1; ++i)
    {
        previous[i] = previous[i + 1];
    }
    previous[SHUFFLE_SOUND_COUNT - 1] = sound_index;


    return sound_index;
}

/**
 * Quickly remove an element from ArrayList by swapping it with last element
 * and then popping the back.
 */
stock void RemoveArrayListElement(ArrayList &list, int index)
{
    if (list && index >= 0 && index < list.Length)
    {
        int last = 0;
        if (list.Length > 1)
        {
            last = list.Length - 1;
            list.SwapAt(index, last);
        }
        list.Erase(last);
    }
}

/**
 * Reinterpret int as ArrayList.
 */
stock ArrayList TupleGetArrayList(int[] tuple, int index)
{
    return view_as<ArrayList>(tuple[index]);
}
