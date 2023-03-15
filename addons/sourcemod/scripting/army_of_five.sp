
// ================================================================	//
// Hello and welcome to the source code of Army of Five plugin.		//
// Yes, what you see is 3000+ lines of messy code indeed.			//
// It was started as the first Sourcemod plugin I've ever created	//
// and ended up being a complex project with numerous features.		//
// I never refactored this, but it appears to work fine at least.	//
// So I guess it is what it is.    - Rushin' Russian, July 2017		//
// ================================================================	//

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <insurgency>
#include <smlib>
#undef REQUIRE_PLUGIN
#include <regex>

#pragma unused cvarVersion

#define INS
#define PLUGIN_VERSION "1.4"
#define PLUGIN_DESCRIPTION "Plugin for Army of Five coop mod"

new String:l_configPath[PLATFORM_MAX_PATH];
#define AOF_CONFIG_PATH "configs/aof"
#define AOF_ENTITY_TARGET_NAME "aof_entity"
#define AOF_DUMMY_MODEL_NAME "models/props/cs_office/vending_machine.mdl" // doesn't matter at all

// Fade flags (copy-pasted).
#define FFADE_IN            0x0001        // Just here so we don't pass 0 into the function
#define FFADE_OUT           0x0002        // Fade out (not in)
#define FFADE_MODULATE      0x0004        // Modulate (don't blend)
#define FFADE_STAYOUT       0x0008        // ignores the duration, stays faded out until new ScreenFade message received
#define FFADE_PURGE         0x0010        // Purges all other fades, replacing them with this one

#define MAX_PLAYERS 48	// The constant "MAXPLAYERS" seems to be 64 and is screwing some things up, so here's "MAX_PLAYERS" instead.
#define BOT_COUNT   15	// Bot count *must* remain at constant 15. This plugin will respawn and/or kill them off automatically to adjust the count.

#define MAX_SPAWN_ZONES 		30
#define MAX_TOTAL_SPAWN_POINTS	5000

// I can't #define these :/ Should've used a global const of some sort but w/e
new Float:BOT_HEIGHT = 70.0; 
new Float:BOT_LAST_SEEN_TIME = 15.0;
//new Float:BOT_LAST_SEEN_TIME2 = 25.0; // unused mechanic.

public Plugin:myinfo =
{
	name = "Army of Five plugin",
	author = "Rushin' Russian",
	version = PLUGIN_VERSION,
	description = PLUGIN_DESCRIPTION,
	url = "http://none"
};

// Insurgency standard colors:
// \x03 - light green
// \x04 - solid green
// \x05 - dark green / yellow-ish
// \x06 - black
// \x11 - yellow (no longer works)
// \x12 - dark yellow (no longer works)
// It is recommended to use "\x07######texthere" format, where ###### is the RGB color.
// There are actually quite a few plugins (even SM standard ones, I think?) that help with this.
// But too late for that, I decided to just implement my own simple approach.
// Note: "F2ECD9" is the default white chat color (or, well, it's close enough to it).
#define COLOR_AOF_ROUNDSTART		"D3D3D3"
#define COLOR_AOF_HEALTH_RESTORED	"7FFF00"
#define COLOR_AOF_PLAYER_DOWN		"FF4500"
#define COLOR_AOF_TIP				"7FFF00"
#define COLOR_AOF_DEBUG				"EE82EE"
#define COLOR_AOF_SELECTED_CLASS	"D3D3D3"
#define COLOR_AOF_FINALE_MESSAGE	"FFDE00"
#define COLOR_AOF_JOIN_GROUP		"D3D3D3"
#define COLOR_AOF_SELECTED_DIFF		"D3D3D3"
#define COLOR_AOF_DIFF_VOTE_END		"D3D3D3"
#define COLOR_AOF_DIFF_CURRENT		"FFDE00"
//#define COLOR_AOF_DIFF_EASY		"DC143C"
//#define COLOR_AOF_DIFF_NORMAL		"DC143C"
//#define COLOR_AOF_DIFF_HARD		"DC143C"
//#define COLOR_AOF_DIFF_BRUTAL		"DC143C"

// Note:
// g_var stands for "global var".
// l_var stands for "lookup var", i.e. it's sort of global const.

// Hit groups.
new String:l_hitgroupName[9][50];
enum eHitGroup
{
	hgGeneral = 0,
	hgHead,
	hgChest,
	hgStomach,
	hgLeftArm,
	hgRightArm,
	hgLeftLeg,
	hgRightLeg,
	hgGear
};

// Human classes.
enum eHumanClass
{
	hcBreacher = 0,
	hcRifleman,
	hcScavenger,
	hcMarksman,
	hcGrenadier,
	hcSwapSlot,
	hcBotClass,
	hcUnknown,
	TOTAL_PLAYER_CLASSES
};
new String:l_playerClassName[TOTAL_PLAYER_CLASSES][100];

// Bot classes and groups.
enum eBotClass
{
	bcHeavy = 0,
	bcSniper1,
	bcSniper2,
	bcShotgunner,
	bcFighter1,
	bcFighter2,
	bcFighter3,
	bcUnknown,
	TOTAL_BOT_CLASSES
};
enum eBotGroup
{
	bgHeavy = 0,
	bgGeneric,
	bgLight,
	//bgUnknown,
	TOTAL_BOT_GROUPS
};
new String:l_botGroupName[TOTAL_BOT_GROUPS][100];
StringMap l_botClassNameToIndex = null;
new l_botClassToBotGroup[TOTAL_BOT_CLASSES];

// Difficulty levels.
enum eDifficultyLevel
{
	difEasy = 0,
	difNormal,
	difHard,
	difBrutal,
	TOTAL_DIFFICULTY_LEVELS
};
new String:l_difficultyName[TOTAL_DIFFICULTY_LEVELS][100];

// This defines how many bots will spawn (depending on player count).
// For example, N = 10 bots spawn for the first player and then F = 7.3 more
// spawn for every extra player. That is 10 + 7.3 * (5 - 1) = 39 bots for 5 players.
new Float:l_botCountOnePlayer[2][view_as<int>(TOTAL_DIFFICULTY_LEVELS)][view_as<int>(TOTAL_BOT_GROUPS)];
new Float:l_botFracPerPlayer[2][view_as<int>(TOTAL_DIFFICULTY_LEVELS)][view_as<int>(TOTAL_BOT_GROUPS)];

// How many more bots in that group can we spawn?
new g_botQueue[TOTAL_BOT_GROUPS];
new g_botsLeft[TOTAL_BOT_GROUPS];

// This arrays stores information about which class every player (bot or human) is.
// Its values are enums above. This data is neither initialized nor reset
// on disconnect so make sure that you access it only for valid clients.
// NOTE: do NOT rely on this for the humans that are alive!
// You can change your class without actually resupplying, remember?
// Use the GetRealHumanClass(client) function in that case.
new g_playerClass[MAX_PLAYERS + 1];

// Bot spawns.
new String:l_mapName[255], String:l_bseFileName[255];
new g_maxZone = 0;
new g_curZone = -1; 
new Handle:g_spawns[MAX_SPAWN_ZONES];
new Handle:g_activateBlockZones[MAX_SPAWN_ZONES];
new Handle:g_deactivateBlockZones[MAX_SPAWN_ZONES];
new Handle:g_revealSpawnsTimer	= INVALID_HANDLE;
new Handle:g_sightCheckTimer	= INVALID_HANDLE;
new bool:g_revealSpawnsNow	= false;
new bool:g_hideBodiesNow	= false;
new bool:g_checkSightNow	= false;
new Float:g_botLastSeen[MAX_PLAYERS + 1];
new bool:g_isInGame = false;
new Float:g_dummySpot[3];

// Player spawns.
new Handle:g_playerSpawns[MAX_SPAWN_ZONES];
new g_playerSpawnIndex = 0;

// SDK setup - for player respawning.
new Handle:g_hGameConfig;
new Handle:g_hPlayerRespawn;

// cvars.
new Handle:cvarVersion				= INVALID_HANDLE;
new Handle:cvarInsBotDifficulty		= INVALID_HANDLE, 		serverDifficulty;
new Handle:cvarRestoreHealth		= INVALID_HANDLE, bool:	serverRestoreHealth;
new Handle:cvarDebugDamage			= INVALID_HANDLE, bool:	serverDebugDamage;
new Handle:cvarPrintBotCount		= INVALID_HANDLE, bool:	serverPrintBotCount;
new Handle:cvarSpawnRevealRate		= INVALID_HANDLE, Float:serverSpawnRevealRate;
new Handle:cvarForcePlayerCount		= INVALID_HANDLE, 		serverForcePlayerCount;
new Handle:cvarDebugBotSpawns		= INVALID_HANDLE, bool:	serverDebugBotSpawns;
new Handle:cvarDebugBotSpawns2		= INVALID_HANDLE, bool:	serverDebugBotSpawns2;
new Handle:cvarDebugFinaleOnly		= INVALID_HANDLE, bool:	serverDebugFinaleOnly;
new Handle:cvarEnableTips			= INVALID_HANDLE, bool: serverEnableTips;
new Handle:cvarSightCheckRate		= INVALID_HANDLE, Float:serverSightCheckRate;
//new Handle:cvarEnableBotTeleport	= INVALID_HANDLE, bool: serverEnableBotTeleport;
new Handle:cvarEnableGroupInvite	= INVALID_HANDLE, bool: serverEnableGroupInvite;
new Handle:cvarEnableFinale			= INVALID_HANDLE, bool: serverEnableFinale;
new Handle:cvarPrintHealth			= INVALID_HANDLE, bool: serverPrintHealth;
new Handle:cvarDebugAnesthetic		= INVALID_HANDLE, bool: serverDebugAnesthetic;

// Difficulty voting menu.
new bool:g_isdifVoteReady = true;
new Handle:g_difVoteHandle = INVALID_HANDLE;
new Handle:g_difVoteList = INVALID_HANDLE;
new g_lastVotePrintTimestamp = 0;

// God Mode stuff.
new bool:g_isInGodMode[MAX_PLAYERS + 1];
new Float:g_lastDealtDamageTime[MAX_PLAYERS + 1];
new Float:g_lastTakenDamageTime[MAX_PLAYERS + 1];
new Float:g_godModeValue[MAX_PLAYERS + 1];
new Float:l_godModeDamageHeavyModifier = 3.0;
new Float:l_godModeDamageDefaultScale = 0.20;
new Float:l_godModeDamageDifficultyModifier[TOTAL_DIFFICULTY_LEVELS] = { 1.35, 1.05, 0.83, 0.67 };
new Float:l_godModeDuration = 9.5; // seconds
new Float:l_godModeActiveInternalStart = 130.0;
new Float:l_godModeActiveDecayRate;
new Float:l_godModeInactiveDecayOnePercentTime = 2.0;
new Float:l_godModeInactiveDecayRate;
new Float:l_godModeFreezeTimeOnDamage = 3.0;
new Float:l_godModeDamageExplosiveScale = 0.7;

// Scavenger vampire mechanic.
new Float:l_scavengerVampireRewardNormal =  4.0;
new Float:l_scavengerVampireRewardHeavy  =  8.0;

// Scavenger anesthetic mechanic.
new Float:l_scavengerAnesthetic = 0.16; // how long, in seconds, until the damage reduction bonus fully wears off.
new l_scavengerAnestheticDebug[MAX_PLAYERS + 1];

// Removal of empty weapons.
new Handle:g_removeWeapon;

// Did you know that resupplying SOMETIMES heals you up? This must be disabled.
new g_lastHealth[MAX_PLAYERS + 1];

// This helps keep track of whether the player has spawned for the first time or not.
new bool:g_hasSpawnedBefore[MAX_PLAYERS + 1];

// Finales.
new bool:g_isFinale = false;

// Plugin whitelisting.
new Handle:g_pluginWhitelist = INVALID_HANDLE;

// Shotgunner bots' flashlights.
new Float:g_flashlightTickLastUpdate = 0.0;

// Round count.
new g_roundNumber = 0;

Min(a, b) { if (a < b) return a; return b; }
Max(a, b) { if (a > b) return a; return b; }
Float:MinFloat(Float:a, Float:b) { if (a < b) return a; return b; } // never used, commented out to get rid of the warning
Float:MaxFloat(Float:a, Float:b) { if (a > b) return a; return b; }

// When plugin starts.
public OnAllPluginsLoaded() // note: no OnPluginStart
{
	// Force to check for updates. The plugin will be automatically reloaded on map change or server restart.
	UpdateSelf();
	
	// Load translations.
	LoadTranslations("common.phrases");
	LoadTranslations("army_of_five.phrases");
	
	// Most of these are not even supposed to be editable by server operators, they were implemented for debug reasons.
	cvarVersion				= CreateConVar("aof_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | FCVAR_DONTRECORD);
	cvarRestoreHealth		= CreateConVar("aof_restore_health",		"1",	"Restore health of all alive players whenever an object is captured or destroyed?",	FCVAR_NOTIFY);
	cvarDebugDamage			= CreateConVar("aof_debug_damage", 			"0",	"Debug damage dealt to bots (to aid in weapon balancing)?",							FCVAR_NOTIFY);
	cvarPrintBotCount		= CreateConVar("aof_print_bot_count",		"1",	"Print bot count for all players constantly?",										FCVAR_NOTIFY);
	cvarSpawnRevealRate		= CreateConVar("aof_spawn_reveal_rate",		"0.3",	"How often (in seconds) can players reveal bot spawn points?",						FCVAR_NOTIFY);
	cvarForcePlayerCount	= CreateConVar("aof_force_player_count",	"0",	"Force player count to become this specific value (0 = disabled)",					FCVAR_NOTIFY);
	cvarDebugBotSpawns		= CreateConVar("aof_debug_bot_spawns", 		"0",	"Debug bot spawning?",																FCVAR_NOTIFY);
	cvarDebugBotSpawns2		= CreateConVar("aof_debug_bot_spawns2", 	"0",	"Extra debug",																		FCVAR_NOTIFY);
	cvarDebugFinaleOnly		= CreateConVar("aof_debug_finale_only", 	"0",	"Disable everything but the finales?",												FCVAR_NOTIFY);
	cvarEnableTips			= CreateConVar("aof_enable_tips", 			"1",	"Enable tips?",																		FCVAR_NOTIFY);
	cvarSightCheckRate		= CreateConVar("aof_sight_check_rate",		"0.2",	"How often (in seconds) can players spot the bots?",								FCVAR_NOTIFY);
	//cvarEnableBotTeleport	= CreateConVar("aof_enable_bot_teleport", 	"0",	"Enable bot teleporting? - KEEP THIS ONE DISABLED",									FCVAR_NOTIFY);
	cvarEnableGroupInvite	= CreateConVar("aof_enable_group_invite", 	"1",	"Enable ins_aof steam group invitation message?",									FCVAR_NOTIFY);
	cvarEnableFinale		= CreateConVar("aof_enable_finale",		 	"1",	"Enable finale?",																	FCVAR_NOTIFY);
	cvarPrintHealth			= CreateConVar("aof_print_health",			"1",	"Display Scavenger's health?",														FCVAR_NOTIFY);
	cvarDebugAnesthetic		= CreateConVar("aof_debug_anesthetic", 		"0",	"Debug the 'anesthetic' mechanic for Scavenger?",									FCVAR_NOTIFY);
	cvarInsBotDifficulty	= FindConVar("ins_bot_difficulty");
	//RegConsoleCmd("inventory_resupply", PlayerResupply);
	RegConsoleCmd("aof_test", CmdTest);	
	
	HookConVarChange(cvarRestoreHealth,		CvarChange);
	HookConVarChange(cvarDebugDamage,		CvarChange);
	HookConVarChange(cvarPrintBotCount,		CvarChange);
	HookConVarChange(cvarSpawnRevealRate,	CvarChange);
	HookConVarChange(cvarForcePlayerCount,	CvarChange);
	HookConVarChange(cvarDebugBotSpawns,	CvarChange);
	HookConVarChange(cvarDebugBotSpawns2,	CvarChange);
	HookConVarChange(cvarDebugFinaleOnly,	CvarChange);
	HookConVarChange(cvarEnableTips,		CvarChange);
	HookConVarChange(cvarSightCheckRate,	CvarChange);
	//HookConVarChange(cvarEnableBotTeleport,	CvarChange);
	HookConVarChange(cvarEnableGroupInvite,	CvarChange);
	HookConVarChange(cvarEnableFinale,		CvarChange);
	HookConVarChange(cvarPrintHealth,		CvarChange);
	HookConVarChange(cvarDebugAnesthetic,	CvarChange);
	HookConVarChange(cvarInsBotDifficulty,	CvarChange);
	UpdateCvars();
	
	HookEvent("player_spawn",			Event_PlayerSpawn);
	HookEvent("player_pick_squad",		Event_PlayerPickSquad);
	HookEvent("player_changename",		Event_NameChanged, EventHookMode_Pre);
	HookEvent("player_hurt",			Event_PlayerHurtPre, EventHookMode_Pre);
	HookEvent("player_death",			Event_PlayerDeathPre, EventHookMode_Pre);
	HookEvent("player_blind",			Event_PlayerBlindPre, EventHookMode_Pre);
	HookEvent("player_disconnect", 		Event_PlayerDisconnect, EventHookMode_Pre);
	HookEvent("game_start", 			Event_GameStart); // this also fires when someone connects after everyone left mid-map.
	HookEvent("game_end", 				Event_GameEnd); // this fires about 10 seconds prior to map voting start (or level change, if "next map" was voted before)
	HookEvent("round_start",			Event_RoundStart);
	HookEvent("round_end",				Event_RoundEnd);
	HookEvent("object_destroyed",		Event_ObjectDestroyedPre, EventHookMode_Pre);
	HookEvent("controlpoint_captured",	Event_ControlPointCapturedPre, EventHookMode_Pre);
	HookEvent("server_cvar",			Event_ServerCvar, EventHookMode_Pre);
	
	l_playerClassName[hcBreacher]	= "breacher";
	l_playerClassName[hcRifleman]	= "rifleman";
	l_playerClassName[hcScavenger]	= "scavenger";
	l_playerClassName[hcMarksman]	= "marksman";
	l_playerClassName[hcGrenadier]	= "grenadier";
	l_playerClassName[hcSwapSlot]	= "swapslot";
	l_playerClassName[hcBotClass]	= "debug_class";
	l_playerClassName[hcUnknown]	= "unknown_class";
		
	l_hitgroupName[hgGeneral]	= "GENERAL";
	l_hitgroupName[hgHead]		= "HEAD";
	l_hitgroupName[hgChest]		= "CHEST";
	l_hitgroupName[hgStomach]	= "STOMACH";
	l_hitgroupName[hgLeftArm]	= "LEFTARM";
	l_hitgroupName[hgRightArm]	= "RIGHTARM";
	l_hitgroupName[hgLeftLeg]	= "LEFTLEG";
	l_hitgroupName[hgRightLeg]	= "RIGHTLEG";
	l_hitgroupName[hgGear]		= "GEAR";
	
	l_botGroupName[bgHeavy]		= "Heavy";
	l_botGroupName[bgGeneric]	= "Generic";
	l_botGroupName[bgLight]		= "Light";
	
	l_botClassNameToIndex = new StringMap();
	l_botClassNameToIndex.SetValue("template_bot_heavy_aof",		bcHeavy,		true);
	l_botClassNameToIndex.SetValue("template_bot_sniper1_aof",		bcSniper1,		true);
	l_botClassNameToIndex.SetValue("template_bot_sniper2_aof",		bcSniper2,		true);
	l_botClassNameToIndex.SetValue("template_bot_shotgunner_aof",	bcShotgunner,	true);
	l_botClassNameToIndex.SetValue("template_bot_fighter1_aof",		bcFighter1,		true);
	l_botClassNameToIndex.SetValue("template_bot_fighter2_aof",		bcFighter2,		true);
	l_botClassNameToIndex.SetValue("template_bot_fighter3_aof",		bcFighter3,		true);
	l_botClassToBotGroup[bcHeavy]		= bgHeavy;
	l_botClassToBotGroup[bcSniper1]		= bgLight;
	l_botClassToBotGroup[bcSniper2]		= bgLight;
	l_botClassToBotGroup[bcShotgunner]	= bgLight;
	l_botClassToBotGroup[bcFighter1]	= bgGeneric;
	l_botClassToBotGroup[bcFighter2]	= bgGeneric;
	l_botClassToBotGroup[bcFighter3]	= bgGeneric;
	
	l_godModeActiveDecayRate = (l_godModeActiveInternalStart * GetTickInterval()) / l_godModeDuration;
	l_godModeInactiveDecayRate = (1.0 / l_godModeInactiveDecayOnePercentTime) * GetTickInterval();
	
	// Set up the config path (likely addons/sourcemod/configs/aof).
	BuildPath(Path_SM, l_configPath, sizeof(l_configPath), AOF_CONFIG_PATH);
	
	SetupDifficultyLevels();
	SetupDifVoteMenu();
	SetupSDK();
	SetupPluginWhitelist();
	
	ResetServerCVars();
	UnloadPlugins();
	
	PrintToServer("[AoF] =============== OnAllPluginsLoaded done ===============");
}

SetupDifficultyLevels()
{
	l_difficultyName[difEasy]	= "difficulty_easy";
	l_difficultyName[difNormal]	= "difficulty_normal";
	l_difficultyName[difHard]	= "difficulty_hard";
	l_difficultyName[difBrutal]	= "difficulty_brutal";
	
	/////////////////////////////////////////
	// R E G U L A R   O B J E C T I V E S //
	/////////////////////////////////////////
	// Easy
	l_botCountOnePlayer[0][difEasy][bgHeavy]		= _:1.001;
	l_botCountOnePlayer[0][difEasy][bgLight]		= _:1.201;
	l_botCountOnePlayer[0][difEasy][bgGeneric]		= _:3.501;
	l_botFracPerPlayer[0][difEasy][bgHeavy]			= _:0.501;
	l_botFracPerPlayer[0][difEasy][bgLight]			= _:0.801;
	l_botFracPerPlayer[0][difEasy][bgGeneric]		= _:1.701;
	
	// Normal
	l_botCountOnePlayer[0][difNormal][bgHeavy]		= _:1.001;
	l_botCountOnePlayer[0][difNormal][bgLight]		= _:2.001;
	l_botCountOnePlayer[0][difNormal][bgGeneric]	= _:5.001;
	l_botFracPerPlayer[0][difNormal][bgHeavy]		= _:0.901;
	l_botFracPerPlayer[0][difNormal][bgLight]		= _:1.101;
	l_botFracPerPlayer[0][difNormal][bgGeneric]		= _:2.201;
	
	// Hard
	l_botCountOnePlayer[0][difHard][bgHeavy]		= _:1.001;
	l_botCountOnePlayer[0][difHard][bgLight]		= _:3.001;
	l_botCountOnePlayer[0][difHard][bgGeneric]		= _:7.001;
	l_botFracPerPlayer[0][difHard][bgHeavy]			= _:1.301;
	l_botFracPerPlayer[0][difHard][bgLight]			= _:1.801;
	l_botFracPerPlayer[0][difHard][bgGeneric]		= _:2.801;
	
	// Brutal
	l_botCountOnePlayer[0][difBrutal][bgHeavy]		= _:2.201;
	l_botCountOnePlayer[0][difBrutal][bgLight]		= _:4.001;
	l_botCountOnePlayer[0][difBrutal][bgGeneric]	= _:8.001;
	l_botFracPerPlayer[0][difBrutal][bgHeavy]		= _:1.801;
	l_botFracPerPlayer[0][difBrutal][bgLight]		= _:2.301;
	l_botFracPerPlayer[0][difBrutal][bgGeneric]		= _:3.801;
	
	///////////////////
	// F I N A L E S //
	///////////////////
	// Easy
	l_botCountOnePlayer[1][difEasy][bgHeavy]		= _:1.001;
	l_botCountOnePlayer[1][difEasy][bgLight]		= _:1.201;
	l_botCountOnePlayer[1][difEasy][bgGeneric]		= _:2.501;
	l_botFracPerPlayer[1][difEasy][bgHeavy]			= _:0.501;
	l_botFracPerPlayer[1][difEasy][bgLight]			= _:1.001;
	l_botFracPerPlayer[1][difEasy][bgGeneric]		= _:1.901;
	
	// Normal
	l_botCountOnePlayer[1][difNormal][bgHeavy]		= _:1.001;
	l_botCountOnePlayer[1][difNormal][bgLight]		= _:2.001;
	l_botCountOnePlayer[1][difNormal][bgGeneric]	= _:3.001;
	l_botFracPerPlayer[1][difNormal][bgHeavy]		= _:1.001;
	l_botFracPerPlayer[1][difNormal][bgLight]		= _:1.301;
	l_botFracPerPlayer[1][difNormal][bgGeneric]		= _:2.501;
	
	// Hard
	l_botCountOnePlayer[1][difHard][bgHeavy]		= _:1.001;
	l_botCountOnePlayer[1][difHard][bgLight]		= _:2.001;
	l_botCountOnePlayer[1][difHard][bgGeneric]		= _:5.001;
	l_botFracPerPlayer[1][difHard][bgHeavy]			= _:1.501;
	l_botFracPerPlayer[1][difHard][bgLight]			= _:2.001;
	l_botFracPerPlayer[1][difHard][bgGeneric]		= _:3.301;
	
	// Brutal
	l_botCountOnePlayer[1][difBrutal][bgHeavy]		= _:2.201;
	l_botCountOnePlayer[1][difBrutal][bgLight]		= _:3.001;
	l_botCountOnePlayer[1][difBrutal][bgGeneric]	= _:6.001;
	l_botFracPerPlayer[1][difBrutal][bgHeavy]		= _:2.001;
	l_botFracPerPlayer[1][difBrutal][bgLight]		= _:2.501;
	l_botFracPerPlayer[1][difBrutal][bgGeneric]		= _:4.501;
}

SetupDifVoteMenu()
{
	g_difVoteHandle = CreateMenu(DifMenuHandler, MenuAction_DisplayItem|MenuAction_Display);
	SetMenuTitle(g_difVoteHandle, "<vote_menu_title>");
	for (new i = 0; i < view_as<int>(TOTAL_DIFFICULTY_LEVELS); ++i)
	{
		AddMenuItem(g_difVoteHandle, l_difficultyName[i], l_difficultyName[i]);
	}
	g_difVoteList = CreateArray();
}

SetupSDK()
{
	// SDK setup.
	g_hGameConfig = LoadGameConfigFile("insurgency.games");
	if (g_hGameConfig == INVALID_HANDLE)
	{
		SetFailState("[AoF] ERROR: missing file addons/sourcemod/gamedata/insurgency.games.txt! Re-download and extract aof_package.zip from the server hosting guide!");
	}
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Signature, "ForceRespawn");
	g_hPlayerRespawn = EndPrepSDKCall();
	if (g_hPlayerRespawn == INVALID_HANDLE)
	{
		SetFailState("[AoF] ERROR: unable to find signature for \"ForceRespawn\" in addons/sourcemod/gamedata/insurgency.games.txt! Re-download and extract aof_package.zip from the server hosting guide!");
	}
}

SetupPluginWhitelist()
{
	// AoF forcefully unloads and disables all the plugins that are not explicitly approved in this list.
	// It may sounds like a terrible idea. And it probably is, I know. But you know what's even worse?
	// Loading plugins that awfully conflict with AoF. That's what. There are plugins out there
	// that can disrupt the Army of Five gameplay very badly. This helps to prevent that from happening.
	// If you're reading this, please contact me on steam if you'd like to see another plugin whitelisted.
	g_pluginWhitelist = CreateArray(ByteCountToCells(200));
	
	// Required plugins.
	PushArrayString(g_pluginWhitelist, "army_of_five.smx");
	
	// Standard plugins.
	PushArrayString(g_pluginWhitelist, "admin.smx");
	PushArrayString(g_pluginWhitelist, "adminhelp.smx");
	PushArrayString(g_pluginWhitelist, "adminmenu.smx");
	PushArrayString(g_pluginWhitelist, "antiflood.smx");
	PushArrayString(g_pluginWhitelist, "basebans.smx");
	PushArrayString(g_pluginWhitelist, "basechat.smx");
	PushArrayString(g_pluginWhitelist, "basecomm.smx");
	PushArrayString(g_pluginWhitelist, "basecommands.smx");
	PushArrayString(g_pluginWhitelist, "basetriggers.smx");
	PushArrayString(g_pluginWhitelist, "basevotes.smx");
	PushArrayString(g_pluginWhitelist, "clientprefs.smx");
	PushArrayString(g_pluginWhitelist, "funcommands.smx");
	PushArrayString(g_pluginWhitelist, "funvotes.smx");
	//PushArrayString(g_pluginWhitelist, "nextmap.smx"); // it says it's incompatible with this game...
	PushArrayString(g_pluginWhitelist, "playercommands.smx");
	PushArrayString(g_pluginWhitelist, "reservedslots.smx");
	PushArrayString(g_pluginWhitelist, "sounds.smx");
	PushArrayString(g_pluginWhitelist, "admin-sql-prefetch.smx");
	PushArrayString(g_pluginWhitelist, "admin-sql-threaded.smx");
	PushArrayString(g_pluginWhitelist, "mapchooser.smx");
	PushArrayString(g_pluginWhitelist, "randomcycle.smx");
	PushArrayString(g_pluginWhitelist, "rockthevote.smx");
	PushArrayString(g_pluginWhitelist, "admin-flatfile.smx");

	// Some custom plugins.
	PushArrayString(g_pluginWhitelist, "advertisements.smx");		// "Advertisements" (0.6) by Tsunami
	PushArrayString(g_pluginWhitelist, "botnames.smx");				// "Bot Names" (1.0) by Rakeri
	PushArrayString(g_pluginWhitelist, "gem_damage_report.smx");	// "Damage report" (1.1.13) by [30+]Gemeni
	PushArrayString(g_pluginWhitelist, "hlstatsx.smx");				// "HLstatsX CE Ingame Plugin" (1.6.19) by psychonic
	//PushArrayString(g_pluginWhitelist, "insurgency.smx");			// "[INS] Insurgency Support Library" (1.3.0) by Jared Ballou
	//PushArrayString(g_pluginWhitelist, "killer_info_display.smx");	// "Killer Info Display" (1.4.1) by Berni, gH0sTy, Smurfy1982, Snake60
	PushArrayString(g_pluginWhitelist, "motd.smx");					// "Message Of The Day" (2.0) by Insurgency ANZ
	PushArrayString(g_pluginWhitelist, "sb_admins.smx");			// "SourceBans: Admins" (2.0.0-dev) by GameConnect
	PushArrayString(g_pluginWhitelist, "sb_bans.smx");				// "SourceBans: Bans" (2.0.0-dev) by GameConnect
	//PushArrayString(g_pluginWhitelist, "showhealth.smx");			// "Show Health" (1.0.2) by exvel
	PushArrayString(g_pluginWhitelist, "sm_downloader.smx");		// "SM File/Folder Downloader and Precacher" (1.4) by SWAT_88
	PushArrayString(g_pluginWhitelist, "sourcebans.smx");			// "SourceBans" (2.0.0-dev) by GameConnect
	PushArrayString(g_pluginWhitelist, "sourcesleuth.smx");			// "SourceSleuth" (SBR-1.5.3) by ecca, Sarabveer(VEER™)
	PushArrayString(g_pluginWhitelist, "superlogs-generic.smx");	// "SuperLogs: Generic" (1.0) by psychonic
	PushArrayString(g_pluginWhitelist, "superlogs-ins.smx");		// "SuperLogs: Insurgency" (1.1.4) by psychonic
	PushArrayString(g_pluginWhitelist, "tf_kickvote_immunity.smx");	// "TF2 Basic Kickvote Immunity" (1.2) by psychoninc
	PushArrayString(g_pluginWhitelist, "votelog.smx");				// "Vote Logging" (0.0.3) by Jared Ballou (jballou)
	
	// Other seemingly harmless plugins - untested.
	PushArrayString(g_pluginWhitelist, "adminlist.smx");
	PushArrayString(g_pluginWhitelist, "afk_manager.smx");
	PushArrayString(g_pluginWhitelist, "commanddump.smx");
	PushArrayString(g_pluginWhitelist, "crashmap.smx");
	PushArrayString(g_pluginWhitelist, "custom_hostname.smx");
	PushArrayString(g_pluginWhitelist, "nofog.smx");
	PushArrayString(g_pluginWhitelist, "nominations.smx");
	PushArrayString(g_pluginWhitelist, "nominations_extended.smx");
	PushArrayString(g_pluginWhitelist, "rockthevote_extended.smx");
	PushArrayString(g_pluginWhitelist, "rules.smx");
	PushArrayString(g_pluginWhitelist, "serverhop.smx");
	PushArrayString(g_pluginWhitelist, "simple-chatprocessor.smx");
	PushArrayString(g_pluginWhitelist, "sourcebans_listener.smx");
	PushArrayString(g_pluginWhitelist, "sourcebans_sample.smx");
	PushArrayString(g_pluginWhitelist, "sql-admin-manager.smx");
	PushArrayString(g_pluginWhitelist, "steamtools.smx");
	PushArrayString(g_pluginWhitelist, "welcomesound-ins.smx");
	
	// v1.4
	PushArrayString(g_pluginWhitelist, "discord_api.smx");
	PushArrayString(g_pluginWhitelist, "discord_MapNotification.smx");
	PushArrayString(g_pluginWhitelist, "discord_chat.smx");
	PushArrayString(g_pluginWhitelist, "slowmo_aof.smx");
	PushArrayString(g_pluginWhitelist, "gameme.smx");
	PushArrayString(g_pluginWhitelist, "franug_tagfeatures.smx");
	PushArrayString(g_pluginWhitelist, "hl_bandisconnected.smx");
	PushArrayString(g_pluginWhitelist, "ins_serverinfo_shoubi.smx");
	PushArrayString(g_pluginWhitelist, "ins_serverinfo_aof.smx");
	PushArrayString(g_pluginWhitelist, "shutdowncountdown.smx");
	PushArrayString(g_pluginWhitelist, "console-welcome.smx");
}

void UnloadPlugins()
{
	//new String:pluginList[50][50];
	new Handle:iter = GetPluginIterator();
	decl String:fileName[200];
	while (MorePlugins(iter))
	{
		new Handle:plugin = ReadPlugin(iter);
		GetPluginFilename(plugin, fileName, sizeof(fileName));
		for (new i = 0, len = strlen(fileName); i < len; ++i)
		{
			fileName[i] = CharToLower(fileName[i]);
		}
		if (FindStringInArray(g_pluginWhitelist, fileName) == -1)
		{
			PrintToServer("[AoF] WARNING: Unloading and disabling plugin \"%s\", as it is not whitelisted by Army of Five. Sorry.", fileName);
			ServerCommand("sm plugins unload %s", fileName);
			decl String:enabledPath[PLATFORM_MAX_PATH], String:disabledPath[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, enabledPath, sizeof(enabledPath), "plugins/%s", fileName);
			BuildPath(Path_SM, disabledPath, sizeof(disabledPath), "plugins/disabled/%s", fileName);
			if (RenameFile(disabledPath, enabledPath) == false)
			{
				PrintToServer("[AoF] ERROR: couldn't move the plugin from \"%s\" to \"%s\".", enabledPath, disabledPath);
			}
		}
	}
	CloseHandle(iter);
}

// CVar updater.
public CvarChange(Handle:cvar, const String:oldvalue[], const String:newvalue[])
{
	UpdateCvars();
}

public UpdateCvars()
{
	serverRestoreHealth		= GetConVarBool(cvarRestoreHealth);
	serverDebugDamage		= GetConVarBool(cvarDebugDamage);
	serverPrintBotCount		= GetConVarBool(cvarPrintBotCount);
	serverSpawnRevealRate	= GetConVarFloat(cvarSpawnRevealRate);
	serverForcePlayerCount	= GetConVarInt(cvarForcePlayerCount);
	serverDebugBotSpawns	= GetConVarBool(cvarDebugBotSpawns);
	serverDebugBotSpawns2	= GetConVarBool(cvarDebugBotSpawns2);
	serverDebugFinaleOnly	= GetConVarBool(cvarDebugFinaleOnly);
	serverEnableTips		= GetConVarBool(cvarEnableTips);
	serverSightCheckRate	= GetConVarFloat(cvarSightCheckRate);
	//serverEnableBotTeleport	= GetConVarBool(cvarEnableBotTeleport);
	serverEnableGroupInvite	= GetConVarBool(cvarEnableGroupInvite);
	serverEnableFinale		= GetConVarBool(cvarEnableFinale);
	serverPrintHealth		= GetConVarBool(cvarPrintHealth);
	serverDebugAnesthetic	= GetConVarBool(cvarDebugAnesthetic);
	serverDifficulty		= GetConVarInt(cvarInsBotDifficulty);
}

ResetServerCVars()
{
	// Forces cvars.. just in case.
	SetConVarString	(FindConVar("mp_theater_override"),							"army_of_five"); 	// FORCED
	SetConVarInt	(FindConVar("mp_coop_lobbysize"),							5);			// FORCED
	SetConVarInt	(FindConVar("ins_bot_count_checkpoint"),					BOT_COUNT);	// FORCED
	SetConVarInt	(FindConVar("ins_bot_count_checkpoint_default"),			BOT_COUNT);	// FORCED
	SetConVarInt	(FindConVar("ins_bot_count_checkpoint_min"),				BOT_COUNT);	// FORCED
	SetConVarInt	(FindConVar("ins_bot_count_checkpoint_max"),				BOT_COUNT);	// FORCED
	SetConVarInt	(FindConVar("mp_spawns_per_frame"),							BOT_COUNT);	// FORCED
	SetConVarBool	(FindConVar("sv_vote_issue_botcount_allowed"),				false);	// FORCED
	SetConVarBool	(FindConVar("sv_vote_issue_changegamemode_allowed"),		false); // FORCED
	SetConVarBool	(FindConVar("mp_friendlyfire"),								false); // FORCED
	SetConVarInt	(FindConVar("mp_timer_preround"),							15);	// FORCED
	SetConVarInt	(FindConVar("mp_timer_postround"),							15);	// FORCED
	SetConVarInt	(FindConVar("mp_timer_postgame"),							10);	// FORCED
	SetConVarInt	(FindConVar("mp_timer_pregame"),							10);	// FORCED
	SetConVarInt	(FindConVar("mp_timer_preround_first"),						15);	// FORCED
	SetConVarInt	(FindConVar("mp_supply_token_base"),						10);	// FORCED
	SetConVarInt	(FindConVar("mp_supply_token_bot_base"),					10);	// FORCED
	SetConVarInt	(FindConVar("mp_supply_token_max"),							10);	// FORCED
	SetConVarInt	(FindConVar("mp_supply_gain"),								0);		// FORCED
	SetConVarInt	(FindConVar("mp_supply_rate_losing_team_high"),				0);		// FORCED
	SetConVarInt	(FindConVar("mp_supply_rate_losing_team_low"),				0);		// FORCED
	SetConVarInt	(FindConVar("mp_supply_rate_winning_team_high"),			0);		// FORCED
	SetConVarInt	(FindConVar("mp_supply_rate_winning_team_low"),				0);		// FORCED
	SetConVarInt	(FindConVar("mp_player_resupply_delay_base"),				15);	// FORCED
	SetConVarInt	(FindConVar("mp_player_resupply_delay_max"),				15);	// FORCED
	SetConVarInt	(FindConVar("mp_player_resupply_delay_penalty"),			0);		// FORCED
	SetConVarInt	(FindConVar("mp_player_resupply_coop_delay_base"),			15);	// FORCED
	SetConVarInt	(FindConVar("mp_player_resupply_coop_delay_max"),			15);	// FORCED
	SetConVarInt	(FindConVar("mp_player_resupply_coop_delay_penalty"),		0);		// FORCED
	SetConVarBool	(FindConVar("sv_hud_scoreboard_show_score"),				true);	// FORCED
	SetConVarBool	(FindConVar("sv_hud_scoreboard_show_score_dead"),			true);	// FORCED
	SetConVarInt	(FindConVar("mp_checkpoint_counterattack_always"),			1);		// FORCED
	SetConVarInt	(FindConVar("mp_checkpoint_counterattack_delay_finale"),	5);		// FORCED
	SetConVarInt	(FindConVar("mp_checkpoint_counterattack_wave_finale"),		0);		// FORCED
	SetConVarInt	(FindConVar("mp_checkpoint_counterattack_duration_finale"),	120);	// FORCED
	SetConVarFloat	(FindConVar("mp_wave_dpr_attackers_finale"),				0.0);	// FORCED
	SetConVarFloat	(FindConVar("mp_wave_dpr_defenders_finale"),				0.0);	// FORCED
	SetConVarInt	(FindConVar("ins_cache_health"), 							90);	// FORCED
	SetConVarInt	(FindConVar("mp_cp_capture_time"), 							23);	// FORCED
	SetConVarInt	(FindConVar("mp_cp_deteriorate_time"), 						120);	// FORCED
	SetConVarInt	(FindConVar("mp_roundtime"), 								900);	// FORCED
	SetConVarInt	(FindConVar("sv_weapon_manager_drop_timer"),				180);	// FORCED
	SetConVarInt	(FindConVar("sv_weapon_manager_max_count"),					100);	// FORCED
	
	// Other.
	SetConVarInt	(FindConVar("mp_maxrounds"),								5, false, false);
	
	// More gameplay settings.
	//SetConVarFloat	(FindConVar("ins_bot_attack_reload_ratio"),				0.3);
	//SetConVarInt	(FindConVar("ins_bot_max_grenade_range"),				900);
	//SetConVarInt	(FindConVar("ins_cache_explosion_damage"),				50);
	//SetConVarInt	(FindConVar("ins_cache_explosion_radius"),				256);
	//SetConVarBool	(FindConVar("sv_hud_targetindicator"),					true);
	
	// Kick idlers a bit earlier so that they don't take up the player slots.
	//SetConVarInt	(FindConVar("mp_autokick_idlers"),						8);
	//SetConVarInt	(FindConVar("sv_timeout"),								180);
	
	// Disable counter-attacks.
	//SetConVarBool	(FindConVar("mp_checkpoint_counterattack_disable"),		true); // NOT HERE
}

// On map start.
public OnMapStart()
{
	PrintToServer("[AoF] =============== MAP START (v%s) ===============", PLUGIN_VERSION);
	
	g_isInGame = false;
	g_flashlightTickLastUpdate = 0.0;
	
	for (new zone = 0; zone < MAX_SPAWN_ZONES; ++zone)
	{
		g_spawns[zone] = CreateArray(3);
		g_playerSpawns[zone] = CreateArray(3);
		g_activateBlockZones[zone] = CreateArray();
		g_deactivateBlockZones[zone] = CreateArray();		
	}
	g_removeWeapon = CreateArray();
	g_revealSpawnsTimer	= CreateTimer(serverSpawnRevealRate,	Timer_RevealSpawns,	_,	TIMER_REPEAT);
	g_sightCheckTimer	= CreateTimer(serverSightCheckRate,		Timer_CheckSight,	_,	TIMER_REPEAT);
	GetCurrentMap(l_mapName, sizeof(l_mapName));
	PrecacheModel(AOF_DUMMY_MODEL_NAME);
	
	// Build the bse file path.
	Format(l_bseFileName, sizeof(l_bseFileName), "%s/bse_data/%s.bse", l_configPath, l_mapName);
	
	// Reset stuff.
	ResetServerCVars();
	UnloadPlugins();
	ResetDifVote();
	
	//PrintToServer("[AoF] =============== Army of Five ready (v%s) ===============", PLUGIN_VERSION);
}

bool:UpdateSelf()
{
	//return true;
	// This function takes the files loaded from aof_main.vpk and copies them over to the server folders.
	PrintToServer("[AoF] =============== Updating from VPK (current version: %s) ===============", PLUGIN_VERSION);
	
	// Set up the paths and special file names.
	new String:serverDataPath[] = "aof_server";
	new String:updateFileName[] = "update.txt"
	new String:tempFileName[] = "aof_temp.dat";
	new String:sourcemodPathAlias[] = "Path_SM/";
	new String:updateFilePath[PLATFORM_MAX_PATH];
	new String:tempFilePath[PLATFORM_MAX_PATH];
	Format(updateFilePath, sizeof(updateFilePath), "%s/%s", serverDataPath, updateFileName);
	Format(tempFilePath, sizeof(tempFilePath), "%s/%s", l_configPath, tempFileName);
	
	// Open the update description file in the vpk.
	PrintToServer("[AoF-Updater] Opening aof_main.vpk...", updateFilePath);
	new Handle:updateFile = OpenFile(updateFilePath, "rt", true, NULL_STRING);
	if (updateFile == INVALID_HANDLE)
	{
		PrintToServer("[AoF-Updater] ERROR: couldn't find %s in the vpk.", updateFilePath);
		return false;
	}
	
	// Read the description file line by line.
	new String:rawPath[PLATFORM_MAX_PATH];			// raw path as it is found in the description file (with or without "Path_SM/")
	new String:inputFilePath[PLATFORM_MAX_PATH];	// input path in the vpk (without "Path_SM/" if it's there)
	new String:outputFilePath[PLATFORM_MAX_PATH];	// output path on the server (with "addons/sourcemod/" instead of "Path_SM/")
	while (ReadFileLine(updateFile, rawPath, sizeof(rawPath)))
	{
		// Read raw file name.
		new bool:isSourcemodPath = false;
		ReplaceStringEx(rawPath, sizeof(rawPath), "\r", "");
		ReplaceStringEx(rawPath, sizeof(rawPath), "\n", "");
		// Attempt removing "Path_SM/" from the beginning of it; check if this actually worked.
		if (ReplaceStringEx(rawPath, sizeof(rawPath), sourcemodPathAlias, "", -1, -1, false) == 0) // would be nice to figure out the searchLen argument
		{
			isSourcemodPath = true;
		}
		// Create proper input path.
		Format(inputFilePath, sizeof(inputFilePath), "%s/%s", serverDataPath, rawPath);
		// Create proper output path.
		if (isSourcemodPath)
		{
			BuildPath(Path_SM, outputFilePath, sizeof(outputFilePath), rawPath);
		}
		else
		{
			strcopy(outputFilePath, sizeof(outputFilePath), rawPath);
		}
		// Open input file from the vpk.
		new Handle:input = OpenFile(inputFilePath, "rb", true, NULL_STRING);
		if (input == INVALID_HANDLE)
		{
			PrintToServer("[AoF-Updater] Failed to open %s in the vpk.", inputFilePath);
			continue; // read next file
		}
		// Create a temporary file on the server.
		new Handle:temp = OpenFile(tempFilePath, "wb");
		if (temp == INVALID_HANDLE)
		{
			PrintToServer("[AoF-Updater] Failed to create %s on the server.", tempFilePath);
			CloseHandle(input);
			break; // no reason to bother 
		}
		// Copy input file data into the temporary file.
		new const blockSize = 512;
		new buf[blockSize];
		for (;;)
		{
			new count = ReadFile(input, buf, blockSize, 1);
			//PrintToServer("[AoF-Updater] read %d bytes.", count);
			if (count <= 0)
			{
				break;
			}
			WriteFile(temp, buf, count, 1);
		}
		CloseHandle(input);
		CloseHandle(temp);
		// Rename the temporary file as the output file.
		if (!RenameFile(outputFilePath, tempFilePath))
		{
			PrintToServer("[AoF-Updater] Copied %s to %s but couldn't rename it as %s.", inputFilePath, tempFilePath, outputFilePath);
			continue;
		}
		// Done!
		PrintToServer("[AoF-Updater] Updated %s", outputFilePath);
	}
	CloseHandle(updateFile);
	return true;
}

// On map end.
public OnMapEnd()
{
	for (new zone = 0; zone < MAX_SPAWN_ZONES; ++zone)
	{		
		CloseHandle(g_spawns[zone]);
		CloseHandle(g_playerSpawns[zone]);
		CloseHandle(g_activateBlockZones[zone]);
		CloseHandle(g_deactivateBlockZones[zone]);
		g_spawns[zone] = INVALID_HANDLE;
		g_playerSpawns[zone] = INVALID_HANDLE;
		g_activateBlockZones[zone] = INVALID_HANDLE;
		g_deactivateBlockZones[zone] = INVALID_HANDLE;
	}
	CloseHandle(g_removeWeapon);
	g_removeWeapon = INVALID_HANDLE;
	if (g_revealSpawnsTimer != INVALID_HANDLE)
	{
		CloseHandle(g_revealSpawnsTimer);
		g_revealSpawnsTimer = INVALID_HANDLE;
	}
	if (g_sightCheckTimer != INVALID_HANDLE)
	{
		CloseHandle(g_sightCheckTimer);
		g_sightCheckTimer = INVALID_HANDLE;
	}
	PrintToServer("[AoF] =============== MAP END (v%s) ===============", PLUGIN_VERSION);
}

// On round start (the beginning of 15-second ready-up time).
public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	CreateTimer(0.1, Timer_DelayedRoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

public Action:Timer_DelayedRoundStart(Handle timer)
{
	++g_roundNumber;
	
	PrintToChatAll("\x07%s[AoF] ===== %t =====", COLOR_AOF_ROUNDSTART, "round_start", g_roundNumber, PLUGIN_VERSION);
	PrintToServer("[AoF] ===== Round %d start (v%s) =====", g_roundNumber, PLUGIN_VERSION);
	ResetGameProgress(); // reset BEFORE loading BSE!
	
	// New in v1.3c.
	new currCount = 0;
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		if (IsBot(client))
		{
			++currCount;
		}
	}
	if (currCount < BOT_COUNT)
	{
		new toAdd = BOT_COUNT - currCount;
		for (new i = 0; i < toAdd; ++i)
		{
			ServerCommand("ins_bot_add_t2");
		}
		PrintToServer("[AoF] WARNING: manually added %d bots (%d now, just as it is required by AoF). This is an Insurgency bug, or the server is configured incorrectly.", toAdd, BOT_COUNT);
	}
	else if (currCount > BOT_COUNT)
	{
		new toKick = currCount - BOT_COUNT;
		for (new i = 0; i < toKick; ++i)
		{
			ServerCommand("ins_bot_kick_t2");
		}
		PrintToServer("[AoF] WARNING: manually kicked %d bots (%d now, just as it is required by AoF). This is an Insurgency bug, or the server is configured incorrectly.", toKick, BOT_COUNT);
	}
	//if (currCount != BOT_COUNT)
	//{
	//	// "Fix" the bot count issue by restarting the map.
	//	decl String:fullMapName[255];
	//	Format(fullMapName, sizeof(fullMapName), "%s checkpoint", l_mapName);
	//	ForceChangeLevel(fullMapName, "");
	//}
	
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		//g_isInGodMode[client] = false; // don't fix what ain't broken
		g_lastDealtDamageTime[client] = 0.0;
		g_lastTakenDamageTime[client] = 0.0;
		g_godModeValue[client] = 0.0;
	}
	for (new zone = 0; zone < MAX_SPAWN_ZONES; ++zone)
	{
		ClearArray(g_spawns[zone]);
		ClearArray(g_playerSpawns[zone]);
		ClearArray(g_activateBlockZones[zone]);
		ClearArray(g_deactivateBlockZones[zone]);
	}
	ClearArray(g_removeWeapon);
	if (!LoadBse())
	{
		SetFailState("[AoF] ERROR: unable to open %s. Re-download and extract aof_package.zip from the server hosting guide!", l_bseFileName);
	}
	else
	{
		PrintToServer("[AoF] Succesfully parsed %s.", l_bseFileName);
	}
	RemoveSprinklers();
	if (g_isdifVoteReady)
	{
		PrintDifVote();
	}
	CreateTimer(14.7, Timer_AnnounceDifficulty, _, TIMER_FLAG_NO_MAPCHANGE);
	UpdateGameProgress(0); // setup the first zone
	CreateTimer(14.0, Timer_InitiateLastSeenTime, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	//PrintToChatAll("[AoF] ===== Round end =====");
	ResetGameProgress();
	return Plugin_Continue;
}

// Is this client valid?
// Note: IsValidClient already exists. Whatever.
bool:IsOkClient(client)
{
	//if (client < 1 || client > MAX_PLAYERS)
	if (client < 1 || client > GetMaxClients()) // v1.4
	{
		return false;
	}
	return (IsClientInGame(client) && IsClientConnected(client));
}

// Is this client a human?
bool:IsHuman(client)
{
	return (IsOkClient(client) && !IsFakeClient(client));
}

// Is this client a bot?
bool:IsBot(client)
{
	return (IsOkClient(client) && IsFakeClient(client));
}

// Is this client an alive human?
bool:IsAliveHuman(client)
{
	return (IsHuman(client) && IsPlayerAlive(client));
}

// Is this client an alive bot?
bool:IsAliveBot(client)
{
	return (IsBot(client) && IsPlayerAlive(client));
}

bool:IsDeadOrSpectator(client)
{
	return (IsHuman(client) && !IsPlayerAlive(client));
}

bool:IsSpectatingClient(spectator, client)
{
	// Returns whether the 'spectator' is spectating the 'client'.
	if (!IsDeadOrSpectator(spectator) || !IsAliveHuman(client))
	{
		return false;
	}
	//PrintToChatAll("[AoF-Debug] Distance check between spectator %d and client %d.", spectator, client);
	decl Float:spectatorPos[3], Float:clientPos[3];
	GetClientAbsOrigin(spectator, spectatorPos);
	GetClientAbsOrigin(client, clientPos);
	//PrintToChatAll("[AoF-Debug] Spectator pos: %0.f %0.f %0.f", spectatorPos[0], spectatorPos[1], spectatorPos[2]);
	//PrintToChatAll("[AoF-Debug] client pos: %0.f %0.f %0.f", clientPos[0], clientPos[1], clientPos[2]);
	//PrintToChatAll("[AoF-Debug] Squared distance from spectator %d to client %d: %.2f.", spectator, client, GetVectorDistance(spectatorPos, clientPos, true));
	// Major most of the time the distance check returns 0.00 units.
	// However, *sometimes* it produces weird values, such as ~18 or so (which equals sqrt(18) map units).
	// So let's have a few map units of room for error.
	static Float:maxError = 25.0;
	return (GetVectorDistance(spectatorPos, clientPos, true) < maxError);
}

// Restores health for all alive and hurt human players.
RestoreHealthForAliveHumans()
{
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		if (IsAliveHuman(client))
		{
			if (GetClientHealth(client) < 100)
			{
				SetEntityHealth(client, 100);
				g_lastHealth[client] = 100;
				PrintToChat(client, "\x07%s[AoF] %t", COLOR_AOF_HEALTH_RESTORED, "health_restored");
			}
		}
	}
}

// Prints 'Playername is down' message.
void PrintHumanDeath(client)
{
	decl String:playerName[255], String:className[255];
	GetClientName(client, playerName, sizeof(playerName));
	for (new cl = 1; cl <= GetMaxClients(); ++cl)
	{
		if (IsOkClient(cl))
		{
			Format(className, sizeof(className), "%T", l_playerClassName[g_playerClass[client]], cl);
			PrintToChat(cl, "\x07%s[AoF] %t", COLOR_AOF_PLAYER_DOWN, "player_down", playerName, className);
		}
	}
	Format(className, sizeof(className), "%T", l_playerClassName[g_playerClass[client]], LANG_SERVER);
	PrintToServer("[AoF] %T", "player_down", LANG_SERVER, playerName, className);
}

public Action:Timer_PrintTip(Handle timer, any serial)
{
	new client = GetClientFromSerial(serial);
	new classIndex = g_playerClass[client];
	if (!IsHuman(client) || !serverEnableTips)
	{
		return Plugin_Continue;
	}
	new tipIndex = (classIndex >= 0 && classIndex < 5 && GetURandomFloat() < 0.70) ? classIndex : 5;
	decl String:className[255] = "general";
	if (tipIndex < 5)
	{
		className = l_playerClassName[tipIndex];
	}
	decl String:keyCount[255];
	Format(keyCount, sizeof(keyCount), "tip_%s_count", className);
	decl String:valueCount[10];
	Format(valueCount, sizeof(valueCount), "%T", keyCount, client);
	new tipCount = StringToInt(valueCount);
	if (tipCount <= 0)
	{
		return Plugin_Continue;
	}
	decl String:keyTip[255];
	Format(keyTip, sizeof(keyTip), "tip_%s_%d", className, GetRandomInt(1, tipCount));
	PrintToChat(client, "\x07%s[AoF] %t", COLOR_AOF_TIP, keyTip);
	return Plugin_Continue;
}

// When a player spawns.
public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IsOkClient(client))
	{
		return Plugin_Continue;	
	}
	
//	if (IsHuman(client))
//	{
//		SetConVarInt(FindConVar("sv_cheats"), 1, false, false);
//		FakeClientCommand(client, "give_supply 1");
//		SetConVarInt(FindConVar("sv_cheats"), 0, false, false);
//	}
	
	g_lastHealth[client] = 100;
	if (serverDebugBotSpawns2)
	{
		decl String:playerName[255];
		GetClientName(client, playerName, sizeof(playerName));
		PrintToServer("[AoF-Debug2] [%08.3f] Client %2d |%14s| spawned.", GetGameTime(), client, playerName);
	}
	if (IsBot(client))
	{
		g_botLastSeen[client] = 0.0;
		if (g_isInGame)
		{
			// Don't teleport bots anywhere if g_dummySpot is not initialized or relevant.
			TeleportEntity(client, g_dummySpot, NULL_VECTOR, NULL_VECTOR);
		}
	}
	if (IsHuman(client))
	{
		// Reset any existing fades - just in case.
		CreateDelayedFade(client, 0.0, 0.0, 0.1, (FFADE_PURGE|FFADE_IN), 255, 255, 255, 255);
		//CreateTimer(0.1, Timer_CheckCustomPlayerSpawn, client);
		if (g_curZone != -1)
		{
			new size = GetArraySize(g_playerSpawns[g_curZone]);
			if (IsAliveHuman(client) && (size > 0))
			{
				new Float:spawnPos[3];
				GetArrayArray(g_playerSpawns[g_curZone], g_playerSpawnIndex, spawnPos);
				g_playerSpawnIndex = (g_playerSpawnIndex + 1) % size;
				TeleportEntity(client, spawnPos, NULL_VECTOR, NULL_VECTOR);
			}
		}
		if (IsAliveHuman(client))
		{
			// I additionally check that the player is alive because "player_spawn" also gets called when he initially picks a squad without spawning yet.
			if (!g_hasSpawnedBefore[client] && g_isInGame)
			{
				//PrintDifficulty(client);
				CreateTimer(0.5, Timer_AnnounceDifficultyToOne, client, TIMER_FLAG_NO_MAPCHANGE);
			}
			g_hasSpawnedBefore[client] = true;
		}
	}
	
	return Plugin_Continue;
}

/*
public Action:Timer_CheckCustomPlayerSpawn(Handle timer, client)
{
	//if (g_isFinale && IsAliveHuman(client))
	//{
	//	TeleportEntity(client, g_finalePlayerSpawn[GetRandomInt(0, 4)], NULL_VECTOR, NULL_VECTOR);
	//}
	new size = GetArraySize(g_playerSpawns[g_curZone]);
	if (IsAliveHuman(client) && (size > 0))
	{
		new Float:spawnPos[3];
		GetArrayArray(g_playerSpawns[g_curZone], g_playerSpawnIndex, spawnPos);
		g_playerSpawnIndex = (g_playerSpawnIndex + 1) % size;
		TeleportEntity(client, spawnPos, NULL_VECTOR, NULL_VECTOR);
	}
}
*/

// Before a player is hurt.
public Action:Event_PlayerHurtPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (serverDebugDamage)
	{
		new attacker  = GetClientOfUserId(GetEventInt(event, "attacker"));
		new victim = GetClientOfUserId(GetEventInt(event, "userid"));
		new dmg = GetEventInt(event, "dmg_health");
		new health = GetEventInt(event, "health");
		new hitgroup  = GetEventInt(event, "hitgroup")
		decl String:weaponName[255], String:attackerName[255], String:victimName[255];
		GetEventString(event, "weapon", weaponName, sizeof(weaponName));
		if (attacker == 0)
		{
			attackerName = "* World *";
		}
		else
		{
			GetClientName(attacker, attackerName, sizeof(attackerName));
		}
		GetClientName(victim, victimName, sizeof(victimName));
		PrintToChatAll("\x07%s[AoF] %s attacked %s with %s for %d hp (hitgroup %s, %d hp left).",
						COLOR_AOF_DEBUG, attackerName, victimName, weaponName, dmg, l_hitgroupName[hitgroup], health);
	}
	return Plugin_Continue;
}

// When a player picks squad.
public Action:Event_PlayerPickSquad(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	decl String:playerName[255];
	GetClientName(client, playerName, sizeof(playerName));
	if (IsFakeClient(client))
	{
		// Bot.
		decl String:classTemplateName[100];
		GetEventString(event, "class_template", classTemplateName, sizeof(classTemplateName));
		new botClassIndex;
		if (!l_botClassNameToIndex.GetValue(classTemplateName, botClassIndex))
		{
			botClassIndex = bcUnknown;
		}
		g_playerClass[client] = botClassIndex;
		g_botLastSeen[client] = 0.0;
	}
	else
	{
		// Human.
		new squad = GetEventInt(event, "squad");
		new squad_slot = GetEventInt(event, "squad_slot");
		new classIndex = (squad == 0 ? squad_slot : (squad == 1 ? view_as<int>(hcSwapSlot) : view_as<int>(hcBotClass)));
		g_playerClass[client] = classIndex;
		for (new human = 1; human <= GetMaxClients(); ++human)
		{
			if (IsHuman(human))
			{
				decl String:className[255];
				Format(className, sizeof(className), "%T", l_playerClassName[g_playerClass[client]], human);
				if (human == client)
				{
					PrintToChat(human, "\x07%s[AoF] %t", COLOR_AOF_SELECTED_CLASS, "you_selected_class", className);
				}
				else
				{
					PrintToChat(human, "\x07%s[AoF] %t", COLOR_AOF_SELECTED_CLASS, "another_player_selected_class", playerName, className);
				}
			}
		}
	}
	return Plugin_Continue;
}

// After a player dies.
public Action:Event_PlayerDeathPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new bool:isSuicide = (client == attacker);
	g_lastHealth[client] = 0;
	//SetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue", 1.00);
	if (serverDebugBotSpawns2)
	{
		decl String:playerName[255];
		GetClientName(client, playerName, sizeof(playerName));
		if (isSuicide)
		{		
			PrintToServer("[AoF-Debug2] [%08.3f] Client %2d |%14s| died (suicide).", GetGameTime(), client, playerName);
		}
		else if (attacker == 0)
		{
			PrintToServer("[AoF-Debug2] [%08.3f] Client %2d |%14s| died (killed by the world).", GetGameTime(), client, playerName);
		}
		else if (IsOkClient(attacker))
		{
			decl String:attackerName[255];
			GetClientName(attacker, attackerName, sizeof(attackerName));
			PrintToServer("[AoF-Debug2] [%08.3f] Client %2d |%14s| died (killed by client %2d |%14s|).", GetGameTime(), client, playerName, attacker, attackerName);
		}
		else
		{
			PrintToServer("[AoF-Debug2] [%08.3f] Client %2d |%14s| died (killed by an unknown entity index %d).", GetGameTime(), client, playerName, attacker);
		}
	}
	if (IsBot(client))
	{
		if (g_hideBodiesNow)
		{
			CreateTimer(0.1, Timer_RemoveRagdoll, client, TIMER_FLAG_NO_MAPCHANGE);
		}
		else
		{
			DataPack pack;
			CreateDataTimer(0.2, Timer_HandleBotDeath, pack, TIMER_FLAG_NO_MAPCHANGE);
			pack.WriteCell(client);
			pack.WriteCell(attacker);
		}
		if (!isSuicide)
		{
			CreateTimer(0.1, Timer_UpdateBotCount, _, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	if (IsHuman(client))
	{
		PrintHumanDeath(client);
		CreateTimer(3.0, Timer_PrintTip, GetClientSerial(client), TIMER_FLAG_NO_MAPCHANGE);
		if (g_playerClass[client] == view_as<int>(hcScavenger) && serverPrintHealth)
		{
			// This cleanly prints "0 HP" for Scavengers when they die.
			// May occasionally print it when it shouldn't but that's fine.
			PrintHealth(client);
		}
		//DebugDumpAllTips(client);
	}
	return Plugin_Continue;
}

/*
void DebugDumpAllTips(client)
{
	for (new i = 0; i <= 5; ++i)
	{
		decl String:className[255] = "general";
		if (i < 5)
		{
			className = l_playerClassName[i];
		}
		decl String:keyCount[255];
		Format(keyCount, sizeof(keyCount), "tip_%s_count", className);
		decl String:valueCount[10];
		Format(valueCount, sizeof(valueCount), "%T", keyCount, client);
		new tipCount = StringToInt(valueCount);
		for (new tip = 1; tip <= tipCount; ++tip)
		{
			decl String:keyTip[255];
			Format(keyTip, sizeof(keyTip), "tip_%s_%d", className, tip);
			PrintToChat(client, "\x07%s[AoF] %t", COLOR_AOF_TIP, keyTip);
		}
	}
}
*/

public Action:Timer_RemoveRagdoll(Handle timer, client)
{
	new ragdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
	if (IsValidEdict(ragdoll))
	{
		RemoveEdict(ragdoll);
	}
	else
	{
		PrintToServer("[AoF-BotSpawns] Unable to locate the ragdoll.");
	}
	return Plugin_Continue;	
}

public Action:Event_PlayerBlindPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new Float:m_flFlashMaxAlpha = GetEntPropFloat(client, Prop_Send, "m_flFlashMaxAlpha");
	new Float:m_flFlashDuration = GetEntPropFloat(client, Prop_Send, "m_flFlashDuration");
	//PrintToChatAll("[AoF-Debug] Player #%d is blind; m_flFlashMaxAlpha = %.2f, m_flFlashDuration = %.2f.", client, m_flFlashMaxAlpha, m_flFlashDuration);
	if (IsHuman(client))
	{
		new Float:decreaseAmount = (GetRealHumanClass(client) == view_as<int>(hcScavenger) ? 140.0 : 238.0);
		m_flFlashMaxAlpha = MaxFloat(0.0, m_flFlashMaxAlpha - decreaseAmount); // before: -160.0
		//PrintToChatAll("[AoF-Debug] m_flFlashMaxAlpha = %f (decreased by %f).", m_flFlashMaxAlpha, decreaseAmount);
		//m_flFlashDuration *= 0.7;
	}
	if (IsBot(client))
	{
		// This won't work - it doesn't actually affect the AI.
		//m_flFlashDuration = MaxFloat(m_flFlashDuration, GetRandomFloat(4.0, 6.0));
	}
	SetEntPropFloat(client, Prop_Send, "m_flFlashMaxAlpha", m_flFlashMaxAlpha);
	SetEntPropFloat(client, Prop_Send, "m_flFlashDuration", m_flFlashDuration);
	return Plugin_Handled;
}

stock ForcePlayerSuicide2(client)
{
	// https://forums.alliedmods.net/showthread.php?t=156427
	new ent = CreateEntityByName("point_hurt");
	if (ent != -1)
	{
		DispatchKeyValue(client, "targetname", "forcesuicide");
		DispatchKeyValue(ent, "DamageTarget", "forcesuicide");
		DispatchKeyValue(ent, "Damage", "1000");
		DispatchKeyValue(ent, "DamageType", "0");
		DispatchSpawn(ent);
		AcceptEntityInput(ent, "Hurt");
		DispatchKeyValue(client, "targetname", "dontsuicide");
		AcceptEntityInput(ent, "Kill");
	}
}

public bool:OnClientConnect(client, String:rejectmsg[], maxlen)
{
	// One of the servers had a weird issue that allowed the 6th player to connect,
	// resulting in 6/5 players on the server. No clue why, but let's prevent that from happening.
	new playerCount = 0;
	//for (new i = 1; i <= MAX_PLAYERS; ++i)
	for (new i = 1; i <= GetMaxClients(); ++i)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			++playerCount;
		}
	}
	if (playerCount >= 6)
	{
		Format(rejectmsg, maxlen, "Server is full (5/5)");
		return false;
	}
	return true;
}

public OnClientPutInServer(client)
{
	SDKHook(client, SDKHook_WeaponDrop, OnWeaponDrop);
	SDKHook(client, SDKHook_WeaponEquip, OnWeaponEquip);
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	//CreateTimer(10.0, Timer_AnnounceDifficultyToOne, client, TIMER_FLAG_NO_MAPCHANGE); // lol don't do this
	g_hasSpawnedBefore[client] = false; // just in case.
}

public Action:Event_PlayerDisconnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	g_hasSpawnedBefore[client] = false;
}

// On weapon drop.
public Action:OnWeaponDrop(client, weapon)
{
	decl String:weaponName[32];
	GetEdictClassname(weapon, weaponName, sizeof(weaponName));
	if (IsFakeClient(client) && g_hideBodiesNow)
	{
		//PrintToChatAll("[AoF-Debug] Trying to remove '%s' dropped by bot #%d.", weaponName, client);
		return Plugin_Handled;
	}
	
	// Let's remove guns with very little (or none) ammunition in them.
	// Unfortunately I failed to port the Ins_GetWeaponGetMaxClip1 native (it just won't work).
	// EDIT: none of these approaches work well:
	// 1) return Plugin_Handled - completely prevents you from picking up a gun if yours is empty.
	// 2) RemoveEdict - crashes the server (segfault).
	// 3) 0.1 second timer + RemoveEdict - too much delay, you can even re-pickup the dropped gun and then it disappears in your hands.
	// I guess it should be possible to mark this entity for removal on the next game tick though.
	// NEW: yup, let's try the mark-for-removal approach. It appears to work.
	new ammo = GetEntProp(weapon, Prop_Send, "m_iClip1", 1);
	//PrintToChatAll("[AoF-Debug] Client %d droppped weapon %d (%s) with %d ammo left in it.", client, weapon, weaponName, ammo);
	if (ammo <= 2) // experimental for v1.4; used to be 0
	{
		//if (IsAliveBot(client) || (IsAliveHuman(client) && GetRealHumanClass(client) == view_as<int>(hcScavener)))
		// Only shitty bot weapons can disappear. The weapons dropped by other human classes never will.
		if (StrContains(weaponName, "_bot") != -1)
		{
			//1) return Plugin_Handled;
			//2) RemoveEdict(weapon);
			//3) CreateTimer(0.1, Timer_RemoveEntity, weapon, TIMER_FLAG_NO_MAPCHANGE);	
			PushArrayCell(g_removeWeapon, weapon);
			//PrintToChatAll("[AoF-Debug] Pushed weapon %d into the removal array. New array size: %d.", weapon, GetArraySize(g_removeWeapon));
		}
	}
	
	return Plugin_Continue;
}

public Action:OnWeaponEquip(client, weapon)
{
	decl String:weaponName[32];
	GetEdictClassname(weapon, weaponName, sizeof(weaponName));
	
	// Turn the m249 lasersight off for humans.
	if (StrEqual(weaponName, "weapon_m249_bot") && IsAliveHuman(client))
	{
		//PrintToChatAll("[AoF-Debug] Disabling lasersight for client %d!", client);
		SetEntProp(weapon, Prop_Send, "m_bLaserOn", 0);
	}
	if (StrEqual(weaponName, "weapon_m590_bot") && IsAliveHuman(client))
	{
		//PrintToChatAll("[AoF-Debug] Disabling flashlight for client %d!", client);
		SetEntProp(weapon, Prop_Send, "m_bFlashlightOn", 0);
	}
}

public Action:Timer_RemoveEntity(Handle timer, entity)
{
	RemoveEdict(entity);
	return Plugin_Continue;
}

GetRealHumanClass(human)
{
	if (!IsAliveHuman(human))
	{
		return g_playerClass[human]; // remember: this data is not initialized. Don't use it for non-existent clients!
	}
	// Here's how this works. Each class has a different melee weapon in the theater.
	// For example, rifleman's melee is "weapon_kabar_rifleman".
	// They all work identically (except for the scavenger's melee).
	// By searching for the substring of the class name, we can figure out which class
	// this user is actually playing is right now. If you select a different class
	// without resupplying, this will still return your actual current class.
	// This hack is reliable because you can neither drop nor change your melee weapon.	
	new playerMelee = GetPlayerWeaponSlot(human, 2);
	decl String:playerMeleeName[255];
	GetEntityClassname(playerMelee, playerMeleeName, sizeof(playerMeleeName));
	for (new i = 0; i < view_as<int>(TOTAL_PLAYER_CLASSES); ++i)
	{
		if (StrContains(playerMeleeName, l_playerClassName[i], false) != -1)
		{
			return i;
		}
	}
	return hcUnknown;
}

// On take damage.
public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
	// Sanity check: victim must be a client.
	if (!IsOkClient(victim))
	{
		return Plugin_Continue;
	}
	
	// Victims in godmode take no damage - even from the world (which is not a client).
	if (g_isInGodMode[victim])
	{
		//PrintToChatAll("[AoF-Debug] You're in god mode - damage (%.2f) ignored.", damage);
		return Plugin_Handled;
	}
	
	// Now, the further code will *only* handle attacks caused by clients.
	if (!IsOkClient(attacker))
	{
		return Plugin_Continue;
	}
	
	// Modify the damage.
	damage = ModifyDamage(victim, attacker, damage, damagetype);
	
	// If Rifleman attacks a bot, update godmode.
	if (IsAliveHuman(attacker) && IsBot(victim) && (GetRealHumanClass(attacker) == view_as<int>(hcRifleman)))
	{
		UpdateGodMode(victim, attacker, damage, damagetype);
	}
	
	// If Scavenger attacks a bot, update godmode.
	if (IsAliveHuman(attacker) && IsBot(victim) && (GetRealHumanClass(attacker) == view_as<int>(hcScavenger)))
	{
		UpdateScavengerVampire(victim, attacker, damage, damagetype);
	}

	// Return updated damage.
	return (damage < 0.1 ? Plugin_Handled : Plugin_Changed);
}

Float:ModifyDamage(victim, attacker, Float:damage, damagetype)
{
	decl String:weaponName[MAX_WEAPON_LEN];
	GetClientWeapon(attacker, weaponName, sizeof(weaponName));
	
	if (IsAliveBot(victim))
	{
		// A bot was hurt by someone.
		new bot = victim;
		new botClass = g_playerClass[bot];
		if (IsAliveHuman(attacker))
		{
			// A bot was hurt by a human.
		//	new human = attacker;
		//	new humanClass = GetRealHumanClass(human);
			//if (some_debug)
			//{
			//	decl String:playerName[255];
			//	GetClientName(bot, playerName, sizeof(playerName));
			//	new bool:isHeavy = (g_playerClass[bot] == view_as<int>(bcHeavy));
			//	PrintToServer("[AoF] Bot %s (%s) was damaged with %s (flags: %d) for %.2f hp.",
			//					playerName, (isHeavy ? "Heavy" : "regular"), weaponName, damagetype, damage);
			//}
			switch (botClass)
			{
				case bcHeavy:
				{
					// A Heavy bot was hurt by a human.
					if ((damagetype & DMG_BLAST) != 0)
					{
						// A Heavy bot was hurt by a human's explosive (Grenadier's launcher, Marksman's C4, or regular grenades).
						// Reduce this damage. In insurgency, armors provides no protection against explosives at all.
						// This lets Grenadier kill Heavies in one grenade launcher shot only if it was accurate enough.
						// UPD: Marksman no longer has C4 and the game actually provides a way to have explosive
						// protection on the theater level. Still, no reason to change and rebalance this.
						damage *= 0.28;
						//PrintToServer("[AoF] Damage dealt by an explosive to some Heavy bot: %.2f.", damage);
					}
					if ((damagetype & DMG_BURN) != 0)
					{
						// A Heavy bot was hurt by a human's molotov.
						// This makes Heavies resistant to burn damage as well.
						// EDIT: except there are no more mollies in the mod.
						damage *= 0.50;
					}
					if ((damagetype & DMG_CRUSH) != 0)
					{
						// A Heavy bot was hurt by a collision impact damage.
						// Odds are it was a direct grenade hit by Grenadier's launcher.
						// Or a Scavenger's flashbang.
						// Heavy bots should only be hurt by this, not killed instantly.
						damage = 60.0;
					}
					if (StrContains(weaponName, "weapon_kabar") != -1)
					{
						// A Heavy bot was knifed by a non-Scavenger.
						if (damage > 100.0)
						{
							// A Heavy bot was knifed in the back by a non-Scavenger.
							// Uncomment to prevent non-Scavengers from knifing Heavies in the back in a single hit.
							damage = 60.0;
						}
					}
					if (StrEqual(weaponName, "weapon_m39"))
					{
						// A Heavy bot was shot by a player with M39 EMR.
						// If the bullet penetrated something, its damage is decreased significantly.
						// We would still like to guarantee a 2-shot kill on a Heavy regardless.
						damage = MaxFloat(51.0, damage);
					}
					if (StrEqual(weaponName, "weapon_galil_sar")	||
						StrEqual(weaponName, "weapon_m4a1")			||
						StrEqual(weaponName, "weapon_ak74")			||
						StrEqual(weaponName, "weapon_fal")			||
						StrEqual(weaponName, "weapon_akm")			||
						StrEqual(weaponName, "weapon_mk18")
						)
					{
						// Tweak the damage of Rifleman's weapons.
						damage *= 1.00;
					}
					if (StrEqual(weaponName, "weapon_br99"))
					{
						// Tweak the damage of Breacher's shotgun.
						damage *= 1.20;
					}
					if (StrEqual(weaponName, "weapon_sterling")	||
						StrEqual(weaponName, "weapon_mp40"))
					{
						// Tweak the damage of Breacher's secondaries.
						damage *= 1.40;
					}
					if (StrEqual(weaponName, "weapon_m590_bot"))
					{
						// Tweak the damage of the bot's shotgun.
						damage *= 1.20;
					}
					// Otherwise keep it as is.
				}
				default:
				{
					if ((damagetype & DMG_CRUSH) != 0)
					{
						// A regular bot was hurt by a collision impact damage.
						// Odds are it was a direct grenade hit by Grenadier's launcher.
						// Regular bots should die instantly from this.
						damage = 101.0;
					}
					// A regular bot was hurt by a human.
					if (StrEqual(weaponName, "weapon_snub"))
					{
						// A regular bot was hurt by a human's snub.
						// Reduce this damage significantly.
						damage *= 0.70;
					}
					if (StrContains(weaponName, "weapon_gurkha") != -1 || StrContains(weaponName, "weapon_machete") != -1)
					{
						// A regular bot was knifed by Scavenger.
						// This should be an instant kill, no matter whether it's from the front or from the back.
						damage = 101.0;
					}
					if (StrEqual(weaponName, "weapon_m39"))
					{
						// A regular bot was shot by M39 EMR
						// This should be an instant kill, even if it penetrated something beforehand.
						damage = MaxFloat(101.0, damage);		
					}
					if (StrEqual(weaponName, "weapon_galil_sar")	||
						StrEqual(weaponName, "weapon_m4a1")			||
						StrEqual(weaponName, "weapon_ak74")			||
						StrEqual(weaponName, "weapon_fal")			||
						StrEqual(weaponName, "weapon_akm")			||
						StrEqual(weaponName, "weapon_mk18")
						)
					{
						// Tweak the damage of Rifleman's weapons.
						damage *= 1.00;
					}
					// Otherwise keep it as is.
				}
			}
		}
		else
		{
			// A bot was hurt by another bot.
			// Disable team damage between bots.
			damage = 0.0;
		}
	}
	else
	{
		// A human was hurt by someone.
		new human = victim;
		new humanClass = GetRealHumanClass(human);
		if (IsAliveHuman(attacker))
		{
			// A human was hurt by a human.
			new otherHuman = attacker;
			new otherHumanClass = GetRealHumanClass(otherHuman);
			if (human == attacker)
			{
				// A human hurt themselves.
				if (otherHumanClass == view_as<int>(hcGrenadier))
				{
					if ((damagetype & DMG_BLAST) != 0)
					{
						// Grenadier does not hurt himself with explosives.
						// Yes, I'm aware this includes cooking a grenade until it goes off in your hand.
						// Yes, other classes might blow themselves up if they pick up dead Grenadier's primary.
						damage = 0.0;
					}
					if ((damagetype & DMG_BURN) != 0)
					{
						// Grenadier does very little damage to himself with his Molotovs.
						// EDIT: Mollies are long gone from the mod though..
						damage *= 0.07;
					}
					// Somehow the Grenadier hurt himself with neither blast nor burn damage.
					// Keep it as-is.		
				}
				// A non-Grenadier hurt themselves.
				// Keep it as-is.
			}
			// A human was attacked by another human. Disable team damage between players.
			// Later this may be handled better so that team damage is not completely gone.
			damage = 0.0;
		}
		else
		{
			// A human was hurt by a bot.
		//	new bot = attacker; // unused
		//	new botClass = g_playerClass[bot];
			if ((damagetype & DMG_BLAST) != 0)
			{
				// A human was hurt by a bot's explosive. Must be a F1 grenade.
				// Reduce this damage. Instant deaths by grenades ain't that fun.
				switch (humanClass)
				{
					case hcScavenger:
					{
						// A human Scavenger was hurt by a bot's explosive.
						// Reduce this damage significantly.
						damage *= 0.35;
					}
					default:
					{
						// A non-Scavenger human was hurt by a bot's explosive.
						// Reduce this damage. A grenade should now instantly kill you only 
						// if you're sitting on top of it or if you've already been hurt before.
						damage *= 0.65;
						decl String:playerName[255];
						GetClientName(human, playerName, sizeof(playerName));
						//PrintToServer("[AoF] Damage dealt by a grenade to %s: %.2f.", playerName, damage);
					}
				}
			}
			else
			{
				// A human was hurt by a bot with non-explosive damage.
				if (StrEqual(weaponName, "weapon_m590_bot"))
				{
					// A human was hurt by a bot's shotgun.
					// Reduce this damage. M590 is only powerful in human's hands.
					damage *= 0.50;
				}
				else
				{
					// A human was hurt by a bot bullet (not a grenade, not a shotgun pellet).
					switch (humanClass)
					{
						case hcScavenger:
						{
							// The anesthetic mechanic.
							if (RoundToNearest(damage) >= 1) // don't bother doing anything if Scavenger was hurt by 0 hp by a bullet. Somehow.
							{
								new Float:timeSinceLastDamage = (GetGameTime() - g_lastTakenDamageTime[human]) + 0.0001; // avoid division by zero without modifying the logic.
								g_lastTakenDamageTime[human] = GetGameTime();
								new Float:newDamage = MaxFloat(1.0, damage * MinFloat(1.0, timeSinceLastDamage / l_scavengerAnesthetic)); // scale damage by 0.0 .. 1.0, but at least 1 HP.
								l_scavengerAnestheticDebug[human] += (RoundToNearest(damage) - RoundToNearest(newDamage));
								damage = newDamage;
								if (serverDebugAnesthetic)
								{
									new String:shortWeaponName[255];
									strcopy(shortWeaponName, sizeof(shortWeaponName), weaponName);
									ReplaceStringEx(shortWeaponName, sizeof(shortWeaponName), "weapon_", "");
									ReplaceStringEx(shortWeaponName, sizeof(shortWeaponName), "_bot", "");
									PrintToChatAll("\x07%s[AoF-Debug] Shot with %s for %d HP (x%.3f), saved %d HP.",
										COLOR_AOF_DEBUG, shortWeaponName, RoundToNearest(damage), MinFloat(1.0, timeSinceLastDamage / l_scavengerAnesthetic), l_scavengerAnestheticDebug[human]);
								}
							}
						}
						default:
						{
						}
					}
				}
			}
		}
	}
	return damage;
}

void UpdateGodMode(bot, human, Float:rawDamage, damagetype)
{
	// Don't give any additional godmode percentage if you're currently in godmode as is.
	if (g_isInGodMode[human])
	{
		return;
	}
	
	new Float:dmg = Min(RoundToNearest(rawDamage), GetClientHealth(bot)) * 1.0;
	switch (g_playerClass[bot])
	{
		case bcHeavy:
		{
			dmg *= l_godModeDamageHeavyModifier;
		}
		default:
		{
		}
	}
	
	dmg *= l_godModeDamageDefaultScale;
	dmg *= l_godModeDamageDifficultyModifier[serverDifficulty];
	if ((damagetype & DMG_BLAST) != 0)
	{
		dmg *= l_godModeDamageExplosiveScale;
	}
	//PrintToChatAll("[AoF-Debug] %.2f points of damage towards godmode.", dmg);
	
	g_godModeValue[human] += dmg;
	g_lastDealtDamageTime[human] = GetGameTime();
	
	if (g_godModeValue[human] > 100.0)
	{
		EnableGodMode(human);
	}
}

void UpdateScavengerVampire(bot, human, Float:rawDamage, damagetype)
{
	// Did the Scavenger actually use his melee for this damage?
	decl String:weaponName[MAX_WEAPON_LEN];
	GetClientWeapon(human, weaponName, sizeof(weaponName));
	if (StrContains(weaponName, "machete") == -1 || StrContains(weaponName, "scavenger") == -1 || (damagetype & DMG_SLASH) == 0)
	{
		return;
	}
	
	// Is this going to be a kill? We can't just check the bot's health because the damage has not been applied yet.
	new currBotHealth = GetClientHealth(bot);
	new estimatedBotHealth = currBotHealth - RoundToNearest(rawDamage);
	//PrintToChatAll("[AoF-Debug] Bot (client %d) - should have %d HP.", bot, estimatedBotHealth);
	if (estimatedBotHealth > 0)
	{
		return;
	}
	
	new Float:reward = 0.0;
	switch (g_playerClass[bot])
	{
		case bcHeavy:
		{
			reward = l_scavengerVampireRewardHeavy;
		}
		default:
		{
			reward = l_scavengerVampireRewardNormal;
		}
	}
	new health = Min(100, GetClientHealth(human) + RoundToNearest(reward));
	SetEntityHealth(human, health);
	g_lastHealth[human] = health;
}

SecondsToFadeTime(Float:sec)
{
	// The format of screen fade duration data is a 16-bit short value, where
	// the lower 9 bits represent the fractional part (as defined by SCREENFADE_FRACBITS).
	// The following produces such value from a regular Float.
	return RoundToNearest(sec * 512);
}

void CreateDelayedFade(client, Float:delay, Float:fadeTime, Float:fadeAndHoldTime, flags, colorR, colorG, colorB, colorA)
{
	DataPack pack;
	CreateDataTimer(delay, Timer_CreateDelayedFade, pack);
	pack.WriteCell(client);
	pack.WriteFloat(fadeTime);
	pack.WriteFloat(fadeAndHoldTime);
	pack.WriteCell(flags);
	pack.WriteCell(colorR);
	pack.WriteCell(colorG);
	pack.WriteCell(colorB);
	pack.WriteCell(colorA);
}

public Action:Timer_CreateDelayedFade(Handle timer, DataPack pack)
{
	ResetPack(pack);
	new client = pack.ReadCell();
	if (!IsOkClient(client))
	{
		return Plugin_Handled;
	}
	new Handle:hFadeClient = StartMessageOne("Fade", client);
	BfWriteShort(hFadeClient, SecondsToFadeTime(pack.ReadFloat()));	// fade time
	BfWriteShort(hFadeClient, SecondsToFadeTime(pack.ReadFloat()));	// fade & hold (total) time
	BfWriteShort(hFadeClient, pack.ReadCell());						// fade flags
	BfWriteByte(hFadeClient, pack.ReadCell());	// fade red
	BfWriteByte(hFadeClient, pack.ReadCell());	// fade green
	BfWriteByte(hFadeClient, pack.ReadCell());	// fade blue
	BfWriteByte(hFadeClient, pack.ReadCell());	// fade alpha
	EndMessage();
	return Plugin_Handled;
}

void EnableGodMode(rifleman)
{
	// The god mode counter goes beyond 100.0 internally, although the printed text is capped at 100%.
	// This is done to let it briefly stay at 100% before starting to decrease while avoiding unnecessary timers.
	g_godModeValue[rifleman] = l_godModeActiveInternalStart;
	g_isInGodMode[rifleman] = true;
	SetEntityRenderColor(rifleman, 255, 180, 40, 255);	
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		// This is a grossly inefficient check but it gets the job done.
		if ((client == rifleman) || IsSpectatingClient(client, rifleman))
		{
			CreateDelayedFade(client, 0.0, 0.2, l_godModeDuration,			(FFADE_PURGE|FFADE_MODULATE|FFADE_OUT),	255, 160, 0, 167);
			CreateDelayedFade(client, 1.0, 0.5, l_godModeDuration - 1.0,	(FFADE_PURGE|FFADE_MODULATE|FFADE_IN),	255, 160, 0, 167);
		}
	}
}

public OnGameFrame()
{
	new Float:curTime = GetGameTime();
	new bool:updateFlashlight = false;
	if (curTime - g_flashlightTickLastUpdate > 0.5)
	{
		g_flashlightTickLastUpdate = curTime;
		updateFlashlight = true;
	}
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		GodModeTick(client, curTime);
		ScavengerVampireTick(client);
		//MarksmanWallhackTick(client); // unused test mechanic
		if (updateFlashlight)
		{
			FlashlightTick(client);
		}
		ForceHealthAfterResupplyTick(client);
	}
	WeaponRemovalTick();
}

void GodModeTick(client, Float:curTime)
{
	if (IsAliveHuman(client) && GetRealHumanClass(client) == view_as<int>(hcRifleman))
	{
		if (g_isInGodMode[client])
		{
			g_godModeValue[client] -= l_godModeActiveDecayRate;
			if (g_godModeValue[client] < 0.0)
			{
				g_godModeValue[client] = 0.0;
				g_lastDealtDamageTime[client] = 0.0;
				g_isInGodMode[client] = false;
			//	PrintToChat(client, "[AoF-Debug] Godmode deactivated!");
				SetEntityRenderColor(client, 255, 255, 255, 0);
			}
		}
		else
		{
			if (curTime - g_lastDealtDamageTime[client] > l_godModeFreezeTimeOnDamage)
			{
				g_godModeValue[client] = MaxFloat(0.0, g_godModeValue[client] - l_godModeInactiveDecayRate);
			}
		}
		new godModeValue = Min(RoundToNearest(g_godModeValue[client] - 0.499), 100);
		PrintCenterText(client, "%t", (g_isInGodMode[client] ? "godmode_active" : "godmode_inactive"), godModeValue);
	}
	else
	{
		if (g_godModeValue[client] > 0.0)
		{
			if (IsAliveHuman(client))
			{
				SetEntityRenderColor(client, 255, 255, 255, 0);
			}
		}
		g_godModeValue[client] = 0.0;
		g_lastDealtDamageTime[client] = 0.0;
		g_isInGodMode[client] = false;
	}
}

void ScavengerVampireTick(client)
{
	if (IsAliveHuman(client) && GetRealHumanClass(client) == view_as<int>(hcScavenger) && serverPrintHealth)
	{
		PrintHealth(client);
	}
}

void PrintHealth(client)
{
	new health = GetClientHealth(client);
	// Colors don't work with PrintCenterText. :/
	//new color = 3;
	//if (health < 75) color = 4;
	//if (health < 50) color = 5;
	//if (health < 25) color = 11;
	PrintCenterText(client, "%d HP", health);
}

/*
void MarksmanWallhackTick(client)
{
	// Disabled.
	if (IsAliveHuman(client) && GetRealHumanClass(client) == view_as<int>(hcMarksman))
	{
		int target = GetClientAimTarget(client, true);
		if (target > 0 && target <= GetMaxClients() && IsAliveBot(target))
		{
			switch (g_playerClass[target])
			{
				case bcHeavy:
				{
					PrintCenterText(client, "=[X]=");
				}
				default:
				{
					PrintCenterText(client, "(X)");
				}
			}
		}
		else
		{
			PrintCenterText(client, "");
		}
	}
}
*/

void FlashlightTick(client)
{
	// The shotgunner bots keep turning the flashlight off.
	// We force-turn it back on. All the time.
	if (IsAliveBot(client))
	{
		new weapon = GetPlayerWeaponSlot(client, 0);
		if (weapon != -1)
		{
			decl String:weaponName[32];
			GetEdictClassname(weapon, weaponName, sizeof(weaponName));
			if (StrEqual(weaponName, "weapon_m590_bot"))
			{
				if (GetEntProp(weapon, Prop_Send, "m_bFlashlightOn") == 0)
				{
					SetEntProp(weapon, Prop_Send, "m_bFlashlightOn", 1);
				}
			}
		}
	}
}

void ForceHealthAfterResupplyTick(client)
{
	if (IsAliveHuman(client))
	{
		new currHealth = GetClientHealth(client);
		if (g_lastHealth[client] > 0 && g_lastHealth[client] < 100 && currHealth == 100)
		{
			// You were alive and hurt, but your HP is now 100 of all sudden.
			// The only ways to heal are to complete an objective or to get melee kills as Scavenger.
			// Both cases already take this into account, forcing g_lastHealth to increase there.
			// In THIS case, however, it was not expected. It means you got the health from resupplying.
			//PrintToChatAll("[AoF-Debug] Player %d healed up from %d to 100 hp. NOT allowing it.", client, g_lastHealth[client]);
			SetEntityHealth(client, g_lastHealth[client]);
		}
		g_lastHealth[client] = GetClientHealth(client);
	}
}

void WeaponRemovalTick()
{
	new size = GetArraySize(g_removeWeapon);
	if (size > 0)
	{
		for (new i = 0; i < size; ++i)
		{
			new ent = GetArrayCell(g_removeWeapon, i);
			//PrintToChatAll("[AoF-Debug] Weapon %d should be removed.", ent);
			if (IsValidEntity(ent))
			{
				//PrintToChatAll("[AoF-Debug] Weapon %d is a valid entity - REMOVED.", ent);
				RemoveEdict(ent);
			}
		}
		ClearArray(g_removeWeapon);
	}
}

/*
public Action:PlayerResupply(client, args)
{
	//PrintToChatAll("[AoF-Debug] Player %d resupplied (current health: %d).", client, GetClientHealth(client));
	g_forceHealth[client] = GetClientHealth(client);
	return Plugin_Continue;
}
*/

public Action:CmdTest(client, args)
{
	//char argString[256];
	//GetCmdArgString(argString, sizeof(argString));	
	//PrintToChatAll("\x07%s[AoF] This is color 0x%s.", argString, argString);
	return Plugin_Continue;
}

void SetCustomBlockZoneActive(ent, bool:isActive)
{
	SetEntProp(ent, Prop_Send, "m_nSolidType", isActive ? SOLID_BBOX : SOLID_NONE);
}

// When a control point is captured.
public Action:Event_ControlPointCapturedPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	new cp = GetEventInt(event, "cp");
	if (cp < 0)
	{
		return Plugin_Continue;
	}
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Objective %c was captured.", GetGameTime(), 'A' + cp);
	}
	PrintToServer("[AoF] Objective %c has been captured.", 'A' + cp);
	// Setup the gameplay for the next zone.
	UpdateGameProgress(cp + 1);
	return Plugin_Continue;
}

// When a weapon cache is destroyed.
public Action:Event_ObjectDestroyedPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	new cp = GetEventInt(event, "cp");
	if (cp < 0)
	{
		// depot_coop has 'fake' weapon caches that fire this event with cp = -1 when they are blown up.
		return Plugin_Continue;
	}
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Objective %c was destroyed.", GetGameTime(), 'A' + cp);
	}
	PrintToServer("[AoF] Objective %c has been destroyed.", 'A' + cp);
	// Setup the gameplay for the next zone.
	UpdateGameProgress(cp + 1);
	return Plugin_Continue;
}

// Suppress annoying messages in chat (v1.3d).
public Action:Event_ServerCvar(Handle:event, const String:name[], bool:dontBroadcast)
{
	decl String:sConVarName[128];
	sConVarName[0] = '\0';    
	GetEventString(event, "cvarname", sConVarName, sizeof(sConVarName));    
	if (StrEqual(sConVarName, "mp_supply_token_bot_base",			false) ||
		StrEqual(sConVarName, "mp_supply_rate_losing_team_high",	false) ||
		StrEqual(sConVarName, "mp_supply_rate_losing_team_low",		false) ||
		StrEqual(sConVarName, "mp_supply_rate_winning_team_high",	false) ||
		StrEqual(sConVarName, "mp_supply_rate_winning_team_low",	false) ||
		StrEqual(sConVarName, "mp_cp_capture_time",					false) ||
		StrEqual(sConVarName, "mp_cp_deteriorate_time",				false) ||
		StrEqual(sConVarName, "mp_checkpoint_counterattack_disable",false) ||
		StrEqual(sConVarName, "mp_maxrounds",						false) )
	{
		return Plugin_Handled;
	}
	if (StrEqual(sConVarName, "ins_bot_difficulty", false))
	{
		CreateTimer(0.1, Timer_AnnounceDifficulty, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
} 

// Game control.
ResetGameProgress()
{
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Resetting game progress...", GetGameTime());
	}
	g_revealSpawnsNow = false;
	g_checkSightNow = false;
	g_curZone = -1;
	g_maxZone = 0;
	g_isFinale = false;
	for (new bg = 0; bg < view_as<int>(TOTAL_BOT_GROUPS); ++bg)
	{
		g_botsLeft[bg] = 0;
		g_botQueue[bg] = 0;
	}
	
	// Remove all dynamically-spawned entities.
	// Mostly, this is for custom blockzones. Props do remove themselves on round restart.
	new count = 0;
	new entityCount = GetEntityCount();
	for (new ent = entityCount - 1; ent >= 0; --ent)
	{
		if (!IsValidEntity(ent))
		{
			continue;
		}
		decl String:targetName[255];
		GetEntPropString(ent, Prop_Data, "m_iName", targetName, sizeof(targetName));
		if (StrEqual(targetName, AOF_ENTITY_TARGET_NAME))
		{
			decl Float:origin[3];
			decl String:className[100];
			GetEntityClassname(ent, className, sizeof(className));
			// Teleport the blockzone upwards so that the "player left blockzone" triggers are fired.
			GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
			origin[2] += 5000.0;
			TeleportEntity(ent, origin, NULL_VECTOR, NULL_VECTOR);
			CreateTimer(1.0, Timer_RemoveEntity, ent, TIMER_FLAG_NO_MAPCHANGE);	
			PrintToServer("[AoF-Cleanup] Cleaned up AoF entity \"%s\" (\"%s\")  from {%.0f %.0f %0.f}.",
							targetName, className, origin[0], origin[1], origin[2]);
			++count;
		}
	}
	if (count > 0)
	{
		PrintToServer("[AoF-Cleanup] Cleaned up %d entities dynamically spawned by Army of Five.", count);
	}
}

// The main gameplay-controlling function.
bool:UpdateGameProgress(newZone)
{
	// Some debug.
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		l_scavengerAnestheticDebug[client] = 0;
	}
	
	// Restore everyone's health.
	if (serverRestoreHealth)
	{
		RestoreHealthForAliveHumans();
	}
	
	// Reset forced cvars.
	ResetServerCVars();
	UnloadPlugins();
	
	// Disable all the subsystems.
	g_hideBodiesNow = true;
	g_revealSpawnsNow = false;
	g_checkSightNow = false;
	
	// Setup the next spawn zone.
	g_curZone = newZone;
	g_playerSpawnIndex = 0;
	
	// Deactivate the old custom block zones and activate the new ones.
	CreateTimer(0.2, Timer_DeactivateCustomBlockZones,	_, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.4, Timer_ActivateCustomBlockZones,	_, TIMER_FLAG_NO_MAPCHANGE);
	
	// Make sure that the bot spawn points array is not empty.
	if (GetArraySize(g_spawns[g_curZone]) == 0)
	{
		PrintToServer("[AoF-BotSpawns] ERROR: no bot spawn spots were found at objective '%c'!", 'A' + g_curZone);
		return false;
	}
	
	// Prepare for the finale, if needed.
	g_isFinale = (g_curZone == g_maxZone);
	SetConVarBool(FindConVar("mp_checkpoint_counterattack_disable"), true, false, false);
	
	if (g_isFinale)
	{
		if (!serverEnableFinale)
		{
			return true; // gg no re!
		}
		SetConVarBool(FindConVar("mp_checkpoint_counterattack_disable"), false, false, false);
		SetConVarInt(FindConVar("mp_maxrounds"), 1, false, false); // this round will be the last, regardless.
		new Float:prepareDelay = (GetConVarInt(FindConVar("mp_checkpoint_counterattack_delay_finale")) * 1.0) - 0.5;
		CreateTimer(prepareDelay, Timer_PrepareFinale, _, TIMER_FLAG_NO_MAPCHANGE);
		PrintToChatAll("\x07%s[AoF] %t", COLOR_AOF_FINALE_MESSAGE, "finale_message");
	}	
	
	// Ok, we can now recalculate how many and which bots we need to spawn, which ones to kill of immediately etc.
	// We have to let the game spawn them normally first, so here's a brief delay.
	new Float:delay = 0.2;
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] UpdateGameProgress called. Default delay: %.1f.", GetGameTime(), delay);
	}
	if (g_curZone == 0)
	{
		// Here's a lengthy explanation. The bots spawn initially when the round starts (when everyone
		// are still frozen). 15 seconds later everyone gets unfrozen. At that point of time the bot count
		// gets re-evaluated again (most likely to account players that have joined during that time).
		// So we also must do our processing after the actual game starts, not when the round starts.
		// Thing is, the event "round_begin" never fires! I still have no idea why.
		// So instead we just wait for 15.1 seconds instead of 0.1 seconds if it is the first round.
		// Hardcoding 15 seconds sucks but I am unable to find the cvar that changes it.
		// mp_match_restart_delay, mp_freezetime, and mp_lobbytime don't affect it at all.
		// mp_timer_preround_first does but only for the first round (who the hell wants that? you already had extra time)
		// EDIT: seems like 15 is not enough, let's have a bit more instead. Ugh. This isn't reliable at all.
		delay += 15.3;
		if (serverDebugBotSpawns2)
		{
			PrintToServer("[AoF-Debug2] [%08.3f] This is the start of the round, so the delay is increased to %.1f.", GetGameTime(), delay);
		}
	}
	else if (g_isFinale)
	{
		delay += GetConVarInt(FindConVar("mp_checkpoint_counterattack_delay_finale")) + 0.3;
		if (serverDebugBotSpawns2)
		{
			PrintToServer("[AoF-Debug2] [%08.3f] This is the finale so the delay is increased to %.1f.", GetGameTime(), delay);
		}
	}
	CreateTimer(delay,			Timer_InitBotQueues,	_, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(delay + 0.3,	Timer_DisableBotHiding,	_, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(delay + 1.0,	Timer_UpdateBotCount,	_, TIMER_FLAG_NO_MAPCHANGE);
	
	// Re-enable the spawn spot revealing system again.
	// Is the timer change ok? Before it was: (g_isFinale ? 0.1 : 5.0) - which is wrong but somehow seemed to work I think.
	new Float:spawnRevealDelay = delay + (g_isFinale ? 0.1 : 5.0);
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] spawnRevealDelay = %.1f.", GetGameTime(), spawnRevealDelay);
	}
	CreateTimer(spawnRevealDelay, Timer_EnableSpawnReveal, _, TIMER_FLAG_NO_MAPCHANGE);
	return true;
}

public Action:Timer_InitBotQueues(Handle timer)
{
	//PrintToServer("[AoF] Timer_InitBotQueues start");
	g_isInGame = true;
	
	// Let's calculate the player count first.
	if (g_curZone == -1)
	{
		return Plugin_Handled;
	}
	
	new playerCount = 0;
	if (serverForcePlayerCount > 0)
	{
		playerCount = serverForcePlayerCount;
	}
	else
	{
		// For a number of reasons I don't trust built-in functions for this..
		for (new human = 1; human <= GetMaxClients(); ++human)
		{
			//if (IsAliveHuman(human))
			//if (IsClientConnected(human) && IsClientInGame(human) && !IsFakeClient(human))
			if (IsHuman(human))
			{
				// Dead humans should count as well because when someone dies right before an objective
				// is completed they won't respawn immediately, but rather after a brief delay.
				// EDIT: this apparently starts to count spectators as well.
				// And I'm unable to find a proper IsSpectator() kind of check.
				// So I'm bringing the health check back.
				if (IsPlayerAlive(human))
				{
					++playerCount;
				}
			}
		}
	}
	playerCount = Max(1, playerCount);
	
	// Now let's recalculate the bot queues.
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Current difficulty: %d (%s), player count: %d.", GetGameTime(), serverDifficulty, l_difficultyName[serverDifficulty], playerCount);
	}
	new count = 0;
	for (new bg = 0; bg < view_as<int>(TOTAL_BOT_GROUPS); ++bg)
	{
		new wave = RoundToFloor(l_botCountOnePlayer[g_isFinale ? 1 : 0][serverDifficulty][bg] + (l_botFracPerPlayer[g_isFinale ? 1 : 0][serverDifficulty][bg] * (playerCount - 1)));
		if (serverDebugFinaleOnly && !g_isFinale)
		{
			wave = 0;
		}
		count += wave;
		g_botQueue[bg] = g_botsLeft[bg] + wave;
		if (serverDebugBotSpawns2)
		{
			PrintToServer("[AoF-Debug2] [%08.3f] Bot group %d |%7s|. g_botsLeft[%d] = %2d, wave added = %2d, new g_botQueue[%d] = %d.",
							GetGameTime(), bg, l_botGroupName[bg], bg, g_botsLeft[bg], wave, bg, g_botQueue[bg]);
			PrintToServer("[AoF-Debug2] [%08.3f]                     RoundToFloor(%.2f + %.2f * %d) = %2d.",
							GetGameTime(), l_botCountOnePlayer[g_isFinale ? 1 : 0][serverDifficulty][bg], l_botFracPerPlayer[g_isFinale ? 1 : 0][serverDifficulty][bg], playerCount - 1, wave);
		}
		g_botsLeft[bg] = g_botQueue[bg];
	}
	decl String:difName[100];
	Format(difName, sizeof(difName), "%T", l_difficultyName[serverDifficulty], LANG_SERVER);
	PrintToServer("[AoF-Debug] There are %d players and the difficulty is %s%s, so we spawn %d new bots.",
					playerCount, difName, (g_isFinale ? " (FINALE)" : ""), count);
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Total new bots added: %d.", GetGameTime(), count);
	}
	
	// Then, we iterate through all the bots.
	new Float:curTime = GetGameTime();
	for (new bot = 1; bot <= GetMaxClients(); ++bot)
	{
		if (IsAliveBot(bot))
		{
			new botGroup = l_botClassToBotGroup[g_playerClass[bot]];
			if (curTime - g_botLastSeen[bot] < BOT_LAST_SEEN_TIME)
			{
				// This bot is alive and has recently been seen by a player.
				// Nothing will happen to him at all, though he counts as one of the bots defending the next objective.
				g_botQueue[botGroup] = Max(0, g_botQueue[botGroup] - 1);
				if (serverDebugBotSpawns2)
				{
					decl String:playerName[255];
					GetClientName(bot, playerName, sizeof(playerName));
					PrintToServer("[AoF-Debug2] [%08.3f] Iterating: %2d |%14s| (%7s) is alive, seen recently.", GetGameTime(), bot, playerName, l_botGroupName[botGroup]);
				}
				continue;
			}
			// This bot was either naturally respawned by the game or he ran away
			// from the previous objective and has not been seen by any players recently.
			if (g_botQueue[botGroup] > 0)
			{
				// This bot is allowed to live. Since he's already spawned, he no longer takes the slot in the queue.
				--g_botQueue[botGroup];
				// We reset his health and position. Since it's the start of the wave, valid spawn spots should always exist.
				SetEntityHealth(bot, 100);
				new Float:spawnPos[3];
				GetArrayArray(g_spawns[g_curZone], GetRandomInt(0, GetArraySize(g_spawns[g_curZone]) - 1), spawnPos);
				TeleportEntity(bot, spawnPos, NULL_VECTOR, NULL_VECTOR);
				g_botLastSeen[bot] = curTime;
				if (serverDebugBotSpawns2)
				{
					decl String:playerName[255];
					GetClientName(bot, playerName, sizeof(playerName));
					PrintToServer("[AoF-Debug2] [%08.3f] Iterating: %2d |%14s| (%7s) is alive, not seen recently, kept alive.", GetGameTime(), bot, playerName, l_botGroupName[botGroup]);
				}
				continue;
			}
			// There is no room for this bot anymore, so we kill him off and remove his corpse and dropped weapons.
			// Temporary hack: move him away to prevent players from hearing their death screams. Comment out this line to remove the hack.
			//new Float:curPos[3]; GetEntPropVector(bot, Prop_Send, "m_vecOrigin", curPos); curPos[2] += 5000.0; TeleportEntity(bot, curPos, NULL_VECTOR, NULL_VECTOR);
			// EDIT: it worked like ass for several reasons. Let's try the dummy spot approach instead.
			TeleportEntity(bot, g_dummySpot, NULL_VECTOR, NULL_VECTOR);		
			// EDIT: it appears that ForcePlayerSuicide sometimes just does not work now! See internal log 21-07-2016-063946.
			// One of the alternatives is using FakeClientCommand(client, "kill"); but they say it's a hack.
			// EDIT 2: replaced this with custom ForcePlayerSuicide2 function.
			ForcePlayerSuicide2(bot);
			if (serverDebugBotSpawns2)
			{
				decl String:playerName[255];
				GetClientName(bot, playerName, sizeof(playerName));
				PrintToServer("[AoF-Debug2] [%08.3f] Iterating: %2d |%14s| (%7s) is alive, not seen recently, killed.", GetGameTime(), bot, playerName, l_botGroupName[botGroup]);
			}
		}
		else if (serverDebugBotSpawns2 && IsBot(bot))
		{
			new botGroup = l_botClassToBotGroup[g_playerClass[bot]];
			decl String:playerName[255];
			GetClientName(bot, playerName, sizeof(playerName));
			PrintToServer("[AoF-Debug2] [%08.3f] Iterating: %2d |%14s| (%7s) is dead.", GetGameTime(), bot, playerName, l_botGroupName[botGroup]);
		}
	}
	return Plugin_Continue;
}

public Action:Timer_DeactivateCustomBlockZones(Handle timer)
{
	// Deactivate old custom block zones.
	new g_prevZone = g_curZone - 1;
	if (g_prevZone >= 0 && g_prevZone <= g_maxZone)
	{
		for (new i = 0; i < GetArraySize(g_deactivateBlockZones[g_prevZone]); ++i)
		{
			SetCustomBlockZoneActive(GetArrayCell(g_deactivateBlockZones[g_prevZone], i), false);
		}
	}
}

public Action:Timer_ActivateCustomBlockZones(Handle timer)
{
	// Activate new custom block zones.
	if (g_curZone >= 0 && g_curZone <= g_maxZone)
	{
		for (new i = 0; i < GetArraySize(g_activateBlockZones[g_curZone]); ++i)
		{
			SetCustomBlockZoneActive(GetArrayCell(g_activateBlockZones[g_curZone], i), true);
		}
	}
}

public Action:Timer_PrepareFinale(Handle timer)
{
	// Remove all capture triggers so that the bots cannot capture the final point.
	// Before we remove it though, we move it way up in the sky so that the "player left spawn point" events are fired.
	new ent = -1;
	for (;;)
	{
		ent = FindEntityByClassname(ent, "trigger_capture_zone");
		if (ent == -1)
		{
			break;
		}
		decl Float:origin[3];
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
		origin[2] += 5000.0;
		TeleportEntity(ent, origin, NULL_VECTOR, NULL_VECTOR);
		CreateTimer(1.0, Timer_RemoveEntity, ent, TIMER_FLAG_NO_MAPCHANGE);	
	}
	ent = -1;
	for (;;)
	{
		ent = FindEntityByClassname(ent, "point_controlpoint");
		if (ent == -1)
		{
			break;
		}
		//CreateTimer(1.0, Timer_RemoveEntity, ent, TIMER_FLAG_NO_MAPCHANGE); // causes segmentation fault!
	}
	new clientIndex = 0;
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		if (IsAliveHuman(client))
		{
			CreateDelayedFade(client, 0.0, 0.3, 0.5,	(FFADE_PURGE|FFADE_MODULATE|FFADE_OUT),	0, 0, 0, 255);
			CreateDelayedFade(client, 0.3, 0.3, 0.3,	(FFADE_PURGE|FFADE_MODULATE|FFADE_IN),	0, 0, 0, 255);
			DataPack pack;
			CreateDataTimer(0.3, Timer_TeleportPlayerFinale, pack);
			pack.WriteCell(client);
			pack.WriteCell(clientIndex);
			++clientIndex;
		}
		if (IsBot(client))
		{
			// This most likely won't even work, you need to make sure that the correct 
			// boolean vars are disabled as well or he'll get "seen" immediately again anyway..
			// EDIT: I don't know, all the bots do get teleported away when the finale starts
			// (even if they were in your plain sight before) so maybe I shouldn't touch this.
			g_botLastSeen[client] = 0.0;
		}
	}
}

public Action:Timer_TeleportPlayerFinale(Handle timer, DataPack pack)
{
	ResetPack(pack);
	new client = pack.ReadCell();
	//new clientId = pack.ReadCell(); // unused now
	//TeleportEntity(client, g_finalePlayerSpawn[clientId], NULL_VECTOR, NULL_VECTOR);
	if (g_curZone != g_maxZone)
	{
		PrintToServer("[AoF] ERROR: Timer_TeleportPlayerFinale called during objective '%c' (expected '%c').", 'A' + g_curZone, 'A' + g_maxZone);
	}
	new Float:spawnPos[3];
	GetArrayArray(g_playerSpawns[g_maxZone], g_playerSpawnIndex, spawnPos);
	g_playerSpawnIndex = (g_playerSpawnIndex + 1) % GetArraySize(g_playerSpawns[g_maxZone]);
	TeleportEntity(client, spawnPos, NULL_VECTOR, NULL_VECTOR);
}

public Action:Timer_DisableBotHiding(Handle timer)
{
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Timer_DisableBotHiding executed.", GetGameTime());
	}
	g_hideBodiesNow = false;
	g_checkSightNow = true;
	return Plugin_Continue;
}

void RespawnAndTeleportBot(bot)
{
	if (serverDebugBotSpawns2)
	{
		decl String:playerName[255];
		GetClientName(bot, playerName, sizeof(playerName));
		PrintToServer("[AoF-Debug2] [%08.3f] Respawning bot %2d |%14s|.", GetGameTime(), bot, playerName);
	}
	if (!IsPlayerAlive(bot))
	{
		SDKCall(g_hPlayerRespawn, bot);
	}
	new spawnPointCount = GetArraySize(g_spawns[g_curZone]);
	new Float:spawnPos[3];
	GetArrayArray(g_spawns[g_curZone], GetRandomInt(0, spawnPointCount - 1), spawnPos);
	TeleportEntity(bot, spawnPos, NULL_VECTOR, NULL_VECTOR);
}

public Action:Timer_HandleBotDeath(Handle timer, DataPack pack)
{
	ResetPack(pack);
	new client = pack.ReadCell();
	new attacker = pack.ReadCell();
	new bool:isSuicide = (client == attacker);
	new botGroup = l_botClassToBotGroup[g_playerClass[client]];
	if (g_curZone == -1)
	{
		if (serverDebugBotSpawns2)
		{
			decl String:playerName[255];
			GetClientName(client, playerName, sizeof(playerName));
			PrintToServer("[AoF-Debug2] [%08.3f] Handling the death of bot %2d |%14s| (%7s). g_curZone is -1: exiting.",
							GetGameTime(), client, playerName, l_botGroupName[botGroup]);
		}
		return Plugin_Continue;
	}
	new spawnPointCount = GetArraySize(g_spawns[g_curZone]);
	new bool:canRespawn = (spawnPointCount > 0);
	new bool:wantsRespawn = (g_botQueue[botGroup] > 0);
	if (serverDebugBotSpawns2)
	{
		decl String:playerName[255];
		GetClientName(client, playerName, sizeof(playerName));
		PrintToServer("[AoF-Debug2] [%08.3f] Handling the death of bot %2d |%14s| (%7s). Is suicide: %5s, wants to respawn: %5s, can respawn: %5s.",
						GetGameTime(), client, playerName, l_botGroupName[botGroup], (isSuicide ? "true" : "false"), (wantsRespawn ? "true" : "false"), (canRespawn ? "true" : "false"));
	}
	if (!canRespawn)
	{
		// Regardless of how this bot died and whether he wants to respawn or not,
		// we check whether he (or any other bot for that matter) *can* respawn or not.
		for (new i = 0; i < view_as<int>(TOTAL_BOT_GROUPS); ++i)
		{
			g_botQueue[i] = 0;
		}
		if (serverDebugBotSpawns2)
		{
			PrintToServer("[AoF-Debug2] [%08.3f] This bot can't respawn. Setting all bot queues to 0.", GetGameTime());
		}
		CreateTimer(0.1, Timer_UpdateBotCount, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	if (isSuicide && canRespawn)
	{
		// The bot suicided somehow (fall damage, force-killed by the game etc).
		// There's still room to respawn him. So we do that silently and exit.
		RespawnAndTeleportBot(client);
		return Plugin_Continue;
	}
	if (wantsRespawn && canRespawn)
	{
		RespawnAndTeleportBot(client);
	}
	if (!isSuicide)
	{
		g_botsLeft[botGroup] = Max(0, g_botsLeft[botGroup] - 1);
		g_botQueue[botGroup] = Max(0, g_botQueue[botGroup] - 1);
	}
	//PrintToServer("[AoF-Debug] Bot %d died, g_botsLeft: %d, g_botQueue: %d.", client, g_botsLeft[botGroup], g_botQueue[botGroup]);
	return Plugin_Continue;
}

public Action:Timer_EnableSpawnReveal(Handle timer)
{
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Timer_EnableSpawnReveal executed.", GetGameTime());
	}
	g_revealSpawnsNow = true;
	return Plugin_Continue;
}

public Action:Timer_UpdateBotCount(Handle timer)
{
	if (!serverPrintBotCount || g_hideBodiesNow)
	{
		return Plugin_Continue;
	}
	new count = Team_CountAlivePlayers(view_as<int>(TEAM_INSURGENTS));
	decl String:message[255] = "";
	Format(message, sizeof(message), "Alive: %2d", count);
	for (new bg = 0; bg < view_as<int>(TOTAL_BOT_GROUPS); ++bg)
	{
		count += g_botQueue[bg];
		Format(message, sizeof(message), "%s, %s: %2d", message, l_botGroupName[bg], g_botQueue[bg]);
	}
	if (serverDebugBotSpawns2)
	{
		PrintToServer("[AoF-Debug2] [%08.3f] Printing bot count: %d. %s.", GetGameTime(), count, message);
	}
	// We cannot use the following commented out approach for two reasons:
	// 1) g_botsLeft gets updated later (depends on the Timer_HandleBotDeath call timer);
	// 2) If all spawn spots are revealed then the queues will be empty but they'll still get accounted for.
	//new count2 = 0;
	//for (new bg = 0; bg < view_as<int>(TOTAL_BOT_GROUPS); ++bg)
	//{
	//	count2 += g_botsLeft[bg];
	//}
	PrintHintTextToAll("%t", "bot_count", count);
	return Plugin_Continue;
}

public bool:FilterNotSelf(entity, contentsMask, any:client)
{
	return (entity != client);
}

public bool:FilterIgnoreClients(entity, contentsMask)
{
	return (entity < 1 || entity > GetMaxClients());
}

public Action:Timer_RevealSpawns(Handle timer)
{
	// Technically, this function is being executed the entire time, non-stop, while the map is played.
	if (!g_revealSpawnsNow || g_curZone == -1)
	{
		return Plugin_Continue;
	}
	// So, we perform a sight check from every human to every "active" bot spawn points in the current area.
	// When any human has a clear line of sight with a certain spawn point, that certain spawn point gets
	// considered "inactive" (i.e. it is removed from the array of currently available spawn points).
	// By doing this we make sure that the bots will never respawn in places that players have already cleared.
	// Note that the humans' angles are not taken into account; simply running past a small room without actually
	// looking inside is sufficient to prevent the bots from respawning there (unless you manage to slide past it so
	// fast that the sight check doesn't register but that's nearly impossible since it runs several times a second).
	// But isn't that a lot of sight checks, you might ask? Wouldn't that slow the server down real bad?
	// That's what I initially thought as I was coding this. However, it seems the sight checks are super optimized.
	// I tried running many thousand checks a second and there was hardly any more CPU usage on the server.
	// Since the player limit is 5, and I never put more than 100 spawn spots per objective, it's max 500 checks at a time.
	for (new human = 1; human <= GetMaxClients(); ++human)
	{
		if (!IsAliveHuman(human))
		{
			continue;
		}
		new Float:humanPos[3];
		GetClientEyePosition(human, humanPos);
		// KEEP GetArraySize IN the loop! Do NOT just "optimize" it out of the loop since the size might change!
		for (new sp = GetArraySize(g_spawns[g_curZone]) - 1; sp >= 0; --sp)
		{
			new Float:spawnPos[3];
			GetArrayArray(g_spawns[g_curZone], sp, spawnPos);
			spawnPos[2] += BOT_HEIGHT;
			// Note: this trace type doesn't go through undamaged glass. I don't see a way to fix it but it's not a big deal.
			// EDIT: I suppose it makes more sense to trace from each spawn spot to each human's position rather than the other
			// way around. Since a lot of spots are hidden behind corners and the such, it should hit an obstacle faster and thus
			// perform fewer collision checks with the world. Or at least that's how I assume this works on the engine level.
			new Handle:hTrace = TR_TraceRayFilterEx(spawnPos, humanPos, MASK_SHOT_HULL, RayType_EndPoint, FilterIgnoreClients);
			new bool:isClearSight = !TR_DidHit(hTrace);
			CloseHandle(hTrace);
			if (isClearSight)
			{
				RemoveFromArray(g_spawns[g_curZone], sp);
				if (serverDebugBotSpawns)
				{
					decl String:playerName[255];
					GetClientName(human, playerName, sizeof(playerName));
					PrintToChatAll("\x07%s[AoF-Debug] %s revealed a spawn point (%d remain).", COLOR_AOF_DEBUG, playerName, GetArraySize(g_spawns[g_curZone]));
				}
			}
		}
	}
	return Plugin_Continue;	
}

public Action:Timer_CheckSight(Handle timer)
{
	if (!g_checkSightNow)
	{
		return Plugin_Continue;
	}
	// This is very similar to the code above. It runs sight checks from each player to each bot.
	// This allows me to figure out how long ago a given bot was seen by players.
	// Whenever an objective completed, all the bots that have not been seen by any players
	// for some time will get teleported up front to the next objective. This prevents
	// the bots who "got lost" from wandering around the map for too long.
	new Float:curTime = GetGameTime();
	for (new bot = 1; bot <= GetMaxClients(); ++bot)
	{
		if (!IsAliveBot(bot))
		{
			// Anything that is not an alive bot is considered to be never seen.
			g_botLastSeen[bot] = 0.0;
			continue;
		}
		new bool:isSeen = false;
		for (new human = 1; human <= GetMaxClients() && !isSeen; ++human)
		{
			if (!IsAliveHuman(human))
			{
				continue;
			}
			new Float:humanEyePos[3], Float:botEyePos[3], Float:bosFeetPos[3];
			GetClientEyePosition(human, humanEyePos);
			GetClientEyePosition(bot, botEyePos);
			GetClientAbsOrigin(bot, bosFeetPos);
			new Handle:hTrace1 = TR_TraceRayFilterEx(humanEyePos, botEyePos, MASK_SHOT_HULL, RayType_EndPoint, FilterIgnoreClients);
			new Handle:hTrace2 = TR_TraceRayFilterEx(humanEyePos, bosFeetPos, MASK_SHOT_HULL, RayType_EndPoint, FilterIgnoreClients);
			new bool:isClearSight = !TR_DidHit(hTrace1) || !TR_DidHit(hTrace2);
			CloseHandle(hTrace1);
			CloseHandle(hTrace2);
			if (isClearSight)
			{
				// This bot is marked as just seen. Otherwise the time stamp will not be updated.
				g_botLastSeen[bot] = curTime;
				isSeen = true;
			}
		}
		// NOTE: the following section of the code is buggy AND gameplay-inefficient. It's better to keep it disabled for now.
		/*
		if (!isSeen && serverEnableBotTeleport) // disabled
		{
			// This bot cannot be seen by anyone. How long ago WAS he seen, then?
			if ((curTime - g_botLastSeen[bot] > BOT_LAST_SEEN_TIME2) && (g_curZone != -1))
			{
				// Apparently it's been quite a while.
				new spawnPointCount = GetArraySize(g_spawns[g_curZone]);
				if (spawnPointCount > 0)
				{
					new Float:spawnPos[3];
					GetArrayArray(g_spawns[g_curZone], GetRandomInt(0, spawnPointCount - 1), spawnPos);
					TeleportEntity(bot, spawnPos, NULL_VECTOR, NULL_VECTOR);
					g_botLastSeen[bot] = curTime;
				}
			}
		}
		*/
	}
	return Plugin_Continue;
}

public Action:Timer_InitiateLastSeenTime(Handle timer)
{
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		// Everyone are considered to be never seen before.
		g_botLastSeen[client] = 0.0;
	}
	g_checkSightNow = true;
}

bool:LoadBse()
{
	// So, if you're actually reading this you might be wondering: what the hell are these "*.bse" files?
	// These files are located in insurgency/addons/sourcemod/configs/aof/bse_data directory of your server.
	// There's one .bse file for each map supported by Army of Five.
	// "BSE" originally stands for "Bot Spawn Editor", which is the name of a special plugin
	// that I've created. It is not included in the Army of Five server installation package and 
	// in fact it has never been (and almost certainly will not be) uploaded publicly on the web.
	// It is a private, internal, and fairly buggy tool that I use to edit those .bse files.
	// It allows me to run around the maps and add, remove, edit the bot spawn points for every objective.
	// I believe the standard .nav mesh editing (provided by the engine) is kind of similar to this process.
	// Unlike the normal (vanilla) spawn points, which are actual entities on the map, my custom spawn points
	// are just data. Simple floating points that are parsed from a file and loaded into an array.
	// The bots don't *actually* (re)spawn in the specified points; they spawn normally in the locations
	// provided by the vanilla system and then they're almost immediately teleported into a randomly selected custom one.
	// Daimyo has also implemented a bot-respawning system for Sernix coop, but his approach is completely different:
	// he reads the map's .nav data and extracts certain locations from it (like the so-called "hiding spots", I think).
	// Then, whenever a bot is respawned, he gets teleported to one of such locations somewhere not too close and
	// not too far from the players (it's more complex than that I believe but I haven't read too deeply into the code).
	// The advantage of his approach is that it reliably works on pretty much any given map, custom or stock one.
	// The disadvantage is that the bots may sometimes spawn in inaccessible areas, behind fences, behind players etc.
	// The advantage of my approach is that since I place every single spawn point by hand, the bots won't ever
	// spawn behind you (or on rooftops - awful for Scavenger etc), and you'll be able to fully clear each objective.
	// The disadvantage is that, of course, it took a LOT of time, and you cannot play any "unsupported" map in AoF.
	// That is, you cannot simply play any map with Army of Five mod; there has to be a .bse file created by me for it.
	// However, this is acceptable because a lot of maps simply do not fit AoF gameplay at all anyway.
	// UPD: after a year of using and extending the BSE functionality, I can now also:
	// - move entities around (including blockzones, capture triggers etc);
	// - remove specific entities;
	// - spawn entities in given coordinates with a given model;
	// - create custom blockzones;
	// - customize player spawn poins;
	// ...etc, all without modifying the actual .BSP map data.
	KeyValues kv = new KeyValues("bse");
	new bool:isOk = DoLoadBse(kv);
	CloseHandle(kv);
	return isOk;
}

bool:DoLoadBse(KeyValues kv)
{
	g_maxZone = -1;
	kv.SetEscapeSequences(true); 
	if (!kv.ImportFromFile(l_bseFileName))
	{
		PrintToServer("[BSE-Error] Failed to open %s.", l_bseFileName);
		return false;
	}
	
	// Find the dummy spot origin.
	if (!kv.JumpToKey("dummyspot"))
	{
		PrintToServer("[BSE-Error] Failed to find key \"dummyspot\".");
		return false;
	}
	kv.GetVector("origin", g_dummySpot);
	kv.Rewind();
	
	// Read spawnpoints.
	if (!kv.JumpToKey("spawnpoints"))
	{
		PrintToServer("[BSE-Error] Failed to find key \"spawnpoints\".");
		return false;
	}
	kv.GotoFirstSubKey(); // in "A", "B" etc
	new String:objName[2];
	do
	{
		kv.GetSectionName(objName, sizeof(objName));
		new zoneId = objName[0] - 'A';
		if (g_maxZone < zoneId)
		{
			g_maxZone = zoneId;
		}
		kv.GotoFirstSubKey(); // in "0", "1" etc
		do
		{
			decl Float:pos[3];
			kv.GetVector("origin", pos);
			new bool:isActive = (kv.GetNum("active") ? true : false);
			if (isActive)
			{
				PushArrayArray(g_spawns[zoneId], pos);
			}
		} while (kv.GotoNextKey());
		kv.GoBack();
	} while (kv.GotoNextKey());
	for (new zoneId = 0; zoneId <= g_maxZone; ++zoneId)
	{
		new count = GetArraySize(g_spawns[zoneId]);
		PrintToServer("[BSE] Spawn zone '%c' contains %d active spawn points.", (zoneId == g_maxZone ? '*' : 'A' + zoneId), count);
	}
	kv.Rewind();
	
	// Load the player spawnpoints.
	if (!kv.JumpToKey("player_spawnpoints"))
	{
		PrintToServer("[BSE-Error] Failed to find key \"player_spawnpoints\".");
		return false;
	}
	kv.GotoFirstSubKey(); // in "A", "B" etc
	//new String:objName[2];
	do
	{
		kv.GetSectionName(objName, sizeof(objName));
		new zoneId = objName[0] - 'A';
		if (g_maxZone < zoneId)
		{
			g_maxZone = zoneId;
		}
		kv.GotoFirstSubKey(); // in "0", "1" etc
		do
		{
			decl Float:pos[3];
			kv.GetVector("origin", pos);
			new bool:isActive = (kv.GetNum("active") ? true : false);
			if (isActive)
			{
				PushArrayArray(g_playerSpawns[zoneId], pos);
			}
		} while (kv.GotoNextKey());
		kv.GoBack();
	} while (kv.GotoNextKey());
	for (new zoneId = 0; zoneId <= g_maxZone; ++zoneId)
	{
		new count = GetArraySize(g_playerSpawns[zoneId]);
		if (count > 0)
		{
			PrintToServer("[BSE] Found %d active player spawns for zone '%c'.", count, (zoneId == g_maxZone ? '*' : 'A' + zoneId));
		}
	}
	if (GetArraySize(g_playerSpawns[g_maxZone]) == 0)
	{
		PrintToServer("[BSE-Error] Found no player spawn points for the finale.");
		return false;
	}
	kv.Rewind();
	
	// Read "move_entities" if it exists.
	if (kv.JumpToKey("move_entities"))
	{
		kv.GotoFirstSubKey(); // in "0", "1" etc
		do
		{
			decl String:className[100], String:targetName[100], Float:newPos[3];
			decl String:curTargetName[100], Float:oldPos[3], Float:curPos[3];
			kv.GetString("classname", className, sizeof(className), "?");
			kv.GetString("targetname", targetName, sizeof(targetName), "?");
			kv.GetVector("origin", oldPos);
			kv.GetVector("new_origin", newPos);
			new ent = -1, bool:isFound = false;
			while ((ent = FindEntityByClassname(ent, className)) != -1)
			{
				if (IsValidEntity(ent))
				{
					GetEntPropVector(ent, Prop_Send, "m_vecOrigin", curPos);
					GetEntPropString(ent, Prop_Data, "m_iName", curTargetName, sizeof(curTargetName));
					new bool:isClose = (GetVectorDistance(oldPos, curPos, true) < 3.0);
					new bool:isNameMatch = (StrEqual(curTargetName, targetName, false)) || (strlen(targetName) == 0);
					if (isClose && isNameMatch)
					{
						isFound = true;
						TeleportEntity(ent, newPos, NULL_VECTOR, NULL_VECTOR);
						PrintToServer("[BSE-Move] Moved entity \"%s\" (\"%s\") from {%.0f %.0f %.0f} to {%.0f %.0f %.0f}.",
										curTargetName, className, curPos[0], curPos[1], curPos[2], newPos[0], newPos[1], newPos[2]);
					}
				}
			}
			if (!isFound)
			{
				PrintToServer("[BSE-Move] Couldn't find entity \"%s\" (\"%s\").", targetName, className);
			}
		} while (kv.GotoNextKey());
		kv.Rewind();
	}
	
	// Read "remove_entities" if it exists.
	if (kv.JumpToKey("remove_entities"))
	{
		kv.GotoFirstSubKey(); // in "0", "1" etc
		do
		{
			decl String:className[100], String:targetName[100], Float:pos[3];
			new String:curTargetName[100]; // NOT DECL
			decl Float:curPos[3];
			kv.GetString("classname", className, sizeof(className), "");
			kv.GetString("targetname", targetName, sizeof(targetName), "");
			kv.GetVector("origin", pos);			
			new ent = -1, bool:isFound = false;
			while ((ent = FindEntityByClassname(ent, className)) != -1)
			{
				if (IsValidEntity(ent))
				{
					GetEntPropVector(ent, Prop_Send, "m_vecOrigin", curPos);
					new bool:isClose = (GetVectorDistance(pos, curPos, true) < 1.0);
					if (isClose)
					{
						new bool:isNameMatch = true;
						if (strlen(targetName) > 0)
						{
							GetEntPropString(ent, Prop_Data, "m_iName", curTargetName, sizeof(curTargetName));
							isNameMatch = StrEqual(curTargetName, targetName, false);
						}
						if (isNameMatch)
						{
							isFound = true;
							RemoveEdict(ent);
							ent = -1;
							PrintToServer("[BSE-Remove] Removed entity \"%s\" (\"%s\") from {%.0f %.0f %0.f}.",
											curTargetName, className, curPos[0], curPos[1], curPos[2]);
						}
						else
						{
							PrintToServer("[BSE-Remove] Found entity \"%s\" (\"%s\") at {%.0f %.0f %0.f} - doesn't match target name \"%s\".",
											curTargetName, className, curPos[0], curPos[1], curPos[2], targetName);
						}
					}
				}
			}
			if (!isFound)
			{
				PrintToServer("[BSE-Remove] Couldn't find entity \"%s\" (\"%s\").", targetName, className);
			}
		} while (kv.GotoNextKey());
		kv.Rewind();
	}
	
	//// This is horribly inefficient but also reliable.
	//new bool:hasFoundMore = true;
	//new count = 0;
	//while (hasFoundMore)
	//{
	//	hasFoundMore = false;
	//	new entityCount = GetEntityCount();
	//	for (new i = 0; i < entityCount && !hasFoundMore; ++i)
	//	{
	//		if (!IsValidEntity(i))
	//		{
	//			continue;
	//		}
	//		decl String:targetName[255];
	//		GetEntPropString(i, Prop_Data, "m_iName", targetName, sizeof(targetName));
	//		if (StrEqual(targetName, AOF_ENTITY_TARGET_NAME))
	//		{
	//			RemoveEdict(i);
	//			hasFoundMore = true;
	//			++count;
	//		}
	//	}		
	//}
	//PrintToServer("[BSE-Spawn] Removed %d entities dynamically spawned by Army of Five.", count);
	
	// Read "spawn_entities" if it exists.
	if (kv.JumpToKey("spawn_entities"))
	{
		kv.GotoFirstSubKey(); // in "0", "1" etc
		do
		{
			decl String:className[100];
			kv.GetString("classname", className, sizeof(className), "");
			new ent = CreateEntityByName(className);
			if (ent == -1)
			{
				PrintToServer("[BSE-Spawn] Failed to spawn entity \"%s\".", className);
				continue;
			}
			SetEntPropString(ent, Prop_Data, "m_iName", AOF_ENTITY_TARGET_NAME);
			if (StrContains(className, "prop") != -1)
			{
				decl String:modelName[100], Float:origin[3], Float:angles[3];
				kv.GetString("modelname", modelName, sizeof(modelName), "");
				kv.GetVector("origin", origin);
				kv.GetVector("angles", angles);
				PrecacheModel(modelName, true);
				DispatchKeyValue(ent, "physdamagescale", "0.0");
				SetEntityModel(ent, modelName);
				SetEntProp(ent, Prop_Send, "m_CollisionGroup", 0);
				DispatchKeyValue(ent, "Solid", "6"); 
				DispatchSpawn(ent);
				TeleportEntity(ent, origin, angles, NULL_VECTOR);
				PrintToServer("[BSE-Spawn] Spawned a prop with model \"%s\" (\"%s\") at %.2f %.2f %.2f; entity index is %d.",
								modelName, className, origin[0], origin[1], origin[2], ent);
			}
			else if (StrEqual(className, "ins_blockzone"))
			{
				decl Float:origin[3], Float:size[3];
				decl String:objSpawnName[2], String:objRemoveName[2], String:lastObjName[2] = "A";
				lastObjName[0] += g_maxZone;
				kv.GetVector("origin", origin);
				kv.GetVector("size", size);
				kv.GetString("obj_spawn",  objSpawnName,  sizeof(objSpawnName),  "A");
				kv.GetString("obj_remove", objRemoveName, sizeof(objRemoveName), lastObjName);
				new objSpawn  = objSpawnName[0]  - 'A';
				new objRemove = objRemoveName[0] - 'A';
				if (objSpawn < 0 || objSpawn > g_maxZone || objRemove < 0 || objRemove > g_maxZone || objSpawn > objRemove)
				{
					PrintToServer("[BSE-Spawn] Error: couldn't spawn an ins_blockzone at %.2f %.2f %.2f. Valid objective bounds: A..%c, found: spawn = %c, remove = %c.",
									origin[0], origin[1], origin[2], 'A' + g_maxZone, objSpawn, objRemove);
					continue;
				}
				decl Float:minBounds[3], Float:maxBounds[3];
				for (new i = 0; i < 3; ++i)
				{
					minBounds[i] = -size[i] / 2;
					maxBounds[i] =  size[i] / 2;
				}
				// https://forums.alliedmods.net/showthread.php?t=129597
				DispatchSpawn(ent);
				TeleportEntity(ent, origin, NULL_VECTOR, NULL_VECTOR);
				SetEntityModel(ent, AOF_DUMMY_MODEL_NAME);
				SetEntPropVector(ent, Prop_Send, "m_vecMins", minBounds);
				SetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxBounds);
				PushArrayCell(g_activateBlockZones[objSpawn], ent);
				PushArrayCell(g_deactivateBlockZones[objRemove], ent);
				PrintToServer("[BSE-Spawn] Created an ins_blockzone at %.2f %.2f %.2f; it activates when %c becomes available and deactivates when %c is captured; entity index is %d.",
								origin[0], origin[1], origin[2], objSpawn + 'A', objRemove + 'A', ent);
			}
		} while (kv.GotoNextKey());
		kv.Rewind();
	}
	
	// Read "hurt_entities" if it exists.
	if (kv.JumpToKey("hurt_entities"))
	{
		kv.GotoFirstSubKey(); // in "0", "1" etc
		do
		{
			decl String:className[100], String:targetName[100], String:amountStr[100];
			new String:curTargetName[100]; // NOT DECL
			kv.GetString("classname", className, sizeof(className), "");
			kv.GetString("targetname", targetName, sizeof(targetName), "");
			new amount = kv.GetNum("amount", 1000);
			IntToString(amount, amountStr, sizeof(amountStr));
			new ent = -1, bool:isFound = false;
			while ((ent = FindEntityByClassname(ent, className)) != -1)
			{
				if (IsValidEntity(ent) && strlen(targetName) > 0)
				{
					GetEntPropString(ent, Prop_Data, "m_iName", curTargetName, sizeof(curTargetName));
					if (StrEqual(curTargetName, targetName, false))
					{
						isFound = true;
						new pointHurt = CreateEntityByName("point_hurt");
						if (pointHurt)
						{
							DispatchKeyValue(ent, "targetname", "hurtme");
							DispatchKeyValue(pointHurt, "DamageTarget", "hurtme");
							DispatchKeyValue(pointHurt, "Damage", amountStr);
							DispatchKeyValue(pointHurt, "DamageType", "0");
							DispatchSpawn(pointHurt);
							AcceptEntityInput(pointHurt, "Hurt", -1);
							DispatchKeyValue(ent, "targetname", "donthurtme");
							AcceptEntityInput(pointHurt, "Kill");
							PrintToServer("[BSE-Hurt] Hurt entity \"%s\" (\"%s\") by %d health.", curTargetName, className, amount);
						}
						else
						{
							PrintToServer("[BSE-Hurt] Failed to create point_hurt to hurt entity \"%s\" (\"%s\") by %d health.", curTargetName, className, amount);
						}
					}
				}
			}
			if (!isFound)
			{
				PrintToServer("[BSE-Hurt] Couldn't find entity \"%s\" (\"%s\") to hurt it by %d health.", targetName, className, amount);
			}
		} while (kv.GotoNextKey());
		kv.Rewind();
	}
	
	return true;
}

// Suppress messages like "BOT Name changed name to (1)BOT Name"
public Action:Event_NameChanged(Event event, const char[] name, bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IsFakeClient(client))
	{
		event.BroadcastDisabled = true;
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action:Event_GameStart(Event event, const char[] name, bool:dontBroadcast)
{
	ResetDifVote();
	CreateTimer(1.0, Timer_DelayedCvarReset, _, TIMER_FLAG_NO_MAPCHANGE); // v1.4
	g_isInGame = false;
	g_roundNumber = 0;
	PrintToServer("[AoF-Debug] Event_GameStart called!");
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		g_hasSpawnedBefore[client] = false;
	}
	return Plugin_Continue;
}

public Action:Timer_DelayedCvarReset(Handle timer)
{
	ResetServerCVars();
}
	
public Action:Event_GameEnd(Event event, const char[] name, bool:dontBroadcast)
{
	g_isInGame = false;
	new winner = GetEventInt(event, "winner");
	//PrintToServer("[AoF-Debug] Game ended, winner team id: %d.", winner)
	if (winner == view_as<int>(TEAM_SECURITY) && serverEnableGroupInvite)
	{
		PrintToChatAll("\x07%s[AoF] %t http://steamcommunity.com/groups/ins_aof", COLOR_AOF_JOIN_GROUP, "join_group");
	}
	return Plugin_Continue;
}

ResetDifVote()
{
	SetConVarInt(cvarInsBotDifficulty, 1, false, false); // reset to Normal.
	g_isdifVoteReady = true;
	ClearArray(g_difVoteList);
}

PrintDifVote()
{
	if (!g_isdifVoteReady)
	{
		return;
	}
	g_isdifVoteReady = false;
	for (new human = 1; human <= GetMaxClients(); ++human)
	{
		if (IsAliveHuman(human))
		{
			DisplayMenu(g_difVoteHandle, human, 14);
		}
	}
	CreateTimer(14.5, Timer_FinalizeVote, _, TIMER_FLAG_NO_MAPCHANGE);
}

public DifMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	new client = param1;
	new difficulty = param2;
	switch (action)
	{
		case MenuAction_Display:
		{
			// Localize the menu title.
			decl String:menuName[255];
			Format(menuName, sizeof(menuName), "%T", "vote_menu_title", client); 
			new Handle:panel = Handle:param2;
			SetPanelTitle(panel, menuName);
		}
		case MenuAction_DisplayItem:
		{
			// Localize each of the menu items.
			decl String:difName[100];
			GetMenuItem(menu, difficulty, difName, sizeof(difName)); 
			decl String:difTranslatedName[100];
			Format(difTranslatedName, sizeof(difTranslatedName), "%T", difName, client);
			return RedrawMenuItem(difTranslatedName);
		}
		case MenuAction_Select:
		{
			// Process the difficulty selection.
			decl String:playerName[255];
			GetClientName(client, playerName, sizeof(playerName));
			decl String:difNameLocalized[100];
			Format(difNameLocalized, sizeof(difNameLocalized), "%T", l_difficultyName[difficulty], client);
			PrintToChat(client, "\x07%s[AoF] %t", COLOR_AOF_SELECTED_DIFF, "vote_reply", difNameLocalized);
			PushArrayCell(g_difVoteList, difficulty); // save this player's difficulty choice
		} 
		case MenuAction_Cancel:
		{
		}
		case MenuAction_End:
		{
		}
	}
	return 0;
}

public Action:Timer_FinalizeVote(Handle timer)
{
	new voteCount = GetArraySize(g_difVoteList);
	if (voteCount == 0)
	{
		// Noone voted.
		SetConVarInt(cvarInsBotDifficulty, 1, false, false); // default is Normal.
		PrintToChatAll("\x07%s[AoF] %t", COLOR_AOF_DIFF_VOTE_END, "vote_end_no_votes");
	}
	else
	{
		// There has been one or more votes. Let's calculate the average difficulty.
		new accum = 0;
		for (new vote = 0; vote < voteCount; ++vote)
		{
			accum += GetArrayCell(g_difVoteList, vote);
		}
		new dif = RoundToFloor(((accum * 1.0) / voteCount) + 0.49);
		SetConVarInt(cvarInsBotDifficulty, dif, false, false);
		// Display the localized list of difficulties selected by players.
		for (new client = 1; client <= GetMaxClients(); ++client)
		{
			if (IsHuman(client))
			{
				// Initialize the difficulty list with the first element.
				decl String:strList[500];
				Format(strList, sizeof(strList), "%T", l_difficultyName[GetArrayCell(g_difVoteList, 0)], client);
				for (new i = 1; i < voteCount; ++i)
				{
					// Inside the lopp, add a separator and the next difficulty name.
					Format(strList, sizeof(strList), "%s%T%T",
							strList,
							"vote_list_separator", client,
							l_difficultyName[GetArrayCell(g_difVoteList, i)], client);
				}
				// The difficulty list is passed as an argument.
				PrintToChat(client, "\x07%s[AoF] %t", COLOR_AOF_DIFF_VOTE_END, "vote_end", strList);
			}
		}
	}
}

public Action:Timer_AnnounceDifficulty(Handle timer)
{
	if ((GetTime() - g_lastVotePrintTimestamp < 2) || g_roundNumber == 0)
	{
		return;
	}
	g_lastVotePrintTimestamp = GetTime();
	for (new client = 1; client <= GetMaxClients(); ++client)
	{
		if (IsHuman(client))
		{
			PrintDifficulty(client);
		}
	}
}

public Action:Timer_AnnounceDifficultyToOne(Handle timer, client)
{
	if (IsAliveHuman(client) && g_isInGame && g_roundNumber > 0) // double-checking just in case.
	{
		PrintDifficulty(client);
	}
}

void PrintDifficulty(client)
{
	decl String:difNameLocalized[100];
	Format(difNameLocalized, sizeof(difNameLocalized), "%T", l_difficultyName[serverDifficulty], client);
	//decl String:difColor[100];
	//switch (serverDifficulty)
	//{
	//	case 0: { strcopy(difColor, sizeof(difColor), COLOR_AOF_DIFF_EASY);		}
	//	case 1: { strcopy(difColor, sizeof(difColor), COLOR_AOF_DIFF_NORMAL);	}
	//	case 2: { strcopy(difColor, sizeof(difColor), COLOR_AOF_DIFF_HARD);		}
	//	case 3: { strcopy(difColor, sizeof(difColor), COLOR_AOF_DIFF_BRUTAL);	}
	//}
	//PrintToChat(client, "\x07%s[AoF] %t", difColor, "announce_difficulty", difNameLocalized);
	PrintToChat(client, "\x07%s[AoF] %t", COLOR_AOF_DIFF_CURRENT, "announce_difficulty", difNameLocalized);	
}

public Action:Event_Generic(Handle:event, const String:name[], bool:dontBroadcast)
{
	PrintToServer("[AoF] Event \"%s\" fired.", name);
}

RemoveSprinklers()
{
	new count = 0;
	for (;;) // while (true) = reduntant test warning, lol
	{
		new ent = FindEntityByClassname(-1, "prop_sprinkler");
		if (ent == -1)
		{
			break;
		}
		++count;
		RemoveEdict(ent);
	}
	if (count > 0)
	{
		PrintToServer("[AoF] Removed %d sprinklers.", count);
	}
}

