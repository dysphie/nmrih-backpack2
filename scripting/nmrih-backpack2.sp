#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#include <vscript_proxy>

#pragma semicolon 1
#pragma newdecls required

// FIXME: Item trace hulls are not clipped
// FIXME: Zombies can drop weapons at 0 0 0 when they receive a backpack
// TODO: Glow backpacks when obj items are added to them, and restore targetnames

#define PLUGIN_PREFIX "[Backpack2] "

#define MASK_NONE 0
#define INVALID_USER_ID 0

#define TEMPLATE_RANDOM -1

#define WEIGHT_PER_AMMO 5
#define WEAPON_NOT_CARRIED 0
#define MAXENTITIES 2048
#define EF_ITEM_BLINK 0x100

#define MAX_BP_USE_DISTANCE 90.0


#define MAXPLAYERS_NMRIH 9

#define PROP_PHYS_DEBRIS 4
#define PROP_PHYS_USE_OUTPUT 256

#define GLOWTYPE_GLOW 1
#define GLOWTYPE_BLINK 2

#define MASK_ITEM 0
#define INVALID_ITEM 0
#define INVALID_AMMO -1

enum 
{
	COL_LEFT,
	COL_MIDDLE,
	COL_RIGHT,
	COL_MAX
}

enum 
{
	CAT_WEAPON,
	CAT_AMMO
}

public Plugin myinfo = {
	name        = "[NMRiH] Backpack2",
	author      = "Dysphie & Ryan",
	description = "Portable inventory boxes",
	version     = "2.0.7",
	url         = "github.com/dysphie/nmrih-backpack2"
};

bool optimize;
bool fixUpBoards;

ConVar cvOptimize;
ConVar cvHints;
ConVar cvGlowType;
ConVar cvGlowBlip;
ConVar cvGlowDist;
ConVar cvNpcBackpackChance;
ConVar cvBackpackCount;
ConVar cvAmmoMultiplier;
ConVar cvBackpackColorize;

ConVar cvRightLootMin;
ConVar cvRightLootMax;
ConVar cvAmmoLootMinPct;
ConVar cvAmmoLootMaxPct;
ConVar cvMiddleLootMin;
ConVar cvMiddleLootMax;
ConVar cvLeftLootMin;
ConVar cvLeftLootMax;

ConVar inv_maxcarry = null;

Cookie hintCookie;

ArrayList templates = null;
ArrayList backpacks = null;

StringMap itemLookup = null;
ArrayList itemRegistry = null;

bool wasLookingAtBackpack[MAXPLAYERS_NMRIH+1] = {false, ...};
float nextHintTime[MAXPLAYERS_NMRIH+1] = {-1.0, ...};
bool wearingBackpack[MAXENTITIES+1] = {false, ...};
bool isDroppedBackpack[MAXENTITIES+1] = {false, ...};
float stopThinkTime[MAXENTITIES+1] = {-1.0, ...};

bool used[MAXENTITIES+1] = { false, ...};

int MaxEntities = 0;
int numDroppedBackpacks = 0;

enum struct BackpackSound
{
	char path[PLATFORM_MAX_PATH];
	int layers;
}

enum struct Item
{
	char alias[64];
	int id;
	int category;
	int columns;		// Columns this item can go in
	bool spawnAsLoot;
	int ammoID;
	int capacity;
}

enum
{
	SoundAdd,
	SoundDrop,
	SoundWear,
	SoundOpen,
	SoundMAX
}

enum struct BackpackTemplate
{
	int itemLimit[COL_MAX];

	char attachMdl[PLATFORM_MAX_PATH];
	char droppedMdl[PLATFORM_MAX_PATH];


	ArrayList sounds[SoundMAX];
	int layers[SoundMAX];

	void Init()
	{
		for (int i; i < SoundMAX; i++) {
			this.sounds[i] = new ArrayList(sizeof(BackpackSound));
		}
	}

	void Delete()
	{
		for (int i; i < SoundMAX; i++) {
			delete this.sounds[i];
		}
	}
}

enum struct StoredItem
{
	int id;
	int ammoCount;
}

enum struct Backpack
{
	int templateID;			// Template index, used for sounds, colors, models, etc.

	int propRef;			// Entity reference to the backpack's object in the world
	int wearerRef;				// Entity reference to the backpack wearer
	
	ArrayList items[COL_MAX];	

	int atInterface[MAXPLAYERS_NMRIH+1];    // True if player index is likely browsing the backpack
											// Must verify with in-game check

	int color[3];			// Unique color to distinguish from other backpacks (tint and glow)

	void Init(int templateID)
	{
		StoredItem blank;

		if (templateID == TEMPLATE_RANDOM) 
		{
			this.templateID = GetRandomInt(0, templates.Length - 1);
		} else {
			this.templateID = templateID;
		}

		BackpackTemplate template;
		templates.GetArray(this.templateID, template);

		for (int i = 0; i < COL_MAX; i++) 
		{
			this.items[i] = new ArrayList(sizeof(StoredItem));
			for (int j; j < template.itemLimit[i]; j++) 
			{
				this.items[i].PushArray(blank);
			}
		}

		this.propRef = INVALID_ENT_REFERENCE;
		this.wearerRef = INVALID_ENT_REFERENCE;

		GetRandomRGB(this.color);
	}

	void ColorizeProp(int prop)
	{
		if (cvBackpackColorize.BoolValue)
		{
			SetEntityRenderMode(prop, RENDER_TRANSCOLOR);
			SetEntityRenderColor(prop, this.color[0], this.color[1], this.color[2], 255);
		}
	}

	void ShuffleContents()
	{
		for (int i = 0; i < COL_MAX; i++) {
			this.items[i].Sort(Sort_Random, Sort_Integer);	
		}
	}

	void HighlightEntity(int entity)
	{
		int glowType = cvGlowType.IntValue;
		
		if (glowType == GLOWTYPE_GLOW)
		{
			DispatchKeyValue(entity, "glowable", "1");
			DispatchKeyValue(entity, "glowblip", cvGlowBlip.BoolValue ? "1" : "0");
			DispatchKeyValueFloat(entity, "glowdistance", cvGlowDist.FloatValue);

			char colorStr[12];
			FormatEx(colorStr, sizeof(colorStr), "%d %d %d", this.color[0], this.color[1], this.color[2]);
				
			DispatchKeyValue(entity, "glowcolor", colorStr);
		
			RequestFrame(Frame_GlowEntity, EntIndexToEntRef(entity));
		}	
		else if (glowType == GLOWTYPE_BLINK)
		{
			AddEntityEffects(entity, EF_ITEM_BLINK);
		}
	}

	bool Attach(int wearer, bool suppressSound = false)
	{
		if (this.wearerRef != INVALID_ENT_REFERENCE) {
			return false;
		}

		this.EndUseForAll();

		int attached = CreateEntityByName("prop_dynamic_ornament");
		if (attached == -1) {
			return false;
		}

		BackpackTemplate template;
		templates.GetArray(this.templateID, template);
		DispatchKeyValue(attached, "model", template.attachMdl);
		DispatchKeyValue(attached, "disableshadows", "1");
		
		if (!DispatchSpawn(attached)) 
		{
			RemoveEntity(attached);
			return false;
		}

		// Remove physics prop
		int dropped = EntRefToEntIndex(this.propRef);
		if (dropped != -1)
		{
			isDroppedBackpack[dropped] = false;
			RemoveEntity(dropped);
			numDroppedBackpacks--;
		}

		SetVariantString("!activator");
		AcceptEntityInput(attached, "SetAttached", wearer, wearer);

		this.ColorizeProp(attached);

		this.wearerRef = EntIndexToEntRef(wearer);
		this.propRef = EntIndexToEntRef(attached);

		wearingBackpack[wearer] = true;

		if (!suppressSound) {
			this.PlaySound(SoundWear);	
		}

		return true;
	}

	bool Drop()
	{
		int wearer = EntRefToEntIndex(this.wearerRef);
		if (wearer == -1) {
			return true;
		}

		int dropped = CreateEntityByName("prop_physics_override");
		if (dropped == -1)  {
			return false;
		}

		BackpackTemplate template;
		templates.GetArray(this.templateID, template);
		DispatchKeyValue(dropped, "model", template.droppedMdl);
		DispatchKeyValue(dropped, "spawnflags", "260"); //  Debris (4) + Generate output on +use (256) 

		if (!DispatchSpawn(dropped) || !DropFromEntity(wearer, dropped)) 
		{
			RemoveEntity(dropped);
			return false;
		}

		// Drop was successful past this point

		numDroppedBackpacks++;
		this.ColorizeProp(dropped);
		this.HighlightEntity(dropped);

		SDKHook(dropped, SDKHook_Use, OnBackpackPropUse);
		SDKHook(dropped, SDKHook_OnTakeDamage, OnBackpackPropDamage);

		if (IsValidEntity(this.propRef)) {
			RemoveEntity(this.propRef);
		}

		this.propRef = EntIndexToEntRef(dropped);

		isDroppedBackpack[dropped] = true;
		wearingBackpack[wearer] = false;
		this.wearerRef = INVALID_ENT_REFERENCE;
		this.PlaySound(SoundDrop);

		if (ClientWantsHints(client))
		{
			SendBackpackHint(client, "");
			nextHintTime[client] = GetTickedTime() + 2.0;
		}

		return true;
	}

	void PlaySound(int soundType)
	{
		BackpackTemplate template;
		templates.GetArray(this.templateID, template);

		int rnd = GetRandomInt(0, template.sounds[soundType].Length - 1);

		BackpackSound snd;
		template.sounds[soundType].GetArray(rnd, snd);

		for (int i; i < snd.layers; i++) {
			EmitSoundToAll(snd.path, this.propRef);
		}
	}

	bool Use(int client)
	{
		if (IsValidEntity(this.wearerRef)) {
			return false;
		}

		int dropped = EntRefToEntIndex(this.propRef);
		if (dropped == -1 || !CanReachBackpack(client, dropped)) {
			return false;
		}

		FreezePlayer(client);
		this.PlaySound(SoundOpen);

		if (ClientWantsHints(client))
		{
			SendBackpackHint(client, "");
			nextHintTime[client] = GetTickedTime() + 999999.9;
		}

		Handle msg = StartMessageOne("ItemBoxOpen", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteShort(dropped);

		// Describe every cell in the inventory box
		int expected[] = { 8, 4, 8 };

		for (int k = 0; k < COL_MAX; k++)
		{
			int i = 0;
			int max = this.items[k].Length;
			for (; i < max; i++)
			{
				int id = this.items[k].Get(i, StoredItem::id);

				// HACKHACK: Replace boards with the barricade hammer in the user msg
				// as clients are unable to render board entries in 1.12.1
				// https://github.com/nmrih/source-game/issues/1256
				if (fixUpBoards && id == 61) {
					id = 23;
				}

				bf.WriteShort(id);
			}

			// Our columns might be smaller than the game expects due
			// configurable backpack limits, make sure to fill the rest
			for (; i < expected[k]; i++) {
				bf.WriteShort(INVALID_ITEM);
			}	
		}



		EndMessage();
		this.atInterface[client] = true;
		return true;
	}

	void EndUseForAll()
	{
		for (int i = 1; i <= MaxClients; i++) {
			if (this.atInterface[i] && IsClientInGame(i)) {
				this.EndUse(i);
			}
		}
	}

	void EndUse(int client)
	{
		// HACK: Re enable hints
		nextHintTime[client] = GetTickedTime();
		wasLookingAtBackpack[client] = false;

		UnfreezePlayer(client);
		this.atInterface[client] = false;
		UserMsg_EndUse(client);
	}

	bool AddWeapon(int ammoCount, Item reg, bool suppressSound = false)
	{
		for (int i; i < COL_MAX; i++) 
		{
			if (reg.columns & (1 << i) 
				&& this.AddWeaponToColumn(i, ammoCount, reg, suppressSound))
			{
				return true;
			}
		}
		return false;
	}

	bool AddWeaponToColumn(int col, int ammoCount, Item reg, bool suppressSound = false)
	{
		ArrayList arr = this.items[col];
		int maxItems = arr.Length;

		for (int i = 0; i < maxItems; i++)
		{
			StoredItem stored;
			arr.GetArray(i, stored);

			if (stored.id == INVALID_ITEM)
			{
				stored.id = reg.id;
				stored.ammoCount = ammoCount;
				
				if (!suppressSound) {
					this.PlaySound(SoundAdd);
				}

				arr.SetArray(i, stored);
				return true;
			}
		}
		return false;
	}

	int AddAmmo(int ammoCount, Item reg, bool suppressSound = false, bool allowStacking = true)
	{
		int leftover = ammoCount;

		int i = 0;
		while (leftover > 0 && i < COL_MAX)
		{
			if (reg.columns & (1 << i))
			{
				leftover = this.AddAmmoToColumn(i, leftover, reg, suppressSound);
			}
			i++;
		}
		return leftover;
	}

	int AddAmmoToColumn(int col, int ammoCount, Item reg, bool suppressSound = false, bool allowStacking = true)
	{
		ArrayList arr = this.items[col];

		int fullCapacity = RoundToNearest(reg.capacity * cvAmmoMultiplier.FloatValue);
		if (fullCapacity <= 0) {
			fullCapacity = cellmax;
		}
		
		int leftover = this.AddAmmoRecursively(arr, reg.id, ammoCount, fullCapacity, allowStacking);

		if (!suppressSound && leftover < ammoCount) {
			this.PlaySound(SoundAdd);
		}

		return leftover;
	}

	void AddRandomLoot(int count, int column)
	{
		// Get candidate weapons
		ArrayList loot = new ArrayList(sizeof(Item));
		GetLootForColumn(column, loot);

		int numLoot = loot.Length;
		if (numLoot <= 0) 
		{
			delete loot;
			return;
		}

		// For each available slot, get a random weapon and ammo count
		for (int i; i < count; i++)
		{
			int rnd = GetRandomInt(0, numLoot - 1);    

			Item reg;
			loot.GetArray(rnd, reg);

			if (reg.category == CAT_WEAPON)
			{
				int weapon = CreateEntityByName(reg.alias);
				DispatchSpawn(weapon);

				int rndClip = 1;
				int maxClip = GetMaxClip1(weapon);
				if (maxClip != -1)
				{
					int min = RoundToNearest(maxClip * cvAmmoLootMinPct.FloatValue / 100);
					int max = RoundToNearest(maxClip * cvAmmoLootMaxPct.FloatValue / 100);
					rndClip = GetRandomInt(min, max);	
				}

				if (this.AddWeaponToColumn(column, rndClip, reg, true))
				{
					RemoveEntity(weapon);	
				}
			}
			else if (reg.category == CAT_AMMO)
			{
				int minAmmo = reg.capacity * cvAmmoLootMinPct.IntValue / 100;
				if (minAmmo < 1) { 
					minAmmo = 1; 
				}

				int maxAmmo = reg.capacity * cvAmmoLootMaxPct.IntValue / 100;
				int rndClip = GetRandomInt(minAmmo, maxAmmo);
				this.AddAmmoToColumn(column, rndClip, reg, true, false);
			}
		}

		delete loot;
	}

	int AddAmmoRecursively(ArrayList arr, int itemID, int curAmmo, int maxAmmo, bool allowStacking = true)
	{
		int bestSlot = -1;
		int bestIntake = -1;

		for (int i = 0; i < arr.Length; i++)
		{       
			StoredItem stored;
			arr.GetArray(i, stored);

			if (stored.id == itemID && allowStacking)
			{
				// We choose this slot if our best slot is undefined or empty
				// or it can hold more ammo than the best slot
				if (bestSlot == -1 || arr.Get(bestSlot, StoredItem::id) == INVALID_ITEM)
				{
					int intake = maxAmmo - stored.ammoCount;
					if (intake && intake > bestIntake)
					{
						bestSlot = i;
						bestIntake = intake;        
					}
				}
			}
			else if (stored.id == INVALID_ITEM && bestSlot == -1)
			{
				// We choose this slot if our best slot is undefined
				// else we prioritize partially full slots
				
				bestSlot = i;
				bestIntake = maxAmmo;   
			}
		}

		if (bestSlot != -1)
		{
			if (bestIntake > curAmmo)
				bestIntake = curAmmo;

			StoredItem addTo;
			arr.GetArray(bestSlot, addTo);

			curAmmo -= bestIntake;
			addTo.ammoCount += bestIntake;
			addTo.id = itemID;

			arr.SetArray(bestSlot, addTo);

			// Don't take more ammo than we have
			if (curAmmo < 0)
			{
				curAmmo = 0;
			}
			else if (curAmmo > 0)
			{
				this.AddAmmoRecursively(arr, itemID, curAmmo, maxAmmo);
			}
		}
		
		// No more slots, return remainder
		return curAmmo;
	}

	void TakeItemUpdate(int index, int category)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (this.atInterface[i] && IsClientInGame(i))
			{
				Handle msg = StartMessageOne("ItemBoxItemTaken", i, USERMSG_BLOCKHOOKS);
				BfWrite bf = UserMessageToBfWrite(msg);
				bf.WriteShort(index);
				bf.WriteShort(category);
				bf.WriteShort(EntRefToEntIndex(this.propRef));
				EndMessage();
			}
		}
	}

	bool TakeItem(int index, int column, int client)
	{
		if (!CanReachBackpack(client, this.propRef)) 
		{
			this.EndUse(client);
			return false;
		}

		StoredItem stored;
		this.items[column].GetArray(index, stored); // fix me, could be invalid?

		if (stored.id == INVALID_ITEM) 
		{
			this.EndUse(client);
			return false;
		}

		Item reg;
		if (!GetItemByID(stored.id, reg)) {
			return false;
		}

		if (reg.category == CAT_WEAPON)
		{
			if (ClientOwnsWeapon(client, reg.alias)) 
			{
				PrintCenterText(client, "%t", "Already Own This Type");
				return false;
			}
			int weapon = CreateEntityByName(reg.alias);
			if (weapon == -1) {
				return false;
			}

			DispatchSpawn(weapon);

			int leftoverWeight = inv_maxcarry.IntValue - RoundToCeil(GetCarriedWeight(client));
			if (leftoverWeight < GetWeaponWeight(weapon))
			{
				RemoveEntity(weapon);
				PrintCenterText(client, "%t", "No Inventory Space");
				return false;
			}

			SetEntProp(weapon, Prop_Send, "m_iClip1", stored.ammoCount);

			float pos[3];
			GetClientEyePosition(client, pos);
			TeleportEntity(weapon, pos, NULL_VECTOR, NULL_VECTOR);

			if (0 < client <= MaxClients && IsClientInGame(client))
			{
				AcceptEntityInput(weapon, "Use", client, client);
			}

			stored.id = INVALID_ITEM;
			stored.ammoCount = 0;
			this.items[column].SetArray(index, stored);

			this.TakeItemUpdate(index, column);
		}

		else if (reg.category == CAT_AMMO)
		{
			if (reg.ammoID == INVALID_AMMO) {
				return false;
			}

			int leftoverWeight = inv_maxcarry.IntValue - RoundToCeil(GetCarriedWeight(client));
			if (leftoverWeight <= 0) {
				return false;
			}

			int canTake = leftoverWeight / WEIGHT_PER_AMMO;
			if (canTake > stored.ammoCount)
				canTake = stored.ammoCount;
	
			int curAmmo = GetEntProp(client, Prop_Send, "m_iAmmo", _, reg.ammoID);

			// Give all but last ammo directly, this bypasses ammo capacity limits
			SetEntProp(client, Prop_Send, "m_iAmmo", curAmmo + canTake - 1, _, reg.ammoID); 

			// Now give the last piece of ammo, which will trigger a pickup
			GivePlayerAmmo(client, 1, reg.ammoID);

			stored.ammoCount -= canTake;

			if (stored.ammoCount <= 0)
			{
				stored.id = INVALID_ITEM;
				this.TakeItemUpdate(index, column);
			}

			this.items[column].SetArray(index, stored);
		}

		return true;
	}

	bool IsWorn() 
	{
		return IsValidEntity(this.wearerRef);
	}

	void Delete()
	{
		this.EndUseForAll();

		int wearer = EntRefToEntIndex(this.wearerRef);
		if (wearer == -1) {
			numDroppedBackpacks--;
		} else {
			wearingBackpack[wearer] = false;
		}

		int dropped = EntRefToEntIndex(this.propRef);
		if (dropped != -1)
		{
			isDroppedBackpack[dropped] = false;
			RemoveEntity(dropped);
		}

		for (int i = 0; i < COL_MAX; i++) {
			delete this.items[i];
		}
	}
}

void UserMsg_EndUse(int client)
{
	StartMessageOne("ItemBoxClose", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
	EndMessage();
}

bool IsBackpackableNPC(const char[] classname)
{
	return (StrEqual(classname, "npc_nmrih_shamblerzombie") || 
		StrEqual(classname, "npc_nmrih_runnerzombie"));
}

void GetRandomRGB(int rgb[3])
{
	rgb[0] = GetRandomInt(0, 255);
	rgb[1] = GetRandomInt(0, 255);
	rgb[2] = GetRandomInt(0, 255);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDropped);
	SDKHook(client, SDKHook_WeaponSwitch, OnWeaponSwitch);
}

public void OnPluginStart()
{
	LoadTranslations("backpack2.phrases");
	LoadTranslations("common.phrases");

	ConVar cvGameVersion = FindConVar("nmrih_version");
	if (cvGameVersion)
	{
		char gameVersion[32];
		cvGameVersion.GetString(gameVersion, sizeof(gameVersion));

		if (StrEqual(gameVersion, "1.12.0") || StrEqual(gameVersion, "1.12.1"))
		{
			fixUpBoards = true;
		} 
	}

	hintCookie = new Cookie("backpack2_hints", "Toggles Backpack2 screen hints", CookieAccess_Protected);

	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("player_extracted", OnPlayerExtracted);
	HookEvent("nmrih_reset_map", Event_MapReset);
	HookEvent("game_restarting", OnGameRestarting, EventHookMode_PostNoCopy);
	HookEvent("npc_killed", OnNPCKilled);

	RegConsoleCmd("dropbackpack", Cmd_DropBackpack);
	MaxEntities = GetMaxEntities();
	if (MaxEntities > MAXENTITIES)
	{
		SetFailState("Entity limit greater than expected. " ...
			"Change '#define MAXENTITIES %d' to '#define MAXENTITIES %d' and recompile the plugin",
			MAXENTITIES, MaxEntities);
	}

	cvRightLootMin = CreateConVar("sm_backpack_loot_ammo_min", "0", 
		"Minimum ammo boxes to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvRightLootMax = CreateConVar("sm_backpack_loot_ammo_max", "4", 
		"Maximum ammo boxes to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvAmmoLootMinPct = CreateConVar("sm_backpack_loot_ammo_min_pct", "40", 
		"Minimum fill percentage for ammo boxes spawned as backpack loot", _, true, 1.0);

	cvAmmoLootMaxPct = CreateConVar("sm_backpack_loot_ammo_max_pct", "100", 
		"Maximum fill percentage for ammo boxes spawned as backpack loot", _, true, 1.0);

	cvMiddleLootMin = CreateConVar("sm_backpack_loot_gear_min", "0", 
		"Minimum gear items to place in backpacks spawned as loot", _, true, 0.0, true, 4.0);

	cvMiddleLootMax = CreateConVar("sm_backpack_loot_gear_max", "1", 
		"Maximum gear items to place in backpacks spawned as loot", _, true, 0.0, true, 4.0);

	cvLeftLootMin = CreateConVar("sm_backpack_loot_weapon_min", "0", 
		"Minimum weapons to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvLeftLootMax = CreateConVar("sm_backpack_loot_weapon_max", "2", 
		"Maximum weapons to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvHints = CreateConVar("sm_backpack_show_hints", "1",
		"Whether to show screen hints on how to use backpacks");

	cvAmmoMultiplier = CreateConVar("sm_backpack_ammo_stack_limit", "4",
		"Number of ammo pickups that can be stored per ammo slot. 0 means infinite.");

	cvBackpackCount = CreateConVar("sm_backpack_count", "1",
	 "Number of backpacks to create at round start. Won't create more backpacks than there are players.");

	cvBackpackColorize = CreateConVar("sm_backpack_colorize", "1",
	 "Randomly colorize backpacks to help distinguish them.");

	cvGlowType = CreateConVar("sm_backpack_glow", "2", 
	 "Highlight method for dropped backpacks. 0 = None, 1 = Outline glow, 2 = Pulsing brightness");

	cvGlowBlip = CreateConVar("sm_backpack_glow_blip", "0", 
	 "If highlight mode is set to outline, whether to add a marker to the player's compass");

	cvGlowDist = CreateConVar("sm_backpack_glow_distance", "300.0", 
	 "If highlight mode is set to outline, distance at which the glow stops being seen");

	cvNpcBackpackChance = CreateConVar("sm_backpack_zombie_spawn_chance", "0.005",
	 "Chance for a zombie to spawn with a backpack. Set to zero or negative to disable");

	cvOptimize = CreateConVar("sm_backpack_enable_optimizations", "1",
		"Don't trace dropped items if perceived backpack count is zero. Disable for debugging only");

	cvOptimize.AddChangeHook(CvarChangeOptimize);

	AutoExecConfig(true, "plugin.backpack2");

	inv_maxcarry = FindConVar("inv_maxcarry");

	backpacks = new ArrayList(sizeof(Backpack));
	templates = new ArrayList(sizeof(BackpackTemplate));

	itemRegistry = new ArrayList(sizeof(Item));
	itemLookup = new StringMap();

	ParseConfig();

	AddCommandListener(Cmd_TakeItems, "takeitems");
	AddCommandListener(Cmd_CloseBox, "closeitembox");
	RegAdminCmd("sm_bp", Cmd_Backpack, ADMFLAG_CHEATS);
	RegAdminCmd("sm_backpack", Cmd_Backpack, ADMFLAG_CHEATS);

	hintCookie.SetPrefabMenu(CookieMenu_OnOff_Int, "Backpack2 Hints");


	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientPutInServer(i);
}


void CvarChangeOptimize(ConVar convar, const char[] oldValue, const char[] newValue)
{
	optimize = newValue[0] != '0';
}

public Action Cmd_DropBackpack(int client, int args)
{
	if (IsValidPlayer(client)) {
		ClientDropBackpack(client);
	}
	return Plugin_Handled;
}

void Frame_GlowEntity(int entRef)
{
	int entity = EntRefToEntIndex(entRef);
	if (entity != -1) {
		AcceptEntityInput(entity, "enableglow"); 
	}
}

public void OnMapEnd()
{
	DeleteAllBackpacks();
}

public void OnPluginEnd()
{
	DeleteAllBackpacks();
}

public Action Cmd_Backpack(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, PLUGIN_PREFIX ... "Usage: sm_backpack <#userid|name>");
		return Plugin_Handled;
	}

	char cmdTarget[512];
	GetCmdArg(1, cmdTarget, sizeof(cmdTarget));
	
	int target = FindTarget(client, cmdTarget);
	if (!IsValidPlayer(target)) {
		return Plugin_Handled;
	}

	if (wearingBackpack[target])
	{
		ReplyToCommand(client, PLUGIN_PREFIX ... "%t", "Give Backpack Already Owns", target);
		return Plugin_Handled;
	}

	Backpack bp;
	bp.Init(TEMPLATE_RANDOM);
	bp.Attach(target);
	backpacks.PushArray(bp);

	ReplyToCommand(client, PLUGIN_PREFIX ... "%t", "Give Backpack Success", target);
	return Plugin_Handled;
}

Action Cmd_CloseBox(int client, const char[] command, int argc)
{
	if (!IsValidPlayer(client))
	{
		return Plugin_Continue;
	}

	char cmdIndex[11];
	GetCmdArg(1, cmdIndex, sizeof(cmdIndex));
	int index = StringToInt(cmdIndex);

	int result = backpacks.FindValue(EntIndexToEntRef(index), Backpack::propRef);
	if (result == -1)
	{
		UserMsg_EndUse(client); // Prevent user from getting stuck
		return Plugin_Continue;
	}

	Backpack bp;
	backpacks.GetArray(result, bp);
	bp.EndUse(client);
	backpacks.SetArray(result, bp);

	return Plugin_Continue;
}

Action Cmd_TakeItems(int client, const char[] command, int argc)
{
	if (!IsValidPlayer(client))
	{
		return Plugin_Continue;
	}

	char cmdIndex[11];
	GetCmdArg(1, cmdIndex, sizeof(cmdIndex));
	int index = StringToInt(cmdIndex);

	int idx = backpacks.FindValue(EntIndexToEntRef(index), Backpack::propRef);
	if (idx == -1)
	{
		UserMsg_EndUse(client); // Prevent user from getting stuck
		return Plugin_Continue;
	}

	Backpack bp;
	backpacks.GetArray(idx, bp);

	char cmdLeftCol[11], cmdMiddleCol[11], cmdRightCol[11];
	GetCmdArg(2, cmdLeftCol, sizeof(cmdLeftCol));
	GetCmdArg(3, cmdMiddleCol, sizeof(cmdMiddleCol));
	GetCmdArg(4, cmdRightCol, sizeof(cmdRightCol));


	int leftCol = StringToInt(cmdLeftCol);
	if (0 <= leftCol < bp.items[COL_LEFT].Length)
	{
		bp.TakeItem(leftCol, COL_LEFT, client);
	}

	int middleCol = StringToInt(cmdMiddleCol);
	if (0 <= middleCol < bp.items[COL_MIDDLE].Length)
	{
		bp.TakeItem(middleCol, COL_MIDDLE, client);
	}

	int rightCol = StringToInt(cmdRightCol);
	if (0 <= rightCol < bp.items[COL_RIGHT].Length)
	{
		bp.TakeItem(rightCol, COL_RIGHT, client);
	}

	bp.EndUse(client);
	backpacks.SetArray(idx, bp);

	return Plugin_Handled;
}

Action OnBackpackPropUse(int backpack, int activator, int caller, UseType type, float value)
{
	if (!IsValidPlayer(caller))
		return Plugin_Continue;

	int result = backpacks.FindValue(EntIndexToEntRef(backpack), Backpack::propRef);
	if (result == -1) {
		return Plugin_Continue;
	}

	Backpack bp;
	backpacks.GetArray(result, bp);
	bp.Use(caller);
	backpacks.SetArray(result, bp);
	return Plugin_Handled;
}

bool IsValidPlayer(int client)
{
	return 0 < client <= MaxClients && IsClientInGame(client);
}

public void OnMapStart()
{
	PrecacheAssets();
}

void PrecacheAssets()
{
	int maxTemplates = templates.Length;
	for (int k; k < maxTemplates; k++)
	{
		BackpackTemplate template;
		templates.GetArray(k, template);

		if (template.droppedMdl[0])
		{
			PrecacheModel(template.droppedMdl);
			AddModelToDownloadsTable(template.droppedMdl);
		}
		
		if (template.attachMdl[0])
		{
			PrecacheModel(template.attachMdl);
			AddModelToDownloadsTable(template.attachMdl);
		}

		for (int i = 0; i < sizeof(template.sounds); i++)
		{
			char fullPath[PLATFORM_MAX_PATH];
			BackpackSound snd;

			int maxSounds = template.sounds[i].Length;
			for (int j; j < maxSounds; j++)
			{
				template.sounds[i].GetArray(j, snd);

				if (snd.path[0]) 
				{
					PrecacheSound(snd.path, true);
					FormatEx(fullPath, sizeof(fullPath), "sound/%s", snd.path);
					AddFileToDownloadsTable(fullPath);
				}
			}
		}
	}
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

public void OnEntityCreated(int entity, const char[] classname)
{
	if (0 < entity <= MaxEntities && StrEqual(classname, "item_ammo_box"))
	{
		SDKHook(entity, SDKHook_Use, OnAmmoBoxUse);
		SDKHook(entity, SDKHook_SpawnPost, OnAmmoBoxSpawned);
	}
	else if (IsBackpackableNPC(classname)) {
		SDKHook(entity, SDKHook_SpawnPost, OnZombieSpawned);
	}
}

Action OnAmmoBoxUse(int ammobox, int activator, int caller, UseType type, float value)
{
	if (0 < caller <= MaxClients) {
		used[ammobox] = true;
	}

	return Plugin_Continue;
}

void OnZombieSpawned(int zombie)
{
	// Fixes "Map not running" error
	RequestFrame(OnZombieReallySpawned, EntIndexToEntRef(zombie));
}


public void OnZombieReallySpawned(int zombieRef)
{
	int zombie = EntRefToEntIndex(zombieRef);
	if (zombie == -1) {
		return;
	}

	float rnd = GetURandomFloat();
	if (rnd <= cvNpcBackpackChance.FloatValue)
	{
		Backpack bp;
		bp.Init(TEMPLATE_RANDOM);
		bp.Attach(zombie, true);

		// Add random loot

		int amt = GetRandomInt(cvLeftLootMin.IntValue, cvLeftLootMax.IntValue);
		if (amt > 0) {
			bp.AddRandomLoot(amt, COL_LEFT);
		}

		amt = GetRandomInt(cvMiddleLootMin.IntValue, cvMiddleLootMax.IntValue);
		if (amt > 0) {
			bp.AddRandomLoot(amt, COL_MIDDLE);
		}

		amt = GetRandomInt(cvRightLootMin.IntValue, cvRightLootMax.IntValue);
		if (amt > 0) {
			bp.AddRandomLoot(amt, COL_RIGHT);
		}

		bp.ShuffleContents();
		backpacks.PushArray(bp);	
	}
}

void OnAmmoBoxSpawned(int ammobox)
{
	used[ammobox] = false;
	
	stopThinkTime[ammobox] = GetTickedTime() + 1.5;
	// CheckAmmoBoxCollide(ammobox); // crashing in 1.12.0
	CreateTimer(0.0, OnAmmoFallThink, EntIndexToEntRef(ammobox), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

void OnWeaponDropped(int client, int weapon)
{
	if (!IsValidPlayer(client) || !IsValidEdict(weapon)) {
		return;
	}

	stopThinkTime[weapon] = GetTickedTime() + 1.5;
	// CheckWeaponCollide(weapon); // crashing in 1.12.0
	CreateTimer(0.0, OnWeaponFallThink, EntIndexToEntRef(weapon), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

// HACK: Remove "Drop backpack hint" if client is switching away from fists with a backpack
// I'm gonna tweak this to not use a switch hook later
Action OnWeaponSwitch(int client, int weapon)
{
	if (0 < client <= MaxClients && wearingBackpack[client] && ClientWantsHints(client)) 
	{
		int curWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (curWeapon != -1)
		{
			char classname[15];
			GetEntityClassname(curWeapon, classname, sizeof(classname));

			if (StrEqual(classname, "me_fists"))
			{
				SendBackpackHint(client, "");
			}
		}	
	}

	return Plugin_Continue;
}


Action OnAmmoFallThink(Handle timer, int ammoRef)
// void OnAmmoFallThink(int ammoRef)
{
	int ammobox = EntRefToEntIndex(ammoRef);
	if (ammobox == -1)
		return Plugin_Stop;

	// Fix duplication exploit where players can drop ammo, press E to pick it up and still 
	// have it collide with a backpack afterwards, making it end up in both inventory and backpack
	if (used[ammobox])
		return Plugin_Stop;

	if (GetTickedTime() >= stopThinkTime[ammobox])
		return Plugin_Stop;
	
	CheckAmmoBoxCollide(ammobox);
	// RequestFrame(OnAmmoFallThink, ammoRef);
	return Plugin_Continue;
}

Action OnWeaponFallThink(Handle timer, int weaponRef)
{
	int weapon = EntRefToEntIndex(weaponRef);
	if (weapon != -1 && GetTickedTime() < stopThinkTime[weapon] && 
		GetEntProp(weapon, Prop_Send, "m_iState") == WEAPON_NOT_CARRIED)
	{
		CheckWeaponCollide(weapon);
		return Plugin_Continue;
	}
	else {
		return Plugin_Stop;
	}
}

void CheckAmmoBoxCollide(int ammobox)
{
	if (optimize && numDroppedBackpacks <= 0) {
		return;
	}

	float pos[3];
	GetEntPropVector(ammobox, Prop_Data, "m_vecOrigin", pos);

	static float mins[3] = {-8.0, -8.0, -8.0};
	static float maxs[3] = {8.0, 8.0, 8.0};

	TR_EnumerateEntitiesHull(pos, pos, mins, maxs, MASK_NONE, OnAmmoBoxCollide, ammobox);
}

void CheckWeaponCollide(int weapon)
{
	if (optimize && numDroppedBackpacks <= 0) {
		return;
	}

	float pos[3];
	GetEntPropVector(weapon, Prop_Data, "m_vecOrigin", pos);

	static float mins[3] = {-8.0, -8.0, -8.0};
	static float maxs[3] = {8.0, 8.0, 8.0};

	TR_EnumerateEntitiesHull(pos, pos, mins, maxs, MASK_NONE, OnWeaponCollide, weapon);
}

bool OnAmmoBoxCollide(int collidedWith, int ammoBox)
{
	if (!IsValidEdict(collidedWith))
		return true;

	int backpackID = backpacks.FindValue(EntIndexToEntRef(collidedWith), Backpack::propRef);
	if (backpackID != -1)
	{
		Backpack bp;
		backpacks.GetArray(backpackID, bp);

		Item reg;
		if (!GetItemByEntity(ammoBox, reg)) {
			return false;
		}

		int ammoCount = GetEntProp(ammoBox, Prop_Data, "m_iAmmoCount");
		int leftover = bp.AddAmmo(ammoCount, reg);

		if (leftover < ammoCount) 
		{
			if (!leftover) {
				RemoveEntity(ammoBox);
			}
			else {
				SetEntProp(ammoBox, Prop_Data, "m_iAmmoCount", leftover);
			}

			backpacks.SetArray(backpackID, bp);
			return false;
		}

		return true;
	}

	return true;
}

bool OnWeaponCollide(int collidedWith, int weapon)
{
	if (!IsValidEdict(collidedWith))
		return true;

	int backpackID = backpacks.FindValue(EntIndexToEntRef(collidedWith), Backpack::propRef);
	if (backpackID != -1)
	{
		Item reg;
		if (GetItemByEntity(weapon, reg))
		{
			int ammoAmt = GetEntProp(weapon, Prop_Send, "m_iClip1");

			Backpack backpack;
			backpacks.GetArray(backpackID, backpack);
			
			if (backpack.AddWeapon(ammoAmt, reg)) 
			{
				RemoveEntity(weapon);
				backpacks.SetArray(backpackID, backpack);
				return false;
			}
		}
	}

	return true;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], 
	float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (buttons & IN_ALT2 && !(GetEntProp(client, Prop_Data, "m_nOldButtons") & IN_ALT2))
	{
		int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (activeWeapon != -1)
		{
			char classname[12];
			GetEntityClassname(activeWeapon, classname, sizeof(classname));

			if (StrEqual(classname, "me_fists"))
			{
				ClientDropBackpack(client);
				
				if (ClientWantsHints(client)) {
					SendBackpackHint(client, "");
				}
			}
		}
	}

	else if (ClientWantsHints(client))
	{
		float curTime = GetTickedTime();
		if (curTime < nextHintTime[client]) {
			return Plugin_Continue;
		}

		nextHintTime[client] = curTime + 0.2;

		if (wearingBackpack[client])
		{
			int curWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
			if (curWeapon != -1)
			{
				char classname[12];
				GetEntityClassname(curWeapon, classname, sizeof(classname));

				if (StrEqual(classname, "me_fists"))
				{
					SendBackpackHint(client, "%T", "Hint You Can Drop", client);
				}
			}
		}

		else if (NMRiH_IsPlayerAlive(client) && IsLookingAtBackpack(client))
		{
			if (!wasLookingAtBackpack[client]) 
			{
				SendBackpackHint(client, "%T", "Hint You Can Pick Up", client);
			}

			wasLookingAtBackpack[client] = true;
		}
		else if (wasLookingAtBackpack[client]) 
		{
			SendBackpackHint(client, "");
			wasLookingAtBackpack[client] = false;
		}
	}

	return Plugin_Continue;
}

bool ClientWantsHints(int client)
{
	if (!cvHints.BoolValue)
	{
		return false;
	}

	if (AreClientCookiesCached(client))
	{
		char value[11];
		hintCookie.Get(client, value, sizeof(value));

		if (value[0] && value[0] == '0') 
		{
			return false;
		}
	}

	return true;
}

public void OnEntityDestroyed(int entity)
{
	if (IsValidEdict(entity))
	{
		wearingBackpack[entity] = false;

		if (isDroppedBackpack[entity])
		{
			int idx = backpacks.FindValue(EntIndexToEntRef(entity), Backpack::propRef);
			if (idx != -1)
			{
				DeleteBackpack(idx);    
			}
			isDroppedBackpack[entity] = false;
		}
	}
}

bool IsLookingAtBackpack(int client) {

	float eyePos[3]; 
	float eyeAng[3];
	GetClientEyePosition(client, eyePos);
	GetClientEyeAngles(client, eyeAng);

	TR_TraceRayFilter(eyePos, eyeAng, MASK_SHOT, RayType_Infinite, TraceFilter_IgnoreOne, client);

	if (TR_DidHit()) 
	{
		int hitEnt = TR_GetEntityIndex();
		return IsValidEdict(hitEnt) && isDroppedBackpack[hitEnt] && CanReachBackpack(client, hitEnt);
	}

	return false;
}

bool CanReachBackpack(int client, int bpProp)
{
	float pos[3];
	GetEntPropVector(bpProp, Prop_Data, "m_vecOrigin", pos);

	float eyePos[3];
	GetClientEyePosition(client, eyePos);

	return GetVectorDistance(eyePos, pos) <= MAX_BP_USE_DISTANCE;
}

void OnNPCKilled(Event event, const char[] name, bool dontBroadcast)
{
	int npc = event.GetInt("entidx");

	if (IsValidEdict(npc) && wearingBackpack[npc])
	{
		int idx = backpacks.FindValue(EntIndexToEntRef(npc), Backpack::wearerRef);
		if (idx != -1)
		{
			Backpack bp;
			backpacks.GetArray(idx, bp);
			bp.Drop();
			backpacks.SetArray(idx, bp);
		}
	}
}

void OnGameRestarting(Event event, const char[] name, bool dontBroadcast)
{
	DeleteAllBackpacks();
}

void DeleteAllBackpacks()
{
	Backpack bp;

	int max = backpacks.Length;
	for (int i; i < max; i++)
	{
		backpacks.GetArray(i, bp);
		bp.Delete();
	}

	backpacks.Clear();
}

void DeleteBackpack(int backpackID)
{
	Backpack bp;
	backpacks.GetArray(backpackID, bp);
	bp.Delete();
	backpacks.Erase(backpackID);
}

void ParseConfig()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/backpack2.cfg");

	KeyValues kv = new KeyValues("Backpack2");
	if (!kv.ImportFromFile(path)) {
		SetFailState("Failed to load %s", path);
	}

	ParseItemRegistry(kv);
	PrintToServer("Loaded %d backpack templates", ParseTemplates(kv));

	delete kv;
}

int ParseItemRegistry(KeyValues kv)
{
	int numParsed;

	itemRegistry.Clear();

	if (!kv.JumpToKey("weapon_registry"))
	{
		return 0;
	}

	if (!kv.GotoFirstSubKey()) 
	{
		kv.GoBack();
		return 0;
	}

	do 
	{
		Item item;
	
		item.id = kv.GetNum("id", INVALID_ITEM);

		char columns[64];
		kv.GetString("columns", columns, sizeof(columns), "");

		char columnsExp[3][7];
		ExplodeString(columns, " ", columnsExp, sizeof(columnsExp), sizeof(columnsExp[]));

		for (int i; i < sizeof(columnsExp); i++) 
		{
			if (StrEqual(columnsExp[i], "left")) {
				item.columns |= (1 << COL_LEFT);
			}
			else if (StrEqual(columnsExp[i], "middle")) {
				item.columns |= (1 << COL_MIDDLE);
			}
			else if (StrEqual(columnsExp[i], "right")) {
				item.columns |= (1 << COL_RIGHT);
			}
		}

		char lootStr[5];
		kv.GetString("loot", lootStr, sizeof(lootStr), "yes");
		item.spawnAsLoot = !StrEqual(lootStr, "no");

		item.ammoID = kv.GetNum("ammo-id", INVALID_AMMO);

		// If an entry has an ammo ID, we assume it to be ammo
		if (item.ammoID != INVALID_AMMO)
		{
			// Ammo boxes use model paths as their lookup key (alias)
			item.category = CAT_AMMO;
			item.capacity = kv.GetNum("capacity", 1);
			kv.GetString("model", item.alias, sizeof(item.alias));		
		}
		else 
		{
			kv.GetSectionName(item.alias, sizeof(item.alias));
			item.category = CAT_WEAPON;	
		}

		// if SetArray would fail, resize the array 
		// this expects the game to use somewhat consequential IDs for weapons
		while (item.id != itemRegistry.Length - 1)
		{
			// TODO: Prevent big jumps?
			itemRegistry.Resize(item.id + 1);
		}

		itemRegistry.SetArray(item.id, item);
		itemLookup.SetValue(item.alias, item.id);
		numParsed++;
	}
	while (kv.GotoNextKey());

	kv.GoBack();
	kv.GoBack();

	return numParsed;
}

int ParseTemplates(KeyValues kv)
{
	int numParsed = 0;

	if (!kv.JumpToKey("backpack_types"))
	{
		return 0;
	}
	
	if (kv.GotoFirstSubKey())
	{
		do
		{
			BackpackTemplate template;
			template.Init();

			char bpName[256];
			kv.GetSectionName(bpName, sizeof(bpName));

			template.itemLimit[COL_LEFT] = kv.GetNum("max_left", 8);
			template.itemLimit[COL_MIDDLE] = kv.GetNum("max_middle", 4);
			template.itemLimit[COL_RIGHT] = kv.GetNum("max_right", 8);

			// kv.GetVector("offset", template.offset);
			// kv.GetVector("rotation", template.rotation);
			// kv.GetString("attachment", template.attachment, sizeof(template.attachment));
			kv.GetString("itembox_model", template.droppedMdl, sizeof(template.droppedMdl));
			if (!template.droppedMdl[0])
			{
				LogMessage("Backpack template '%s' missing 'itembox_model' key. Skipping..");
			}

			kv.GetString("ornament_model", template.attachMdl, sizeof(template.attachMdl));
			if (!template.attachMdl[0])
			{
				LogMessage("Backpack template '%s' missing 'ornament_model' key. Skipping..");
			}

			if (kv.JumpToKey("sounds"))
			{
				LoadSoundArray(kv, "backpack_open", template.sounds[SoundOpen]);
				LoadSoundArray(kv, "backpack_add", template.sounds[SoundAdd]);
				LoadSoundArray(kv, "backpack_wear", template.sounds[SoundWear]);
				LoadSoundArray(kv, "backpack_drop", template.sounds[SoundDrop]);

				kv.GoBack();
			}

			templates.PushArray(template);
			numParsed++;
		}
		while (kv.GotoNextKey());
		kv.GoBack();
	}

	kv.GoBack();

	return numParsed;
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
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				BackpackSound snd;
				kv.GetSectionName(snd.path, sizeof(snd.path));

				if (!snd.path[0])
				{
					continue;
				}

				snd.layers = kv.GetNum(NULL_STRING, 1);
				if (snd.layers < 1) {
					snd.layers = 1;
				} else if (snd.layers > 9) {
					snd.layers = 9;
				}

				sounds.PushArray(snd);
				
			} while (kv.GotoNextKey(false));

			kv.GoBack();
		}

		kv.GoBack();
	}
}

bool GetItemByEntity(int entity, Item reg)
{
	char alias[64];
	GetEntityClassname(entity, alias, sizeof(alias));

	if (StrEqual(alias, "item_ammo_box")) {
		GetEntPropString(entity, Prop_Data, "m_ModelName", alias, sizeof(alias));
	}

	return alias[0] && GetItemByAlias(alias, reg);
}

bool GetItemByAlias(const char[] alias, Item reg)
{
	int idx;
	if (itemLookup.GetValue(alias, idx)) 
	{
		itemRegistry.GetArray(idx, reg);
		return true;
	}

	return false;
}

bool GetItemByID(int itemID, Item reg)
{
	if (itemID < 0 || itemID >= itemRegistry.Length) {
		return false;
	}

	itemRegistry.GetArray(itemID, reg);
	return true;
}

float GetCarriedWeight(int client) 
{
	return RunEntVScriptFloat(client, "GetCarriedWeight()");
}

Action OnBackpackPropDamage(int backpack, int& attacker, int& inflictor, float& damage, int& damagetype)
{
	if ((damagetype & DMG_CLUB || damagetype & DMG_SLASH) && 
		IsValidPlayer(attacker) && 
		!wearingBackpack[attacker] && 
		IsValidEntity(inflictor) && 
		HasEntProp(inflictor, Prop_Send, "m_hOwner") && 
		CanReachBackpack(attacker, backpack))
	{
		int owner = GetEntPropEnt(inflictor, Prop_Send, "m_hOwner");
		if (owner == attacker)
		{
			int idx = backpacks.FindValue(EntIndexToEntRef(backpack), Backpack::propRef);
			if (idx != -1)
			{
				Backpack bp;
				backpacks.GetArray(idx, bp);
				bp.Attach(owner);
				backpacks.SetArray(idx, bp);
			}
		}
	}

	return Plugin_Handled;
}

int owedBackpacks = 0;

void Event_MapReset(Event event, const char[] name, bool dontBroadcast)
{
	owedBackpacks = 0;
	RequestFrame(BeginGivingBackpacks);
}

void BeginGivingBackpacks()
{
	owedBackpacks = cvBackpackCount.IntValue;

	ArrayList candidates = new ArrayList();

	for (int i = 1; i <= MaxClients; i++) 
	{
		if (IsClientInGame(i) && NMRiH_IsPlayerAlive(i))
		{
			candidates.Push(i);
		}
	}

	while (owedBackpacks > 0)
	{
		int maxCandidates = candidates.Length;
		if (maxCandidates < 1)
			break;

		int rnd = GetRandomInt(0, maxCandidates - 1);

		GiveEntityBackpack(candidates.Get(rnd));
		candidates.Erase(rnd);
		owedBackpacks--;
	}

	delete candidates;
}

void GiveEntityBackpack(int entity, int template = -1)
{
	Backpack bp;
	bp.Init(template);
	bp.Attach(entity);
	backpacks.PushArray(bp);
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client && NMRiH_IsPlayerAlive(client) && owedBackpacks > 0)
	{
		GiveEntityBackpack(client);
		owedBackpacks--;
	}
}

public void OnPlayerExtracted(Event event, const char[] name, bool dontBroadcast)
{
	int client = event.GetInt("player_id");
	if (IsValidPlayer(client)) {
		ClientDropBackpack(client);
	}
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client) {
		ClientDropBackpack(client);
	}
}

public void OnClientDisconnect(int client)
{
	ClientDropBackpack(client);
}

void ClientDropBackpack(int client)
{
	if (wearingBackpack[client])
	{
		int idx = backpacks.FindValue(EntIndexToEntRef(client), Backpack::wearerRef);
		if (idx != -1)
		{
			Backpack bp;
			backpacks.GetArray(idx, bp);
			bp.Drop();
			backpacks.SetArray(idx, bp);
		}	
	}
}

/* Taken from Backpack by Ryan */
bool DropFromEntity(int entity, int backpack)
{
	float origin[3], angles[3];

	if (0 < entity <= MaxClients)
	{
		// Hull sweep in direction of player's camera for backpack
		// drop location.
		if (!TraceBackpackPosition(entity, origin, angles))
		{
			PrintToChat(entity, PLUGIN_PREFIX ... "%t", "Invalid Drop Position");
			return false;
		}  
	}
	else
	{
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
		GetEntPropVector(entity, Prop_Data, "m_angRotation", angles);
		origin[2] += 40.0; // Right now it's just zombies, so raise Z a bit
	}

	TeleportEntity(backpack, origin, angles, NULL_VECTOR);
	AcceptEntityInput(backpack, "EnableMotion");
	return true;
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
	angles[0] = 0.0;
	angles[2] = 0.0;

	// Put glowsticks towards dropper.
	//angles[Y] += 180.0;

	return !TR_PointOutsideWorld(pos);
}

bool Trace_BackpackDrop(int entity, int contents_mask)
{
	return entity == 0 || entity > MaxClients;
}

void AddEntityEffects(int entity, int effects)
{
	int curEffects = GetEntProp(entity, Prop_Send, "m_fEffects");
	SetEntProp(entity, Prop_Send, "m_fEffects", curEffects | effects);
}

bool NMRiH_IsPlayerAlive(int client)
{
	return IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_iPlayerState") == 0;
}

public bool TraceFilter_IgnoreOne(int entity, int contentMask, int ignore)
{
	return entity != ignore;
}

void SendBackpackHint(int client, const char[] format, any ...)
{
	char buffer[255];
	VFormat(buffer, sizeof(buffer), format, 3);

	Handle msg = StartMessageOne("KeyHintText", client, USERMSG_BLOCKHOOKS);
	BfWrite bf = UserMessageToBfWrite(msg);
	bf.WriteByte(1); // number of strings, only 1 is accepted
	bf.WriteString(buffer);
	EndMessage();
}

void GetLootForColumn(int column, ArrayList dest)
{
	Item reg;
	int maxWeapons = itemRegistry.Length;
	for (int i = 0; i < maxWeapons; i++)
	{
		itemRegistry.GetArray(i, reg);
		if ((reg.columns & (1 << column)) && reg.spawnAsLoot)
		{
			dest.PushArray(reg);
		}
	}
}

int GetMaxClip1(int weapon)
{
	return RunEntVScriptInt(weapon, "GetMaxClip1()");
}

float GetWeaponWeight(int weapon)
{
	return RunEntVScriptFloat(weapon, "GetWeight()");
}

bool ClientOwnsWeapon(int client, const char[] name)
{
	char classname[64];

	int maxWeapons = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i; i < maxWeapons; i++)
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (weapon != -1) 
		{
			GetEntityClassname(weapon, classname, sizeof(classname));
			if (StrEqual(name, classname)) {
				return true;
			}
		}
	}

	return false;
}

void FreezePlayer(int client)
{
	int curFlags = GetEntProp(client, Prop_Send, "m_fFlags");
	SetEntProp(client, Prop_Send, "m_fFlags", curFlags | 128);
}

void UnfreezePlayer(int client)
{
	int curFlags = GetEntProp(client, Prop_Send, "m_fFlags");
	SetEntProp(client, Prop_Send, "m_fFlags", curFlags & ~128);
}