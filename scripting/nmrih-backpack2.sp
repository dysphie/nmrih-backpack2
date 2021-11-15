#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#pragma semicolon 1
#pragma newdecls required

// FIXME: Item trace hulls are not clipped
// FIXME: Zombies can drop weapons at 0 0 0 when they receive a backpack
// FIXME: Sanity checks everywhere!
// TODO: Ensure players can't get stuck in the supply crate interface

#define PLUGIN_PREFIX "[Backpack2] "

#define SUPPLY_MAX_WEAPONS 8
#define SUPPLY_MAX_GEAR 4
#define SUPPLY_MAX_AMMO 8

#define MASK_WIP 0

#define INVALID_USER_ID 0

#define DEBUG

#define TEMPLATE_RANDOM -1

#define WEIGHT_PER_AMMO 5
#define WEAPON_NOT_CARRIED 0
#define MAXENTITIES 2048
#define EF_ITEM_BLINK 0x100

#define MAX_BP_USE_DISTANCE 90.0

#define NONE 0
#define WEAPON 1
#define GEAR 2
#define AMMO 3

#define MAXPLAYERS_NMRIH 9

#define PROP_PHYS_DEBRIS 4
#define PROP_PHYS_USE_OUTPUT 256

#define GLOWTYPE_GLOW 1
#define GLOWTYPE_BLINK 2

#define MASK_ITEM 0
#define INVALID_ITEM_ID 0
#define INVALID_AMMO_ID -1

public Plugin myinfo = {
	name        = "[NMRiH] Backpack2",
	author      = "Dysphie",
	description = "Portable inventory boxes",
	version     = "0.0.1willexplode",
	url         = ""
};

enum
{
	CFG_DEF = -1,
	CFG_NO,
	CFG_YES
}

bool optimize;

ConVar cvOptimize;
ConVar cvHints;
ConVar cvGlowType;
ConVar cvGlowBlip;
ConVar cvGlowDist;
ConVar cvNpcBackpackChance;
ConVar cvBackpackCount;
ConVar cvAmmoMultiplier;
ConVar cvBackpackColorize;

ConVar cvAmmoLootMin;
ConVar cvAmmoLootMax;
ConVar cvAmmoLootMinPct;
ConVar cvAmmoLootMaxPct;
ConVar cvGearLootMin;
ConVar cvGearLootMax;
ConVar cvWeaponLootMin;
ConVar cvWeaponLootMax;

Cookie hintCookie;

ArrayList templates = null;
ArrayList backpacks = null;

ConVar sv_zombie_crawler_health = null;
ConVar inv_maxcarry = null;

StringMap itemLookup = null;

ArrayList itemRegistry = null;

bool wasLookingAtBackpack[MAXPLAYERS_NMRIH+1] = {false, ...};
float nextHintTime[MAXPLAYERS_NMRIH+1] = {-1.0, ...};
bool wearingBackpack[MAXENTITIES+1] = {false, ...};
bool isDroppedBackpack[MAXENTITIES+1] = {false, ...};
float stopThinkTime[MAXENTITIES+1] = {-1.0, ...};

bool used[MAXENTITIES+1] = { false, ...};

int MaxEntities = 0;
int numDroppedBackpacks = 0; // FIXME: Prolly desync atm

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
	int weaponLimit;
	int gearLimit;
	int ammoLimit;

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

	ArrayList weapons;		// List of stored weapons and their ammo count
	ArrayList gears;		// List of stored weapons and their ammo count
	ArrayList ammos;			

	int atInterface[MAXPLAYERS_NMRIH+1];    // True if player index is likely browsing the backpack
											// Must verify with in-game check

	int color[3];			// Unique color to distinguish from other backpacks (tint and glow)

	// FIXME: Always selecting the same id?
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

		this.weapons = new ArrayList(sizeof(StoredItem));
		for (int i; i < template.weaponLimit; i++) {
			this.weapons.PushArray(blank);
		}

		this.gears = new ArrayList(sizeof(StoredItem));
		for (int i; i < template.gearLimit; i++) {
			this.gears.PushArray(blank);
		}

		this.ammos = new ArrayList(sizeof(StoredItem));
		for (int i; i < template.ammoLimit; i++) {
			this.ammos.PushArray(blank);
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

	void AddRandomAmmoBoxes(int count)
	{
		for (int i; i < count; i++)
		{
			ArrayList candidates = new ArrayList(sizeof(Item));
			GetLootOfCategory(AMMO, candidates);

			int rnd = GetRandomInt(0, candidates.Length - 1);

			Item ammo;
			candidates.GetArray(rnd, ammo);

			int minAmmo = ammo.capacity * cvAmmoLootMinPct.IntValue / 100;
			if (minAmmo < 1) { 
				minAmmo = 1; 
			}

			int maxAmmo = ammo.capacity * cvAmmoLootMaxPct.IntValue / 100;
			int rndClip = GetRandomInt(minAmmo, maxAmmo);

			this.AddItem(rndClip, ammo, true, false);

			delete candidates;
		}
	}

	void ShuffleContents()
	{
		this.weapons.Sort(Sort_Random, Sort_Integer);
		this.gears.Sort(Sort_Random, Sort_Integer);
		this.ammos.Sort(Sort_Random, Sort_Integer);
	}

	void AddRandomWeapons(int count, int category)
	{
		// Get candidate weapons
		ArrayList weapons = new ArrayList(sizeof(Item));
		GetLootOfCategory(category, weapons);

		// For each available slot, get a random weapon and ammo count
		for (int i; i < count; i++)
		{
			int rnd = GetRandomInt(0, weapons.Length - 1);    

			Item reg;
			weapons.GetArray(rnd, reg);

			int weapon = CreateEntityByName(reg.alias);
			DispatchSpawn(weapon);

			int rndClip = 0;
			int maxClip = GetMaxClip1(weapon);
			if (maxClip > 0)
			{
				int min = RoundToNearest(maxClip * cvAmmoLootMinPct.FloatValue / 100);
				int max = RoundToNearest(maxClip * cvAmmoLootMaxPct.FloatValue / 100);
				rndClip = GetRandomInt(min, max);	
			}

			// if we couldn't fit this, backpack is full, stop
			if (this.AddItem(rndClip, reg, true) != 0) {
				break;
			}

			RemoveEntity(weapon);
		}

		delete weapons;
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

		// fixme
		//FreezePlayer(client);
		this.PlaySound(SoundOpen);

		Handle msg = StartMessageOne("ItemBoxOpen", client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteShort(dropped);

		int i = 0;
		int max = this.weapons.Length;
		for (; i < max; i++) {
			bf.WriteShort(this.weapons.Get(i, StoredItem::id));
		}

		for (; i < 8; i++) {
			bf.WriteShort(INVALID_ITEM_ID);
		}

		i = 0;
		max = this.gears.Length;
		for (; i < max; i++) {
			bf.WriteShort(this.gears.Get(i, StoredItem::id));
		}

		for (; i < 4; i++) {
			bf.WriteShort(INVALID_ITEM_ID);
		}	

		i = 0;
		max = this.ammos.Length;
		for (; i < max; i++) {
			bf.WriteShort(this.ammos.Get(i, StoredItem::id));
		}

		for (; i < 8; i++) {
			bf.WriteShort(INVALID_ITEM_ID);
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
		this.atInterface[client] = false;
		UserMsg_EndUse(client);
	}

	int AddItem(int ammoCount, Item reg, bool suppressSound = false, bool allowStacking = true)
	{
		switch (reg.category)
		{
			case WEAPON, GEAR:
			{
				ArrayList arr = reg.category == WEAPON ? this.weapons : this.gears;
				int maxItems = arr.Length;

				for (int i = 0; i < maxItems; i++)
				{
					StoredItem stored;
					arr.GetArray(i, stored);

					if (stored.id == INVALID_ITEM_ID)
					{
						stored.id = reg.id;
						stored.ammoCount = ammoCount;
						
						if (!suppressSound) {
							this.PlaySound(SoundAdd);
						}

						arr.SetArray(i, stored);
						return 0;
					}
				}	
			}
			case AMMO:
			{
				int fullCapacity = RoundToNearest(reg.capacity * cvAmmoMultiplier.FloatValue);
				if (fullCapacity <= 0) {
					fullCapacity = cellmax;
				}
				
				int leftover = this.AddAmmoRecursively(reg.id, ammoCount, fullCapacity, allowStacking);

				if (!suppressSound && leftover < ammoCount) {
					this.PlaySound(SoundAdd);
				}

				return leftover;
			}
		}

		return ammoCount;
	}

	int AddAmmoRecursively(int itemID, int curAmmo, int maxAmmo, bool allowStacking = true)
	{
		int bestSlot = -1;
		int bestIntake = -1;

		for (int i = 0; i < this.ammos.Length; i++)
		{       
			StoredItem stored;
			this.ammos.GetArray(i, stored);

			if (stored.id == itemID && allowStacking)
			{
				// We choose this slot if our best slot is undefined or empty
				// or it can hold more ammo than the best slot
				if (bestSlot == -1 || this.ammos.Get(bestSlot, StoredItem::id) == INVALID_ITEM_ID)
				{
					int intake = maxAmmo - stored.ammoCount;
					if (intake && intake > bestIntake)
					{
						bestSlot = i;
						bestIntake = intake;        
					}
				}
			}
			else if (stored.id == INVALID_ITEM_ID && bestSlot == -1)
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
			this.ammos.GetArray(bestSlot, addTo);

			curAmmo -= bestIntake;
			addTo.ammoCount += bestIntake;
			addTo.id = itemID;

			this.ammos.SetArray(bestSlot, addTo);

			// Don't take more ammo than we have
			if (curAmmo < 0)
			{
				curAmmo = 0;
			}
			else if (curAmmo > 0)
			{
				this.AddAmmoRecursively(itemID, curAmmo, maxAmmo);
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

	bool TakeItem(int index, int category, int client)
	{
		if (!CanReachBackpack(client, this.propRef)) 
		{
			this.EndUse(client);
			return false;
		}

		// TODO: Check weight of weapon plus its ammo
		if (category == WEAPON || category == GEAR)
		{
			ArrayList arr = category == WEAPON ? this.weapons : this.gears;

			StoredItem stored;
			arr.GetArray(index, stored);

			Item reg;
			if (!GetItemByID(stored.id, reg)) {
				return false;
			}

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

			stored.id = INVALID_ITEM_ID;
			stored.ammoCount = 0;
			arr.SetArray(index, stored);

			this.TakeItemUpdate(index, category);
		}

		else if (category == AMMO)
		{
			StoredItem stored;
			this.ammos.GetArray(index, stored);

			Item reg;
			if (!GetItemByID(stored.id, reg) || reg.ammoID == INVALID_AMMO_ID) {
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
				stored.id = INVALID_ITEM_ID;
				this.ammos.SetArray(index, stored);
				this.TakeItemUpdate(index, category);
			}
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

		if (!IsValidEntity(this.wearerRef)) {
			numDroppedBackpacks--;
		}

		int dropped = EntRefToEntIndex(this.propRef);
		if (dropped != -1)
		{
			isDroppedBackpack[dropped] = false;
			RemoveEntity(dropped);
		}

		delete this.weapons;
		delete this.gears;
		delete this.ammos;
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
}

public void OnPluginStart()
{
	LoadTranslations("backpack2.phrases");
	LoadTranslations("common.phrases");

	hintCookie = new Cookie("backpack_hints", "Disable Backpack2 hints", CookieAccess_Public);

	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("player_extracted", OnPlayerExtracted);
	HookEvent("nmrih_reset_map", Event_MapReset);

	RegConsoleCmd("dropbackpack", Cmd_DropBackpack);
	MaxEntities = GetMaxEntities();
	if (MaxEntities > MAXENTITIES)
	{
		SetFailState("Entity limit greater than expected. " ...
			"Change '#define MAXENTITIES %d' to '#define MAXENTITIES %d' and recompile the plugin",
			MAXENTITIES, MaxEntities);
	}

	cvAmmoLootMin = CreateConVar("sm_backpack_zombie_ammo_min", "0", "");
	cvAmmoLootMax = CreateConVar("sm_backpack_zombie_ammo_max", "4", "");
	cvAmmoLootMinPct = CreateConVar("sm_backpack_zombie_ammo_min_pct", "30", "");
	cvAmmoLootMaxPct = CreateConVar("sm_backpack_zombie_ammo_max_pct", "100", "");
	cvGearLootMin = CreateConVar("sm_backpack_zombie_gear_min", "0", "");
	cvGearLootMax = CreateConVar("sm_backpack_zombie_gear_max", "1", "");
	cvWeaponLootMin = CreateConVar("sm_backpack_zombie_weapon_min", "0", "");
	cvWeaponLootMax = CreateConVar("sm_backpack_zombie_weapon_max", "2", "");

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

	cvNpcBackpackChance = CreateConVar("sm_backpack_zombie_chance", "0.005",
	 "Chance for a zombie to spawn with a backpack. Set to zero or negative to disable");

	cvOptimize = CreateConVar("sm_backpack_enable_optimizations", "1",
		"Don't trace dropped items if perceived backpack count is zero. Disable for debugging only");

	cvOptimize.AddChangeHook(CvarChangeOptimize);

	AutoExecConfig(true, "plugin.backpack2");

	inv_maxcarry = FindConVar("inv_maxcarry");
	sv_zombie_crawler_health = FindConVar("sv_zombie_crawler_health");

	backpacks = new ArrayList(sizeof(Backpack));
	templates = new ArrayList(sizeof(BackpackTemplate));

	itemRegistry = new ArrayList(sizeof(Item));
	itemLookup = new StringMap();

	ParseConfig();

	// inv_maxcarry = FindConVar("inv_maxcarry");

	AddCommandListener(Cmd_TakeItems, "takeitems");
	AddCommandListener(Cmd_CloseBox, "closeitembox");
	RegAdminCmd("sm_bp", Cmd_Backpack, ADMFLAG_CHEATS);
	RegAdminCmd("sm_backpack", Cmd_Backpack, ADMFLAG_CHEATS);


	HookEvent("game_restarting", OnGameRestarting, EventHookMode_PostNoCopy);
	HookEvent("npc_killed", OnNPCKilled);

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientPutInServer(i);

}

void SetCookieMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption)
	{
		Format(buffer, maxlen, "%T", "Backpack Settings", client);
	}

	else if (action == CookieMenuAction_SelectOption)
	{
		ShowBackpackSettings(client);
	}
}

void ShowBackpackSettings(int client)
{
	Menu menu = new Menu(HandleCookieMenu);

	char buffer[512];

	if (ClientWantsHints(client)) {
		FormatEx(buffer, sizeof(buffer), "%T", "Hints Enabled", client);
	}
	else {
		FormatEx(buffer, sizeof(buffer), "%T", "Hints Disabled", client);
	}

	menu.AddItem("nohints", buffer);
	menu.Display(client, MENU_TIME_FOREVER);
}

public int HandleCookieMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[32];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "nohints"))
		{
			char value[11];
			hintCookie.Get(param1, value, sizeof(value));
			PrintCenterText(param1, "%s", value);
			hintCookie.Set(param1, value[0] == '0' ? "1" : "0");
			ShowBackpackSettings(param1);
		}
	}

	else if (action == MenuAction_End) {
		delete menu;
	}

	return 0;
}


void CvarChangeOptimize(ConVar convar, const char[] oldValue, const char[] newValue)
{
	optimize = newValue[0] != '0';
}

public Action Cmd_DropBackpack(int client, int args)
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
		ReplyToCommand(client, "%t", "Give Backpack Already Owns", target);
		return Plugin_Handled;
	}

	Backpack bp;
	bp.Init(TEMPLATE_RANDOM);
	bp.Attach(target);
	backpacks.PushArray(bp);

	ReplyToCommand(client, "%t", "Give Backpack Success", target);
	return Plugin_Handled;
}

Action Cmd_CloseBox(int client, const char[] command, int argc)
{
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

	char cmdWeaponSlot[11], cmdGearSlot[11], cmdAmmoSlot[11];
	GetCmdArg(2, cmdWeaponSlot, sizeof(cmdWeaponSlot));
	GetCmdArg(3, cmdGearSlot, sizeof(cmdGearSlot));
	GetCmdArg(4, cmdAmmoSlot, sizeof(cmdAmmoSlot));

	int weaponSlot = StringToInt(cmdWeaponSlot);
	if (0 <= weaponSlot < bp.weapons.Length)
		bp.TakeItem(weaponSlot, WEAPON, client);

	int gearSlot = StringToInt(cmdGearSlot);
	if (0 <= gearSlot < bp.gears.Length)
		bp.TakeItem(gearSlot, GEAR, client);

	int ammoSlot = StringToInt(cmdAmmoSlot);
	if (0 <= ammoSlot < bp.ammos.Length)
		bp.TakeItem(ammoSlot, AMMO, client);

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
			AddFileToDownloadsTable(template.droppedMdl);
		}
		
		if (template.attachMdl[0])
		{
			PrecacheModel(template.attachMdl);
			AddFileToDownloadsTable(template.attachMdl);
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
		int amt = GetRandomInt(cvAmmoLootMin.IntValue, cvAmmoLootMax.IntValue);
		if (amt > 0) {
			bp.AddRandomAmmoBoxes(amt);
		}

		amt = GetRandomInt(cvWeaponLootMin.IntValue, cvWeaponLootMax.IntValue);
		if (amt > 0) {
			bp.AddRandomWeapons(amt, WEAPON);
		}

		amt = GetRandomInt(cvGearLootMin.IntValue, cvGearLootMax.IntValue);
		if (amt > 0) {
			bp.AddRandomWeapons(amt, GEAR);
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
	CreateTimer(0.1, OnAmmoFallThink, EntIndexToEntRef(ammobox), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

void OnWeaponDropped(int client, int weapon)
{
	if (!IsValidPlayer(client)) {
		return;
	}

	stopThinkTime[weapon] = GetTickedTime() + 1.5;
	// CheckWeaponCollide(weapon); // crashing in 1.12.0
	CreateTimer(0.1, OnWeaponFallThink, EntIndexToEntRef(weapon), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
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

#define EFL_NO_THINK_FUNCTION (1 << 22)

void CheckAmmoBoxCollide(int ammobox)
{
	if (optimize && numDroppedBackpacks <= 0) {
		return;
	}

	float pos[3];
	GetEntPropVector(ammobox, Prop_Data, "m_vecOrigin", pos);

	static float mins[3] = {-8.0, -8.0, -8.0};
	static float maxs[3] = {8.0, 8.0, 8.0};

	TR_EnumerateEntitiesHull(pos, pos, mins, maxs, MASK_WIP, OnAmmoBoxCollide, ammobox);
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

	TR_EnumerateEntitiesHull(pos, pos, mins, maxs, MASK_WIP, OnWeaponCollide, weapon);
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
		int leftover = bp.AddItem(ammoCount, reg);

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
			
			if (backpack.AddItem(ammoAmt, reg) == 0) 
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
				int bID = backpacks.FindValue(EntIndexToEntRef(client), Backpack::wearerRef);
				if (bID != -1)
				{
					Backpack bp;
					backpacks.GetArray(bID, bp);
					bp.Drop();
					backpacks.SetArray(bID, bp);
				}	
			}
		}
	}

	else if (cvHints.BoolValue && ClientWantsHints(client))
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
					SendBackpackHint(client, "[G] Drop backpack");
				}
			}
		}

		else if (IsLookingAtBackpack(client))
		{
			if (!wasLookingAtBackpack[client]) 
			{
				SendBackpackHint(client, "[PUNCH] Equip backpack\n\n[E] Open backpack");
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
	if (AreClientCookiesCached(client))
	{
		char value[11];
		hintCookie.Get(client, value, sizeof(value));
		return value[0] == '0';
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
	// FIXME

	// L 11/10/2021 - 16:23:17: [SM] Exception reported: Entity 277 (277) is not a valid entity
	// L 11/10/2021 - 16:23:17: [SM] Blaming: backpack2.smx
	// L 11/10/2021 - 16:23:17: [SM] Call stack trace:
	// L 11/10/2021 - 16:23:17: [SM]   [0] RemoveEntity
	// L 11/10/2021 - 16:23:17: [SM]   [1] Line 623, backpack2.sp::Backpack::Delete
	// L 11/10/2021 - 16:23:17: [SM]   [2] Line 1108, backpack2.sp::DeleteAllBackpacks
	// L 11/10/2021 - 16:23:17: [SM]   [3] Line 747, backpack2.sp::OnPluginEnd


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
		
		item.id = kv.GetNum("id", INVALID_ITEM_ID);

		char category[20];
		kv.GetString("category", category, sizeof(category), "none");

		char lootStr[5];
		kv.GetString("loot", lootStr, sizeof(lootStr), "yes");

		item.spawnAsLoot = !StrEqual(lootStr, "no");

		if (StrEqual(category, "ammo"))
		{
			// Ammo boxes have extra data and use model paths for their alias
			item.category = AMMO;
			item.ammoID = kv.GetNum("ammo-id", INVALID_AMMO_ID);
			item.capacity = kv.GetNum("capacity", 1);
			kv.GetString("model", item.alias, sizeof(item.alias));
		}
		else
		{
			kv.GetSectionName(item.alias, sizeof(item.alias));
			if (StrEqual(category, "weapon", false)) 
			{
				item.category = WEAPON;
			}
			if (StrEqual(category, "gear", false)) 
			{
				item.category = GEAR;
			}
			else if (!category[0] || StrEqual(category, "none"))
			{
				item.category = NONE;
			}
		}

		// if SetArray would fail, resize the array 
		// this expects the game to use somewhat consequential IDs for weapons
		if (item.id >= itemRegistry.Length)
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

			template.weaponLimit = kv.GetNum("max_weapons", 8);
			template.gearLimit = kv.GetNum("max_gear", 4);
			template.ammoLimit = kv.GetNum("max_ammoboxes", 8);


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
	int logic = CreateEntityByName("logic_script");

	char buffer[75];
	FormatEx(buffer, sizeof(buffer),
		"self.SetName(EntIndexToHScript(%d).GetCarriedWeight().tostring())", client);

	SetVariantString(buffer);
	AcceptEntityInput(logic, "RunScriptCode");
	GetEntPropString(logic, Prop_Send, "m_iName", buffer, sizeof(buffer));

	RemoveEntity(logic);

	return StringToFloat(buffer);
}

Action OnBackpackPropDamage(int backpack, int& attacker, int& inflictor, float& damage, int& damagetype)
{
	if ((damagetype & DMG_CLUB || damagetype & DMG_SLASH) && IsValidPlayer(attacker) && 
		!wearingBackpack[attacker] && IsValidEntity(inflictor) && CanReachBackpack(attacker, backpack))
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
			PrintToChat(entity, PLUGIN_PREFIX ... "%t", "Invalid drop position");
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

void SendBackpackHint(int client, const char[] hint)
{
	Handle msg = StartMessageOne("KeyHintText", client, USERMSG_BLOCKHOOKS);
	BfWrite bf = UserMessageToBfWrite(msg);
	bf.WriteByte(1); // number of strings, only 1 is accepted
	bf.WriteString(hint);
	EndMessage();
}

void GetLootOfCategory(int category, ArrayList dest)
{
	Item reg;
	int maxWeapons = itemRegistry.Length;
	for (int i = 0; i < maxWeapons; i++)
	{
		itemRegistry.GetArray(i, reg);
		if (reg.category == category && reg.spawnAsLoot)
		{
			dest.PushArray(reg);
		}
	}
}

int GetMaxClip1(int weapon)
{
	SetVariantString("self.SetName(self.GetMaxClip1().tostring())");
	AcceptEntityInput(weapon, "RunScriptCode", weapon, weapon);

	char result[11];
	GetEntPropString(weapon, Prop_Data, "m_iName", result, sizeof(result));

	return StringToInt(result);
}

float GetWeaponWeight(int weapon)
{
	SetVariantString("self.SetName(self.GetWeight().tostring())");
	AcceptEntityInput(weapon, "RunScriptCode", weapon, weapon);

	char result[11];
	GetEntPropString(weapon, Prop_Data, "m_iName", result, sizeof(result));

	return StringToFloat(result);
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