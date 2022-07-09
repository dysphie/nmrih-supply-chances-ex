#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define SUPPLY_CHANCES_VERSION "1.1.3"

public Plugin myinfo =
{
    name = "[NMRiH] Supply Chances (Dysphie's fork)",
    author = "Ryan.",
    description = "Adjust spawn chances of inside inventory boxes.",
    version = SUPPLY_CHANCES_VERSION,
    url = "https://forums.alliedmods.net/showthread.php?p=2598096"
};

#define LOG_TAG "[Supply Chances]"

#define CLASSNAME_MAX 128   // Max length of an entity's classname.
#define WEAPON_ID_MAX 128   // Limits the size of our weapon registry array.

// Number of slots per inventory box category.
#define ITEMBOX_MAX_SLOTS 8
#define ITEMBOX_MAX_GEAR 4

// Constants for Get/SetEntData()
#define SIZEOF_INT 4
#define SIZEOF_SHORT 2

#define KV_KEYS_ONLY true
#define KV_KEYS_AND_VALUES false

#define KV_CREATE_IF_MISSING true
#define KV_IGNORE_IF_MISSING false

enum eInventoryBoxCategory
{
    INVENTORY_BOX_CATEGORY_NONE = 0,  // Fists and zippo.
    INVENTORY_BOX_CATEGORY_WEAPON = 1,
    INVENTORY_BOX_CATEGORY_GEAR = 2,
    INVENTORY_BOX_CATEGORY_AMMO = 3
};

enum eCustomSupplyChances
{
    CSC_CHANCE,     // float, 0-100 chance for this box type to spawn
    CSC_WEAPONS,    // ArrayList of weapon's weapon chances
    CSC_GEAR,       // ArrayList of gear's weapon chances
    CSC_AMMO,       // ArrayList of ammo's weapon chances
    CSC_BLOCKED_WEAPON_COUNT,   // Number of items in CSC_WEAPONS array that have 0% chance to spawn.
    CSC_BLOCKED_GEAR_COUNT,     // As above.
    CSC_BLOCKED_AMMO_COUNT,     // As above.

    CSC_TUPLE_SIZE
};

enum eWeaponChancePair
{
    WCP_WEAPON_ID,      // int, ID into g_weapon_registry_names
    WCP_WEAPON_CHANCE,  // float, 0-100 chance for this item to spawn

    WCP_TUPLE_SIZE
};

Handle g_sdkcall_itembox_remove_item;

// Offsets to the int32 arrays inside item_inventory_box's entdata.
int g_offset_itembox_ammo_array;
int g_offset_itembox_gear_array;
int g_offset_itembox_weapon_array;

int g_default_supply_type[CSC_TUPLE_SIZE];  // Fallback supply type.
ArrayList g_supply_types;                   // Stores tuples of eCustomSupplyChance. One of these will be randomly selected for each inventory box spawned.
ArrayList g_supply_type_models;             // Contains the model name used by each supply box type.
ArrayList g_weapon_registry_names;          // Stores weapons' name.
StringMap g_weapon_registry_name_lookup;    // Weapon name to g_weapon_registry_* index

Handle g_forward_on_supply_chances_modify_box;  // A forward that gets called before any box is modified. Signature: Action (int item_box)
                                                // If any plugin returns something other than Plugin_Continue, the box won't be changed.

ConVar g_cvar_supply_chances_config;        // Name of config file to base supply-chances off of (names a file inside sourcemod/configs)

/**
 * Setup plugin.
 */
public void OnPluginStart()
{
    LoadGameData();

    g_supply_types = new ArrayList(CSC_TUPLE_SIZE, 0);
    g_supply_type_models = new ArrayList(PLATFORM_MAX_PATH, 0);
    g_weapon_registry_names = new ArrayList(CLASSNAME_MAX, 0);
    g_weapon_registry_name_lookup = new StringMap();

    g_forward_on_supply_chances_modify_box = CreateGlobalForward("OnSupplyChancesModifyBox", ET_Hook, Param_Cell);

    g_cvar_supply_chances_config = CreateConVar("sm_supply_chances_config", "",
        "Name of supply chance config file (excluding extension). Configs should be placed in sourcemod/configs");

    AutoExecConfig(true);

    RequestFrame(OnFrame_DelayLoadSupplyChancesConfig, 0);
    LoadPluginConfig();
}

/**
 * We delay hooking the config cvar because AutoExecConfig seems to
 * finish late which would cause LoadSupplyChancesConfig() to be called
 * twice.
 */
public void OnFrame_DelayLoadSupplyChancesConfig(int frames_to_wait)
{
    if (frames_to_wait <= 0)
    {
        g_cvar_supply_chances_config.AddChangeHook(ConVar_OnSupplyChancesConfigChanged);
        LoadSupplyChancesConfig();
    }
    else
    {
        RequestFrame(OnFrame_DelayLoadSupplyChancesConfig, frames_to_wait - 1);
    }
}

/**
 * Allow the custom supply chances to be changed mid-game.
 */
public void ConVar_OnSupplyChancesConfigChanged(ConVar cvar, const char[] previous, const char[] current)
{
    LoadSupplyChancesConfig();
}

/**
 * Handle replacing the loot in new inventory boxes.
 */
public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "item_inventory_box"))
    {
        SDKHook(entity, SDKHook_Spawn, Hook_InventoryBoxSpawn);
    }
}

/**
 * Replace the inventory box's contents with a random loot from a randomly
 * selected supply box type.
 */
public void Hook_InventoryBoxSpawn(int box)
{
    // Check if other plugins are protecting this box.
    Action allowed = Plugin_Continue;
    Call_StartForward(g_forward_on_supply_chances_modify_box);
    Call_PushCell(box);
    Call_Finish(allowed);
    if (allowed != Plugin_Continue)
    {
        return;
    }

    // Select a random supply box type.
    float roll = GetURandomFloat() * 100.0;
    int supply_type = -1;

    int supply_type_count = g_supply_types.Length;
    for (int i = 0; i < supply_type_count && supply_type == -1; ++i)
    {
        float chance = view_as<float>(g_supply_types.Get(i, CSC_CHANCE));
        if (chance > 0.0)
        {
            if (roll < chance)
            {
                supply_type = i;
            }
            else
            {
                roll -= chance;
            }
        }
    }

    // Replace the box's loot.
    if (supply_type != -1)
    {
        ArrayList weapons = view_as<ArrayList>(g_supply_types.Get(supply_type, CSC_WEAPONS));
        ArrayList gear = view_as<ArrayList>(g_supply_types.Get(supply_type, CSC_GEAR));
        ArrayList ammo = view_as<ArrayList>(g_supply_types.Get(supply_type, CSC_AMMO));

        int weapons_blocked = g_supply_types.Get(supply_type, CSC_BLOCKED_WEAPON_COUNT);
        int gear_blocked = g_supply_types.Get(supply_type, CSC_BLOCKED_GEAR_COUNT);
        int ammo_blocked = g_supply_types.Get(supply_type, CSC_BLOCKED_AMMO_COUNT);

        for (int slot = 0; slot < ITEMBOX_MAX_SLOTS; ++slot)
        {
            ReplaceBoxItem(box, INVENTORY_BOX_CATEGORY_WEAPON, slot, weapons, weapons_blocked);
            ReplaceBoxItem(box, INVENTORY_BOX_CATEGORY_AMMO, slot, ammo, ammo_blocked);
            if (slot < ITEMBOX_MAX_GEAR)
            {
                ReplaceBoxItem(box, INVENTORY_BOX_CATEGORY_GEAR, slot, gear, gear_blocked);
            }
        }

        char model_path[PLATFORM_MAX_PATH];
        if (g_supply_type_models.GetString(supply_type, model_path, sizeof(model_path)) > 0)
        {
            SetEntityModel(box, model_path);
        }
    }
}

/**
 * Load ent offsets and SDK calls from gamedata config.
 */
void LoadGameData()
{
    static const char gamedata_name[] = "supply-chances.games";
    Handle gameconf = LoadGameConfigFile(gamedata_name);
    if (!gameconf)
    {
        SetFailState("Unable to load gamedata: %s", gamedata_name);
    }

    g_offset_itembox_ammo_array = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_iAmmoItemIds");
    g_offset_itembox_gear_array = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_iGearItemIds");
    g_offset_itembox_weapon_array = GameConfGetOffsetOrFail(gameconf, "CItem_InventoryBox::m_WeaponArray");

    StartPrepSDKCall(SDKCall_Entity);
    GameConfPrepSDKCallSignatureOrFail(gameconf, "CItem_InventoryBox::RemoveItem");
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByRef);  // category &
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);  // slot
    g_sdkcall_itembox_remove_item = EndPrepSDKCall();

    CloseHandle(gameconf);
}

/**
 * Load weapon registry and default supply box chances.
 */
void LoadPluginConfig()
{
    char file_path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, file_path, sizeof(file_path), "configs/supply-chances.cfg");

    KeyValues kv = new KeyValues("supply-chances");
    if (kv.ImportFromFile(file_path))
    {
        LoadWeaponRegistry(kv);
        LoadDefaultSupplyChances(kv);
    }

    if (kv)
    {
        delete kv;
    }
}

/**
 * Read the "default" supply box type. This supply box type is used as a fallback
 * when a weapon needs to be replaced (0% spawn chance) and a custom item wasn't
 * selected to replace it.
 */
void LoadDefaultSupplyChances(KeyValues kv)
{
    DeleteSupplyType(g_default_supply_type);

    static const char DEFAULT_CHANCES[] = "default-chances";
    if (kv.JumpToKey(DEFAULT_CHANCES, KV_IGNORE_IF_MISSING))
    {
        ReadSupplyChancesFromKeyValues(kv, g_default_supply_type, 100.0, DEFAULT_CHANCES);
        kv.GoBack();
    }
}

/**
 * The weapon registry maps weapon classnames to the ID's used by inventory boxes.
 */
void LoadWeaponRegistry(KeyValues kv)
{
    g_weapon_registry_names.Clear();
    g_weapon_registry_names.Resize(WEAPON_ID_MAX);

    g_weapon_registry_name_lookup.Clear();

    if (kv.JumpToKey("weapon-registry", KV_IGNORE_IF_MISSING))
    {
        if (kv.GotoFirstSubKey(KV_KEYS_AND_VALUES))
        {
            char item_name[CLASSNAME_MAX];

            do
            {
                // Extract item info.
                kv.GetSectionName(item_name, sizeof(item_name));
                int id = kv.GetNum(NULL_STRING, -1);

                if (id >= 0 && id < WEAPON_ID_MAX)
                {
                    // Map item's name to its weapon registry ID.
                    g_weapon_registry_name_lookup.SetValue(item_name, id);
                    g_weapon_registry_names.SetString(id, item_name);
                }
            } while (kv.GotoNextKey(KV_KEYS_AND_VALUES));

            kv.GoBack();
        }

        kv.GoBack();
    }
}

/**
 * Delete custom supply chances.
 */
void ResetCustomSupplyChances()
{
    int supply_type[CSC_TUPLE_SIZE];

    int supply_type_count = g_supply_types.Length;
    for (int i = 0; i < supply_type_count; ++i)
    {
        int cells = g_supply_types.GetArray(i, supply_type, sizeof(supply_type));
        if (cells == sizeof(supply_type))
        {
            DeleteSupplyType(supply_type);
        }
    }

    g_supply_types.Clear();
    g_supply_type_models.Clear();
}

/**
 * Delete supply type's custom weapon, gear and ammo lists.
 */
void DeleteSupplyType(int supply_type[CSC_TUPLE_SIZE])
{
    ArrayList weapons = view_as<ArrayList>(supply_type[CSC_WEAPONS]);
    if (weapons)
    {
        delete weapons;
        supply_type[CSC_WEAPONS] = 0;
    }

    ArrayList gear = view_as<ArrayList>(supply_type[CSC_GEAR]);
    if (gear)
    {
        delete gear;
        supply_type[CSC_GEAR] = 0;
    }

    ArrayList ammo = view_as<ArrayList>(supply_type[CSC_AMMO]);
    if (ammo)
    {
        delete ammo;
        supply_type[CSC_AMMO] = 0;
    }
}

/**
 * Iterate over the custom supply box types and read them.
 */
void LoadSupplyChancesConfig()
{
    ResetCustomSupplyChances();

    char config_name[128];
    g_cvar_supply_chances_config.GetString(config_name, sizeof(config_name));

    if (config_name[0] == '\0')
    {
        PrintToServer("%s Using default spawn chances.", LOG_TAG);
        return;
    }

    char file_path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, file_path, sizeof(file_path), "configs/%s.cfg", config_name);

    KeyValues kv = new KeyValues("supply-chances");
    if (kv && kv.ImportFromFile(file_path))
    {
        static const char CUSTOM_CHANCES[] = "custom-chances";

        char section[64];

        kv.GetSectionName(section, sizeof(section));
        if ((StrEqual(section, CUSTOM_CHANCES) || kv.JumpToKey(CUSTOM_CHANCES, KV_IGNORE_IF_MISSING)) &&
            kv.GotoFirstSubKey(KV_KEYS_ONLY))
        {
            char supply_name[128];
            char model_path[PLATFORM_MAX_PATH];
            float chance_total = 0.0;

            do
            {
                kv.GetSectionName(supply_name, sizeof(supply_name));

                float supply_chance = kv.GetFloat("weight", 100.0);
                if (supply_chance <= 0.0)
                {
                    continue;
                }
                chance_total += supply_chance;

                int supply_type[CSC_TUPLE_SIZE];
                ReadSupplyChancesFromKeyValues(kv, supply_type, supply_chance, supply_name);
                g_supply_types.PushArray(supply_type);

                kv.GetString("model", model_path, sizeof(model_path), "");
                if (model_path[0] != '\0')
                {
                    int id = PrecacheModel(model_path, true);
                    if (id <= 0 || !IsModelPrecached(model_path))
                    {
                        PrintToServer("%s Invalid model used in box type \"%s\": %s", LOG_TAG, supply_name, model_path);
                        model_path[0] = '\0';
                    }
                }
                g_supply_type_models.PushString(model_path);

            } while (kv.GotoNextKey(KV_KEYS_ONLY));

            kv.GoBack();

            // Normalize supply type chances when their total is above 100.
            if (chance_total > 100.0)
            {
                int supply_types = g_supply_types.Length;
                for (int i = 0; i < supply_types; ++i)
                {
                    float chance = view_as<float>(g_supply_types.Get(i, CSC_CHANCE));
                    g_supply_types.Set(i, view_as<int>(chance / chance_total * 100.0), CSC_CHANCE);
                }
            }

            PrintToServer("%s Loaded supply chances from %s. Found %d box types.", LOG_TAG, config_name, g_supply_types.Length);
        }
    }
    else
    {
        PrintToServer("%s Can't import key-values from file %s. Using default supply chances.", LOG_TAG, config_name);
    }

    if (kv)
    {
        delete kv;
    }
}

/**
 * Read a custom supply box type from KeyValues.
 *
 * Supply box types have one optional field named "weight" and three optional
 * blocks: "weapons", "gear" and "ammo" which correspond to the inventory
 * box's categories.
 *
 * The three blocks contain 0 or more weapon chance pairs; the weapon's name
 * and its weight to be selected for spawning. Weapons with a weight of 0 will
 * never be allowed to spawn.
 */
void ReadSupplyChancesFromKeyValues(
    KeyValues kv,
    int supply_type[CSC_TUPLE_SIZE],
    float chance,
    const char[] supply_name)
{
    supply_type[CSC_CHANCE] = view_as<int>(chance);
    supply_type[CSC_WEAPONS] = 0;
    supply_type[CSC_GEAR] = 0;
    supply_type[CSC_AMMO] = 0;
    supply_type[CSC_BLOCKED_WEAPON_COUNT] = 0;
    supply_type[CSC_BLOCKED_GEAR_COUNT] = 0;
    supply_type[CSC_BLOCKED_AMMO_COUNT] = 0;

    if (kv.JumpToKey("weapons", KV_IGNORE_IF_MISSING))
    {
        if (kv.GotoFirstSubKey(KV_KEYS_AND_VALUES))
        {
            int blocked_count = 0;
            ArrayList weapons = ReadWeaponChancesFromKeyValues(kv, supply_name, blocked_count);

            supply_type[CSC_WEAPONS] = view_as<int>(weapons);
            supply_type[CSC_BLOCKED_WEAPON_COUNT] = blocked_count;

            kv.GoBack();
        }

        kv.GoBack();
    }

    if (kv.JumpToKey("gear", KV_IGNORE_IF_MISSING))
    {
        if (kv.GotoFirstSubKey(KV_KEYS_AND_VALUES))
        {
            int blocked_count = 0;
            ArrayList gear = ReadWeaponChancesFromKeyValues(kv, supply_name, blocked_count);

            supply_type[CSC_GEAR] = view_as<int>(gear);
            supply_type[CSC_BLOCKED_GEAR_COUNT] = blocked_count;

            kv.GoBack();
        }

        kv.GoBack();
    }

    if (kv.JumpToKey("ammo", KV_IGNORE_IF_MISSING))
    {
        if (kv.GotoFirstSubKey(KV_KEYS_AND_VALUES))
        {
            int blocked_count = 0;
            ArrayList ammo = ReadWeaponChancesFromKeyValues(kv, supply_name, blocked_count);

            supply_type[CSC_AMMO] = view_as<int>(ammo);
            supply_type[CSC_BLOCKED_AMMO_COUNT] = blocked_count;

            kv.GoBack();
        }

        kv.GoBack();
    }
}

/**
 * Expects \c kv to be at the first key-value in a weapon chance block.
 *
 * Reads pairs of weapon classnames => percent chance to spawn in supply box.
 *
 * Normalizes each entry's chance when the total chance is above 100.
 *
 * @param kv                KeyValues object to read.
 * @param supply_name       Name of supply type (for logging purposes).
 * @param blocked_count     Number of weapons that have 0% or less chance of spawning. 
 *
 * @return ArrayList of (weapon ID, spawn chance) pairs.
 */
ArrayList ReadWeaponChancesFromKeyValues(KeyValues kv, const char[] supply_name, int &blocked_count)
{
    ArrayList list = new ArrayList(WCP_TUPLE_SIZE, 0);

    char key[CLASSNAME_MAX];
    float chance_total = 0.0;

    do
    {
        kv.GetSectionName(key, sizeof(key));
        StringToLower(key);

        float chance = kv.GetFloat(NULL_STRING, 100.0);
        chance_total += chance;

        int id = 0;
        if (!g_weapon_registry_name_lookup.GetValue(key, id))
        {
            LogMessage("Warning: Classname '%s' in supply type \"%s\" not found in weapon registry", key, supply_name);
        }
        else if (list.FindValue(id, WCP_WEAPON_ID) != -1)
        {
            LogMessage("Warning: Ignoring duplicate entry for '%s' in supply type \"%s\"", key, supply_name);
        }
        else
        {
            int pair[WCP_TUPLE_SIZE];
            pair[WCP_WEAPON_ID] = id;
            pair[WCP_WEAPON_CHANCE] = view_as<int>(chance);
            list.PushArray(pair);

            if (chance <= 0.0)
            {
                ++blocked_count;
            }
        }
    } while (kv.GotoNextKey(KV_KEYS_AND_VALUES));

    // Normalize chances when they go beyond 100.
    if (chance_total > 100.0)
    {
        int entry_count = list.Length;
        for (int i = 0; i < entry_count; ++i)
        {
            float chance = view_as<float>(list.Get(i, WCP_WEAPON_CHANCE));
            list.Set(i, view_as<int>(chance / chance_total * 100.0), WCP_WEAPON_CHANCE);
        }
    }

    return list;
}

void RemoveBoxItem(int box, int category, int slot)
{
    SDKCall(g_sdkcall_itembox_remove_item, box, category, slot);
}

/**
 * Retrieve the weapon ID held in a particular inventory box category-slot.
 * Additionally retrieves the entdata offset for that slot.
 *
 * @return True if the category and slot are valid, otherwise returns false.
 */
bool GetBoxWeaponId(int box, int category, int slot, int &weapon_id, int &ent_data_offset)
{
    bool valid_slot = false;

    int base_offset = 0;
    int max_slots = 0;
    if (category == view_as<int>(INVENTORY_BOX_CATEGORY_WEAPON))
    {
        base_offset = g_offset_itembox_weapon_array;
        max_slots = ITEMBOX_MAX_SLOTS;
    }
    else if (category == view_as<int>(INVENTORY_BOX_CATEGORY_GEAR))
    {
        base_offset = g_offset_itembox_gear_array;
        max_slots = ITEMBOX_MAX_GEAR;
    }
    else if (category == view_as<int>(INVENTORY_BOX_CATEGORY_AMMO))
    {
        base_offset = g_offset_itembox_ammo_array;
        max_slots = ITEMBOX_MAX_SLOTS;
    }

    if (slot >= 0 && slot < max_slots && base_offset > 0)
    {
        valid_slot = true;

        ent_data_offset = base_offset + SIZEOF_INT * slot;
        weapon_id = GetEntData(box, ent_data_offset, SIZEOF_INT);
    }

    return valid_slot;
}

/*
 * Replace an item inside a box using a custom item weight list.
 *
 * @param box           Ent of item_inventory_box.
 * @param category      Which category to affect.
 * @param slot          0 to ITEMBOX_MAX_SLOTS or ITEMBOX_MAX_GEAR (depending
 *                      on category)
 * @param item_chances  List of custom item spawn chances for this category.
 * @param items_blocked Number of items blocked from spawning by \c item_chances
 */
void ReplaceBoxItem(
    int box,
    eInventoryBoxCategory category,
    int slot,
    ArrayList item_chances,
    int items_blocked)
{
    if (!item_chances)
    {
        return;
    }

    int weapon_id = -1;
    int offset = -1;
    if (GetBoxWeaponId(box, category, slot, weapon_id, offset))
    {
        // Select a random item type.
        float roll = GetURandomFloat() * 100.0;
        int random_id = -1;
        bool must_replace = false;

        int item_count = item_chances.Length;
        for (int i = 0; i < item_count && random_id == -1; ++i)
        {
            float chance = item_chances.Get(i, WCP_WEAPON_CHANCE);
            if (chance > 0.0)
            {
                if (roll < chance)
                {
                    random_id = item_chances.Get(i, WCP_WEAPON_ID);
                }
                else
                {
                    roll -= chance;
                }
            }
            else if (!must_replace)
            {
                must_replace = item_chances.Get(i, WCP_WEAPON_ID) == weapon_id;
            }
        }

        if (random_id == -1)
        {
            if (must_replace)
            {
                // Try to select a new random ID
                random_id = GetRandomItem(category, item_chances, items_blocked);
            }
            else
            {
                random_id = weapon_id;
            }
        }

        if (random_id != -1)
        {
            SetEntData(box, offset, random_id, SIZEOF_INT);
        }
        else
        {
            RemoveBoxItem(box, category, slot);
        }
    }
}

/**
 * Try to select a random item from a custom item chance pool.
 *
 * If an item from the custom chance pool was not selected, fallback to the
 * default item pool. But when picking from the default pool, honour the
 * restrictions made by the custom chances. I.e. items with 0% custom chance
 * should not be picked from the default pool either.
 *
 * @param category      Tells us which category of default items to use.
 * @param item_chances  List of item IDs and their custom spawn chance.
 * @param items_blocked Number of items in \c item_chances with 0% chance.
 *
 * @return  Random item ID from \c item_chances or the categories default
 *          pool that aren't blocked by \c item_chances. -1 if none could
 *          be found.
 */
int GetRandomItem(eInventoryBoxCategory category, ArrayList item_chances, int items_blocked)
{
    int random_id = -1;

    int[] blocked_ids = new int[items_blocked]; // Should be freed automatically: https://wiki.alliedmods.net/SourcePawn_Transitional_Syntax#Arrays
    items_blocked = 0;

    // First, roll against the custom item weights.
    float roll = GetURandomFloat() * 100.0;
    int item_count = item_chances.Length;
    for (int i = 0; i < item_count && random_id == -1; ++i)
    {
        float chance = item_chances.Get(i, WCP_WEAPON_CHANCE);
        if (chance > 0.0)
        {
            if (roll < chance)
            {
                random_id = item_chances.Get(i, WCP_WEAPON_ID);
            }
            else
            {
                roll -= chance;
            }
        }
        else
        {
            blocked_ids[items_blocked] = item_chances.Get(i, WCP_WEAPON_ID);
            ++items_blocked;
        }
    }

    // If first roll found nothing, roll again using the default item weights.
    if (random_id == -1)
    {
        ArrayList default_chances = null;
        switch (category)
        {
        case INVENTORY_BOX_CATEGORY_WEAPON:
            default_chances = view_as<ArrayList>(g_default_supply_type[CSC_WEAPONS]);

        case INVENTORY_BOX_CATEGORY_GEAR:
            default_chances = view_as<ArrayList>(g_default_supply_type[CSC_GEAR]);

        case INVENTORY_BOX_CATEGORY_AMMO:
            default_chances = view_as<ArrayList>(g_default_supply_type[CSC_AMMO]);
        }

        if (default_chances)
        {
            // Calculate the the percentage that blocked items occupy.
            float total_blocked_chance = 0.0;
            int default_count = default_chances.Length;
            for (int i = 0; i < default_count; ++i)
            {
                for (int j = 0; j < items_blocked; ++j)
                {
                    if (default_chances.Get(i, WCP_WEAPON_ID) == blocked_ids[j])
                    {
                        total_blocked_chance += view_as<float>(default_chances.Get(i, WCP_WEAPON_CHANCE));
                        break;
                    }
                }
            }

            float leftover_chance = 100.0 - total_blocked_chance;
            if (leftover_chance <= 0.0)
            {
                return -1;
            }

            roll = GetURandomFloat() * 100.0;
            for (int i = 0; i < default_count && random_id == -1; ++i)
            {
                float chance = view_as<float>(default_chances.Get(i, WCP_WEAPON_CHANCE));
                if (chance <= 0.0)
                {
                    continue;
                }

                bool blocked = false;

                int weapon_id = default_chances.Get(i, WCP_WEAPON_ID);
                for (int j = 0; j < items_blocked && !blocked; ++j)
                {
                    blocked = weapon_id == blocked_ids[j];
                }

                if (blocked)
                {
                    continue;
                }

                // Renormalize this item's chance to account for blocked items.
                chance = chance / leftover_chance * 100.0;

                if (roll < chance)
                {
                    random_id = weapon_id;
                }
                else
                {
                    roll -= chance;
                }
            }
        }
    }

    return random_id;
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
 * Make string lowercase.
 */
int StringToLower(char[] to_lower)
{
    int i = 0;
    while (to_lower[i] != '\0')
    {
        to_lower[i] = CharToLower(to_lower[i]);
        ++i;
    }
    return i;
}
