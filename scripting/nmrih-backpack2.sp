#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <autoexecconfig>
#include <vscript_proxy>

#pragma semicolon 1
#pragma newdecls required

// TODO: Change backpack glow color based on fullness
// TODO: Re-add speed penalty
// TODO: Option to use backpacks while worn
// TODO: Infected clients keep their backpack
// TODO: Helis can drop backpacks
// TODO: Recover backpacks from previous session

#define PLUGIN_PREFIX "[Backpack2] "
#define PLUGIN_DESCRIPTION "Portable inventory boxes"
#define PLUGIN_VERSION "2.0.16"

#define INVALID_USER_ID 0

#define TEMPLATE_RANDOM -1

#define WEAPON_NOT_CARRIED 0
#define MAXENTITIES 2048
#define EF_ITEM_BLINK 0x100

#define MAX_BP_USE_DISTANCE 90.0

#define MAX_TARGETNAME 50
#define MAXPLAYERS_NMRIH 9

#define PROP_PHYS_DEBRIS 4
#define PROP_PHYS_USE_OUTPUT 256

#define GLOWTYPE_GLOW 1
#define GLOWTYPE_BLINK 2

#define MASK_ITEM 0
#define INVALID_ITEM 0
#define INVALID_AMMO -1

#define KEYHINT_TIME 13.0
#define CLIP1_PENDING -2

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
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = "https://github.com/dysphie/nmrih-backpack2"
};

ConVar cvAmmoWeight;
int numStarterBackpacks;

Handle hintUpdateTimer;
ConVar cvItemGlow;

bool runningLevel;

ConVar cvHints;
ConVar cvGlowDist;
ConVar cvBlink;
ConVar cvNpcBackpackChance;
ConVar cvMaxStarterBackpacks;
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
ConVar cvHintsInterval;

ConVar inv_maxcarry;

Cookie hintCookie;

ArrayList templates;
ArrayList backpacks;

StringMap itemLookup;
ArrayList itemRegistry;

bool wearingBackpack[MAXENTITIES+1];
bool isDroppedBackpack[MAXENTITIES+1];
float stopThinkTime[MAXENTITIES+1];
bool usedAmmoBox[MAXENTITIES+1];


int aimedBackpack[MAXPLAYERS_NMRIH+1] = {-1, ...};
bool hintsEnabled[MAXPLAYERS_NMRIH+1];
float hintExpireTime[MAXPLAYERS_NMRIH+1];
bool inFists[MAXPLAYERS_NMRIH+1];
float nextAimTraceTime[MAXPLAYERS_NMRIH+1];

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
	char name[MAX_TARGETNAME];
}

enum struct Backpack
{
	int templateID;			// Template index, usedAmmoBox for sounds, colors, models, etc.

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

	// TODO
	// float GetPercentageFilled(float& slotsPct, float& subSlotsPct)
	// {
	// 	return 0.0;
	// }

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
		if (cvItemGlow.BoolValue)
		{
			DispatchKeyValue(entity, "glowable", "1");
			DispatchKeyValue(entity, "glowblip", "0");
			DispatchKeyValueFloat(entity, "glowdistance", cvGlowDist.FloatValue);
			DispatchKeyValue(entity, "glowcolor", /*isFull ? "255 0 0" :*/ "0 255 0"); // same as item pickup
			RequestFrame(Frame_GlowEntity, EntIndexToEntRef(entity));
		}

		if (cvBlink.BoolValue) {
			AddEntityEffects(entity, EF_ITEM_BLINK);
		}
	}

	bool Attach(int wearer, bool suppressSound = false)
	{
		if (wearingBackpack[wearer]) 
		{
			LogError("Tried to attach backpack to %d, but they already have one", wearer);
			return false;
		}

		if (IsValidEntity(this.wearerRef)) {
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
		SetEntPropString(attached, Prop_Data, "m_iClassname", "backpack_attached");
		
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

			// Sanity check
			if (numDroppedBackpacks < 0)
				numDroppedBackpacks = 0;
		}

		SetVariantString("!activator");
		AcceptEntityInput(attached, "SetAttached", wearer, wearer);

		if (IsValidPlayer(wearer) && AreHintsEnabled(wearer)) 
		{
			// Clear "You can pick up" hints
			EnsureNoHints(wearer, GetTickedTime(), 2.0);
		}

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

		SetEntPropString(dropped, Prop_Data, "m_iClassname", "backpack");

		numDroppedBackpacks++;

		// Sanity check
		int maxBackpacks = backpacks.Length;
		if (numDroppedBackpacks > maxBackpacks) {
			numDroppedBackpacks = maxBackpacks;
		}

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

		if (IsValidPlayer(wearer) && AreHintsEnabled(wearer)) 
		{
			EnsureNoHints(wearer, GetTickedTime(), 2.0);
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

		// EnsureNoHints(client, GetTickedTime());

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
		hintExpireTime[client] = 0.0;
		aimedBackpack[client] = -1;

		UnfreezePlayer(client);
		this.atInterface[client] = false;
		UserMsg_EndUse(client);
	}

	bool AddWeapon(int ammoCount, Item reg, bool suppressSound = false, const char[] name = "")
	{
		for (int i; i < COL_MAX; i++) 
		{
			if (reg.columns & (1 << i) 
				&& this.AddWeaponToColumn(i, ammoCount, reg, suppressSound, name))
			{
				return true;
			}
		}
		return false;
	}

	bool AddWeaponToColumn(int col, int ammoCount, Item reg, bool suppressSound = false, const char[] name = "")
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

				strcopy(stored.name, sizeof(stored.name), name);
				
				if (!suppressSound) {
					this.PlaySound(SoundAdd);
				}

				arr.SetArray(i, stored);

				return true;
			}
		}
		return false;
	}

	bool AddWeaponByEnt(int weapon)
	{
		if (IsValidEntity(this.wearerRef)) 
		{
			LogError("Tried to add weapon (%d) to carried backpack", weapon);
			return false;
		}

		Item reg;
		if (!GetItemByEntity(weapon, reg)) {
			return false;
		}

		// Ignore medical items that have been consumed
		if (IsItemConsumed(weapon)) {
			return false;
		}
		
		int ammoAmt = GetEntProp(weapon, Prop_Send, "m_iClip1");

		char targetname[MAX_TARGETNAME];
		GetEntityTargetname(weapon, targetname, sizeof(targetname));

		if (this.AddWeapon(ammoAmt, reg, _, targetname)) 
		{
			RemoveEntity(weapon);
			return true;
		}

		return false;
	}

	void AddAmmoByEnt(int ammoBox, bool suppressSound = false, bool allowStacking = true)
	{
		if (IsValidEntity(this.wearerRef)) 
		{
			LogError("Tried to add ammo box (%d) to carried backpack", ammoBox);
			return;
		}

		Item reg;
		if (!GetItemByEntity(ammoBox, reg)) {
			return;
		}

		int ammoCount = GetEntProp(ammoBox, Prop_Data, "m_iAmmoCount");
		int leftover = this.AddAmmo(ammoCount, reg, suppressSound, allowStacking);

		if (leftover < ammoCount) 
		{
			if (!leftover) {
				RemoveEntity(ammoBox);
			}
			else {
				SetEntProp(ammoBox, Prop_Data, "m_iAmmoCount", leftover);
			}
		}
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
				this.AddWeaponToColumn(column, CLIP1_PENDING, reg, true);
			}
			else if (reg.category == CAT_AMMO)
			{
				int minAmmo = reg.capacity * cvAmmoLootMinPct.IntValue / 100;
				if (minAmmo < 1) { 
					minAmmo = 1; 
				}

				int maxAmmo = reg.capacity * cvAmmoLootMaxPct.IntValue / 100;
				int rndClip = GetRandomInt(minAmmo, maxAmmo) * cvAmmoMultiplier.IntValue;
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
				curAmmo = this.AddAmmoRecursively(arr, itemID, curAmmo, maxAmmo);
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
		this.items[column].GetArray(index, stored);

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
				PrintCenterText(client, "#NMRiH_InventoryBox_OwnsItem");
				return false;
			}

			int weapon = CreateEntityByName(reg.alias);
			if (weapon == -1 || !DispatchSpawn(weapon)) {
				return false;
			}

			// Items spawning as loot don't have their ammo count computed
			// until the player tries to take them out, for optimization
			if (stored.ammoCount == CLIP1_PENDING)
			{
				int rndClip = 1;
				int maxClip = GetMaxClip1(weapon);
				if (maxClip != -1)
				{
					int min = RoundToNearest(maxClip * cvAmmoLootMinPct.FloatValue / 100);
					int max = RoundToNearest(maxClip * cvAmmoLootMaxPct.FloatValue / 100);
					rndClip = GetRandomInt(min, max);	
				}

				stored.ammoCount = rndClip;
			}

			int leftoverWeight = inv_maxcarry.IntValue - GetCarriedWeight(client);
			if (leftoverWeight < GetWeaponWeight(weapon))
			{
				RemoveEntity(weapon);
				PrintCenterText(client, "#NMRiH_InventoryBox_CantCarry");
				return false;
			}

			SetEntProp(weapon, Prop_Send, "m_iClip1", stored.ammoCount);
			SetEntityTargetname(weapon, stored.name);

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

			int leftoverWeight = inv_maxcarry.IntValue - GetCarriedWeight(client);
			if (leftoverWeight <= 0) 
			{
				PrintCenterText(client, "#NMRiH_InventoryBox_CantCarry");
				return false;
			}

			int canTake;
			int ammoWeight = cvAmmoWeight.IntValue;
			if (ammoWeight <= 0)
			{
				canTake = stored.ammoCount;
			}
			else
			{
				canTake = leftoverWeight / ammoWeight;			
				if (canTake > stored.ammoCount)
					canTake = stored.ammoCount;
			}
	
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
		if (wearer == -1) 
		{
			numDroppedBackpacks--;
			
			// Sanity check
			if (numDroppedBackpacks < 0)
				numDroppedBackpacks = 0;

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
	HookPlayer(client);
}

public void OnPluginStart()
{
	//AddCommandListener(OnDropWeapon, "+dropweapon");

	LoadTranslations("backpack2.phrases");
	LoadTranslations("common.phrases");

	hintCookie = new Cookie("backpack2_hints", "Enables or disables backpack screen hints", CookieAccess_Protected);

	HookEvent("player_spawn", OnPlayerSpawn);
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("player_extracted", OnPlayerExtracted);
	HookEvent("nmrih_reset_map", OnMapReset);
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

	cvItemGlow = FindConVar("sv_item_glow");
	cvAmmoWeight = FindConVar("inv_ammoweight");

	AutoExecConfig_SetFile("plugin.backpack2");

	cvRightLootMin = AutoExecConfig_CreateConVar("sm_backpack_loot_ammo_min", "0", 
		"Minimum ammo boxes to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvRightLootMax = AutoExecConfig_CreateConVar("sm_backpack_loot_ammo_max", "4", 
		"Maximum ammo boxes to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvAmmoLootMinPct = AutoExecConfig_CreateConVar("sm_backpack_loot_ammo_min_pct", "40", 
		"Minimum fill percentage for ammo boxes spawned as backpack loot", _, true, 1.0);

	cvAmmoLootMaxPct = AutoExecConfig_CreateConVar("sm_backpack_loot_ammo_max_pct", "100", 
		"Maximum fill percentage for ammo boxes spawned as backpack loot", _, true, 1.0);

	cvMiddleLootMin = AutoExecConfig_CreateConVar("sm_backpack_loot_gear_min", "0", 
		"Minimum gear items to place in backpacks spawned as loot", _, true, 0.0, true, 4.0);

	cvMiddleLootMax = AutoExecConfig_CreateConVar("sm_backpack_loot_gear_max", "1", 
		"Maximum gear items to place in backpacks spawned as loot", _, true, 0.0, true, 4.0);

	cvLeftLootMin = AutoExecConfig_CreateConVar("sm_backpack_loot_weapon_min", "0", 
		"Minimum weapons to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvLeftLootMax = AutoExecConfig_CreateConVar("sm_backpack_loot_weapon_max", "2", 
		"Maximum weapons to place in backpacks spawned as loot", _, true, 0.0, true, 8.0);

	cvHints = AutoExecConfig_CreateConVar("sm_backpack_show_hints", "1",
		"Whether to show screen hints on how to use backpacks");
	hintsEnabled[0] = cvHints.BoolValue;
	cvHints.AddChangeHook(OnHintsCvarChanged);

	CreateConVar("backpack2_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION,
    	FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	cvHintsInterval = AutoExecConfig_CreateConVar("sm_backpack_hints_interval", "1.0",
		"Rate in seconds at which hints are updated. " ...
		"Lower values result in more accurate hints but increase CPU usage");
	cvHintsInterval.AddChangeHook(OnHintsIntervalCvarChanged);

	cvAmmoMultiplier = AutoExecConfig_CreateConVar("sm_backpack_ammo_stack_limit", "4",
		"Number of ammo pickups that can be stored per ammo slot. 0 means infinite.");

	cvMaxStarterBackpacks = AutoExecConfig_CreateConVar("sm_backpack_count", "1",
	 "Number of backpacks to create at round start. Won't create more backpacks than there are players.");

	cvBackpackColorize = AutoExecConfig_CreateConVar("sm_backpack_colorize", "1",
	 "Randomly colorize backpacks to help distinguish them.");
	cvBackpackColorize.AddChangeHook(OnColorizeCvarChanged);

	cvGlowDist = AutoExecConfig_CreateConVar("sm_backpack_glow_distance", "90", 
		"Glow backbacks in this range of the player");

	cvBlink = AutoExecConfig_CreateConVar("sm_backpack_blink", "0", "Whether dropped backpacks pulse their brightness");
	cvBlink.AddChangeHook(OnBlinkCvarChanged);

	cvNpcBackpackChance = AutoExecConfig_CreateConVar("sm_backpack_zombie_spawn_chance", "0.005",
	 "Chance for a zombie to spawn with a backpack. Set to zero or negative to disable");

	AutoExecConfig_ExecuteFile();

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

	SetCookieMenuItem(OnBackpackCookiesMenu, hintCookie, "Backpack Hints");

	// Lateload support
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			ResetPlayer(i);
			HookPlayer(i);

			if (AreClientCookiesCached(i)) {
				CacheHintPref(i);
			}
		}
	}	

	InitializeHints();
}

void OnHintsIntervalCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	InitializeHints();
}

void OnHintsCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	hintsEnabled[0] = cvHints.BoolValue;
}

void OnBlinkCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Backpack bp;
	int max = backpacks.Length;
	for (int i; i < max; i++)
	{
		backpacks.GetArray(i, bp);
		
		if (!bp.IsWorn() && IsValidEntity(bp.propRef)) 
		{
			if (convar.BoolValue) {
				AddEntityEffects(bp.propRef, EF_ITEM_BLINK);	
			}
			else {
				RemoveEntityEffects(bp.propRef, EF_ITEM_BLINK);	
			}
		}
	}
}

void OnColorizeCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Backpack bp;
	int max = backpacks.Length;
	for (int i; i < max; i++)
	{
		backpacks.GetArray(i, bp);
		
		if (!bp.IsWorn() && IsValidEntity(bp.propRef)) 
		{
			if (convar.BoolValue) 
			{
				SetEntityRenderMode(bp.propRef, RENDER_TRANSCOLOR);
				SetEntityRenderColor(bp.propRef, bp.color[0], bp.color[1], bp.color[2], 255);	
			}
			else
			{
				SetEntityRenderMode(bp.propRef, RENDER_NORMAL);
				SetEntityRenderColor(bp.propRef, 255, 255, 255, 255);
			}

		}
	}	
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
	numStarterBackpacks = 0;
	runningLevel = false;
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
	int bpEnt = StringToInt(cmdIndex);

	Backpack bp;
	int bpID = GetBackpackFromEntity(bpEnt, bp);
	if (bpID == -1)
	{
		UserMsg_EndUse(client); // Prevent user from getting stuck
		return Plugin_Continue;
	}

	bp.EndUse(client);
	backpacks.SetArray(bpID, bp);

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
	int bpEnt = StringToInt(cmdIndex);

	Backpack bp;
	int idx = GetBackpackFromEntity(bpEnt, bp);
	if (idx == -1)
	{
		UserMsg_EndUse(client); // Prevent user from getting stuck
		return Plugin_Continue;
	}

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

Action OnBackpackPropUse(int bpEnt, int activator, int caller, UseType type, float value)
{
	if (!IsValidPlayer(caller)) {
		return Plugin_Continue;
	}

	Backpack bp;
	int bpID = GetBackpackFromEntity(bpEnt, bp);

	if (bpID != -1) 
	{
		bp.Use(caller);
		backpacks.SetArray(bpID, bp);
	}
	
	return Plugin_Handled;
}

bool IsValidPlayer(int client)
{
	return 0 < client <= MaxClients && IsClientInGame(client);
}

public void OnMapStart()
{
	numDroppedBackpacks = 0;
	runningLevel = true;
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
	if (!runningLevel || !IsValidEdict(entity))
		return;

	if (StrEqual(classname, "item_ammo_box"))
	{
		SDKHook(entity, SDKHook_Use, OnAmmoBoxUse);
		SDKHook(entity, SDKHook_SpawnPost, OnAmmoBoxSpawned);
	}
	else if (IsBackpackableNPC(classname)) {
		MakeLootZombie(entity);
	}
}

Action OnAmmoBoxUse(int ammobox, int activator, int caller, UseType type, float value)
{
	if (0 < caller <= MaxClients) {
		usedAmmoBox[ammobox] = true;
	}

	return Plugin_Continue;
}

public void MakeLootZombie(int zombie)
{
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
	usedAmmoBox[ammobox] = false;

	if (numDroppedBackpacks <= 0) {
		return;
	}

	stopThinkTime[ammobox] = GetTickedTime() + 1.5;
	RequestFrame(OnAmmoFallThink, EntIndexToEntRef(ammobox));
}

void OnWeaponDropped(int client, int weapon)
{
	if (!IsValidPlayer(client) || !IsValidEdict(weapon)) {
		return;
	}

	if (numDroppedBackpacks <= 0) {
		return;
	}

	stopThinkTime[weapon] = GetTickedTime() + 1.5;
	RequestFrame(OnWeaponFallThink, EntIndexToEntRef(weapon));
}

void OnWeaponSwitchPost(int client, int weapon)
{
	if (IsValidPlayer(client) && IsValidEdict(weapon)) 
	{
		char classname[10];
		GetClientWeapon(client, classname, sizeof(classname));
		if (StrEqual(classname, "me_fists")) 
		{
			inFists[client] = true;
			return;
		}
	}

	inFists[client] = false;
	return;
}

void OnAmmoFallThink(int ammoRef)
{
	if (numDroppedBackpacks <= 0) {
		return;
	}

	int ammobox = EntRefToEntIndex(ammoRef);
	if (!IsValidEdict(ammobox)) {
		return;
	}

	// Fix duplication exploit where players can drop ammo, press E to pick it up and still 
	// have it collide with a backpack afterwards, making it end up in both inventory and backpack
	if (usedAmmoBox[ammobox]) {
		return;
	}

	if (!IsItemFalling(ammobox)) {
		return;
	}
	
	float pos[3];
	GetEntPropVector(ammobox, Prop_Data, "m_vecOrigin", pos);

	// float mins[3];
	// float maxs[3];
	// GetEntityMins(ammobox, mins);
	// GetEntityMaxs(ammobox, maxs);
	static float mins[3] = {-8.0, ...};
	static float maxs[3] = {8.0, ...}; 

	int bpEnt = GetBackpackEntInBox(pos, mins, maxs);
	if (bpEnt != -1) 
	{
		Backpack bp;
		int bpID = GetBackpackFromEntity(bpEnt, bp);
		if (bpID != -1)
		{
			bp.AddAmmoByEnt(ammobox);
			backpacks.SetArray(bpID, bp);
		} 	
	}
	else {
		RequestFrame(OnAmmoFallThink, ammoRef);	
	}
}

void OnWeaponFallThink(int weaponRef)
{
	if (numDroppedBackpacks <= 0) {
		return;
	}

	int weapon = EntRefToEntIndex(weaponRef);
	if (!IsValidEdict(weapon) || !IsItemFalling(weapon) || !IsDroppedWeapon(weapon)) {
		return;
	}
	
	float pos[3];
	GetEntPropVector(weapon, Prop_Data, "m_vecOrigin", pos);

	// float mins[3], maxs[3];
	// GetEntityMins(weapon, mins);
	// GetEntityMaxs(weapon, maxs);

	static float mins[3] = {-8.0, ...};
	static float maxs[3] = {8.0, ...}; 

	int bpEnt = GetBackpackEntInBox(pos, mins, maxs);
	if (bpEnt != -1) 
	{
		Backpack bp;
		int bpID = GetBackpackFromEntity(bpEnt, bp);
		if (bpID != -1 && bp.AddWeaponByEnt(weapon))
		{
			backpacks.SetArray(bpID, bp);
		}
	}
	else {
		RequestFrame(OnWeaponFallThink, weaponRef);
	}
}

int GetBackpackEntInBox(float pos[3], float mins[3], float maxs[3])
{
	TR_TraceHullFilter(pos, pos, mins, maxs, MASK_ALL, TraceFilter_DroppedBackpacks);

	if (TR_DidHit())
	{
		// Box(pos, mins, maxs, 0.1, GREEN);
		int hit = TR_GetEntityIndex();
		if (IsValidEdict(hit) && isDroppedBackpack[hit]) 
		{
			return hit;
		}
	}
	
	//Box(pos, mins, maxs, 0.1, RED);
	return -1;
}

bool TraceFilter_DroppedBackpacks(int entity, int contentsMask)
{
	return IsValidEdict(entity) && isDroppedBackpack[entity];
}

bool IsItemFalling(int item)
{
	return GetTickedTime() < stopThinkTime[item];
}

bool IsDroppedWeapon(int weapon)
{
	return GetEntProp(weapon, Prop_Send, "m_iState") == WEAPON_NOT_CARRIED;
}

// void GetEntityMins(int entity, float mins[3])
// {
// 	GetEntPropVector(entity, Prop_Data, "m_vecSurroundingMins", mins);
// }

// void GetEntityMaxs(int entity, float maxs[3])
// {
// 	GetEntPropVector(entity, Prop_Data, "m_vecSurroundingMaxs", maxs);
// }

bool ProcessButtons(int client, int& buttons, int wanted)
{
	if (buttons & wanted && !(GetEntProp(client, Prop_Data, "m_nOldButtons") & wanted))
	{
		buttons &= ~wanted;
		return true;
	}

	return false;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (wearingBackpack[client])
	{
		if (inFists[client] && ProcessButtons(client, buttons, IN_ALT2)) 
		{
			ClientDropBackpack(client);
		}
	}

	// Allow instant pickup with right click
	//	NOTE: Disabled, kinda ugly with client pred
	// else if (ProcessButtons(client, buttons, IN_ATTACK2))
	// {
	// 	//buttons &= ~IN_ATTACK;
	// 	aimedBackpack[client] = GetAimBackpack(client);
	// 	if (aimedBackpack[client] != -1)
	// 	{
	// 		Backpack bp;
	// 		int bpID = GetBackpackFromEntity(aimedBackpack[client], bp);
	// 		if (bpID != -1)
	// 		{
	// 			bp.Attach(client);
	// 			backpacks.SetArray(bpID, bp);
	// 		}	
	// 	}
	// }

	return Plugin_Continue;
}

int GetBackpackFromEntity(int entity, Backpack bp)
{
	int bpID = BackpackEntToBackpackID(entity);
	if (bpID != -1) {
		backpacks.GetArray(bpID, bp);
	}
	return bpID;
}

int BackpackEntToBackpackID(int entity)
{
	return backpacks.FindValue(EntIndexToEntRef(entity), Backpack::propRef);
}

public void OnEntityDestroyed(int entity)
{
	if (!IsValidEdict(entity)) {
		return;
	}
	
	if (isDroppedBackpack[entity])
	{
		int bpID = BackpackEntToBackpackID(entity);
		if (bpID != -1)
		{
			DeleteBackpack(bpID);    
		}
		isDroppedBackpack[entity] = false;
	}

	if (wearingBackpack[entity])
	{
		int wearerRef = EntIndexToEntRef(entity);
		int bpID = backpacks.FindValue(wearerRef, Backpack::wearerRef);
		if (bpID != -1)
		{
			DeleteBackpack(bpID);
		}

		wearingBackpack[entity] = false;
	}
	stopThinkTime[entity] = 0.0;
	usedAmmoBox[entity] = false;
}

int GetAimBackpack(int client) 
{
	if (numDroppedBackpacks <= 0) {
		return -1;
	}
	
	float startPos[3]; 
	float endPos[3];
	GetClientEyePosition(client, startPos);
	GetClientEyeAngles(client, endPos);

	ForwardVector(startPos, endPos, MAX_BP_USE_DISTANCE, endPos);

	TR_TraceRayFilter(startPos, endPos, MASK_SHOT, RayType_EndPoint, TraceFilter_DroppedBackpacks);

	if (TR_DidHit()) 
	{
		int hitEnt = TR_GetEntityIndex();
		if (hitEnt > 0) {
			return hitEnt;
		}
	}

	return -1;
}

void ForwardVector(const float vPos[3], const float vAng[3], float fDistance, float vReturn[3])
{
	float vDir[3];
	GetAngleVectors(vAng, vDir, NULL_VECTOR, NULL_VECTOR);
	vReturn = vPos;
	vReturn[0] += vDir[0] * fDistance;
	vReturn[1] += vDir[1] * fDistance;
	vReturn[2] += vDir[2] * fDistance;
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
	PrintToServer(PLUGIN_PREFIX ... "Loaded %d backpack templates", ParseTemplates(kv));

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

int GetCarriedWeight(int client) 
{
	return RunEntVScriptInt(client, "GetCarriedWeight()");
}

Action OnBackpackPropDamage(int backpack, int& attacker, int& inflictor, float& damage, int& damagetype)
{
	Action result = Plugin_Handled; // We never take damage

	// Must be a melee attack
	if (!(damagetype & DMG_CLUB) && !(damagetype & DMG_SLASH)) {
		return result;
	}

	// Must be damage done by a player
	if (!IsValidPlayer(attacker) || wearingBackpack[attacker] || !IsValidEntity(inflictor)) {
		return result;
	}

	// Must be the clients active weapon
	if (inflictor != GetActiveWeapon(attacker)) {
		return result;
	}

	// Out of range
	if (!CanReachBackpack(attacker, backpack)) {
		return result;
	}
	
	Backpack bp;
	int idx = GetBackpackFromEntity(backpack, bp);
	if (idx != -1)
	{
		bp.Attach(attacker);
		backpacks.SetArray(idx, bp);
	}

	return Plugin_Handled;
}

void OnMapReset(Event event, const char[] name, bool dontBroadcast)
{
	DeleteAllBackpacks();
	numStarterBackpacks = 0;
	// Players haven't respawned yet, wait a frame
	RequestFrame(Frame_GiveBackpackAll);
}

void Frame_GiveBackpackAll()
{
	int maxBackpacks = cvMaxStarterBackpacks.IntValue;
	if (numStarterBackpacks >= maxBackpacks) {
		return;
	}

	// Pick backpack wearers evenly 
	ArrayList candidates = new ArrayList();

	for (int i = 1; i <= MaxClients; i++) 
	{
		if (IsClientInGame(i) && NMRiH_IsPlayerAlive(i) && !wearingBackpack[i])
		{
			candidates.Push(i);
		}
	}

	while (numStarterBackpacks < maxBackpacks && candidates.Length > 0)
	{
		int rnd = GetRandomInt(0, candidates.Length - 1);
		GiveEntityBackpack(candidates.Get(rnd)); // TODO: return bool and check
		candidates.Erase(rnd);
		numStarterBackpacks++;
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

void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !NMRiH_IsPlayerAlive(client)  || wearingBackpack[client]) {
		return;
	}

	// Check if we still owe starter backpacks, if so, give one away
	if (numStarterBackpacks < cvMaxStarterBackpacks.IntValue) 
	{
		GiveEntityBackpack(client);
		numStarterBackpacks++;
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
	if (client) 
	{
		// TODO: Make infected survivors keep their backpack
		ClientDropBackpack(client);
	}
}

// bool DiedWhileInfected(int client)
// {
// 	return GetEntPropFloat(client, Prop_Send, "m_flInfectionTime") != -1.0;
// }

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

void EnsureNoHints(int client, float curTime, float till = 0.0)
{
	if (curTime >= hintExpireTime[client]) {
		return;
	}

	KeyHintText(client, "");
	hintExpireTime[client] = curTime + till;
}

void ShowBackpackHint(int client, float curTime, const char[] format, any ...)
{
	if (curTime < hintExpireTime[client]) {
		return;
	}

	SetGlobalTransTarget(client);
	char buffer[255];
	VFormat(buffer, sizeof(buffer), format, 4);
	KeyHintText(client, buffer);

	hintExpireTime[client] = curTime + KEYHINT_TIME;
}

Action Timer_UpdateHints(Handle timer)
{
	if (!hintsEnabled[0]) 
	{
		return Plugin_Continue;
	}

	float curTime = GetTickedTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!hintsEnabled[i] || !IsClientInGame(i) || !NMRiH_IsPlayerAlive(i)) 
		{
			continue;
		}

		if (wearingBackpack[i]) 
		{
			if (inFists[i]) 
			{
				ShowBackpackHint(i, curTime,  "%T", "Hint You Can Drop", i);
			} 
			else 
			{
				EnsureNoHints(i, curTime);
			}
		}
		else 
		{
			int bpEnt = GetAimBackpack(i);
			if (bpEnt != -1) 
			{
				if (aimedBackpack[i] == -1) 
				{
					ShowBackpackHint(i, curTime, "%T", "Hint You Can Pick Up", i);	
				}
			}

			else
			{
				EnsureNoHints(i, curTime);
			}

			aimedBackpack[i] = bpEnt;
		}
	}

	return Plugin_Continue;
}

void KeyHintText(int client, const char[] text)
{	
	Handle msg = StartMessageOne("KeyHintText", client, USERMSG_BLOCKHOOKS);
	BfWrite bf = UserMessageToBfWrite(msg);
	bf.WriteByte(1); // number of strings, only 1 is accepted
	bf.WriteString(text);
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

int GetWeaponWeight(int weapon)
{
	return RunEntVScriptInt(weapon, "GetWeight()");
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

void SetEntityTargetname(int entity, const char[] name)
{
	SetEntPropString(entity, Prop_Data, "m_iName", name);	
}

int GetEntityTargetname(int entity, char[] buffer, int maxlen)
{
	return GetEntPropString(entity, Prop_Data, "m_iName", buffer, maxlen);
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	ResetPlayer(client);
	return true;
}

public void OnClientCookiesCached(int client)
{
	CacheHintPref(client);
}

void CacheHintPref(int client)
{
	char value[11];
	hintCookie.Get(client, value, sizeof(value));
	hintsEnabled[client] = !value[0] || value[0] == '1';
}

void OnBackpackCookiesMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlen, "%T", "Backpack Settings", client);
	}
	else
	{
		ShowHintCookieMenu(client);
	}
}

void ShowHintCookieMenu(int client)
{
	Menu menu = new Menu(OnHintCookieMenu);

	char buffer[255];
	FormatEx(buffer, sizeof(buffer), "%T", "Backpack Settings", client);

	menu.SetTitle(buffer);

	FormatEx(buffer, sizeof(buffer), "%T", 
		hintsEnabled[client] ? "Hints Enabled" : "Hints Disabled", 
		client);

	menu.AddItem("", buffer);
	menu.Display(client, MENU_TIME_FOREVER);
}

int OnHintCookieMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End) 
	{
		delete menu;
	}
	else if (action == MenuAction_Select) 
	{
		hintsEnabled[param1] = !hintsEnabled[param1];

		if (!hintsEnabled[param1]) {
			EnsureNoHints(param1, GetTickedTime());
		}

		if (AreClientCookiesCached(param1))
		{
			char buffer[11];
			FormatEx(buffer, sizeof(buffer), "%d", hintsEnabled[param1]);
			hintCookie.Set(param1, buffer);
		}

		ShowHintCookieMenu(param1);
	}

	return 0;
}

void RemoveEntityEffects(int entity, int effects)
{
    int curEffects = GetEntProp(entity, Prop_Send, "m_fEffects");
    SetEntProp(entity, Prop_Send, "m_fEffects", curEffects & ~effects);
}

bool AreHintsEnabled(int client)
{
	// global (set by cvar) + local (set by cookie)
	return hintsEnabled[0] && hintsEnabled[client];
}

void HookPlayer(int client)
{
	SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDropped);
	SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);

	int weapon = GetActiveWeapon(client);
	OnWeaponSwitchPost(client, weapon);
}

int GetActiveWeapon(int client)
{
	return GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
}

void ResetPlayer(int client)
{
	aimedBackpack[client] = -1;
 	hintExpireTime[client] = 0.0;
	inFists[client] = false;
	hintsEnabled[client] = true;
	nextAimTraceTime[client] = 0.0;
}

void InitializeHints()
{
	delete hintUpdateTimer;
	hintUpdateTimer = CreateTimer(cvHintsInterval.FloatValue, Timer_UpdateHints, _, TIMER_REPEAT);
}

bool IsItemConsumed(int item)
{
	return HasEntProp(item, Prop_Send, "_applied") &&
		GetEntProp(item, Prop_Send, "_applied") != 0;
}