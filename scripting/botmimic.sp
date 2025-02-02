/**
 * Bot Mimic - Record your movments and have bots playing it back.
 * by Peace-Maker
 * visit http://wcfan.de
 *
 * Changelog:
 * 2.0   - 22.07.2013: Released rewrite
 * 2.0.1 - 01.08.2013: Actually made DHooks an optional dependency.
 * 2.1   - 02.10.2014: Added bookmarks and pausing/resuming while recording. Fixed crashes and problems with CS:GO.
 */

#include <botmimic>
#include <cstrike>
#include <sdkhooks>
#include <sdktools>
#include <smlib>
#include <sourcemod>

#undef REQUIRE_EXTENSIONS
#include <dhooks>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "2.1"

#define BM_MAGIC 0xdeadbeef

// New in 0x02: bookmarkCount and bookmarks list
#define BINARY_FORMAT_VERSION 0x02

#define DEFAULT_RECORD_FOLDER "data/botmimic/"

// Flags set in FramInfo.additionalFields to inform, that there's more info afterwards.
#define ADDITIONAL_FIELD_TELEPORTED_ORIGIN   (1 << 0)
#define ADDITIONAL_FIELD_TELEPORTED_ANGLES   (1 << 1)
#define ADDITIONAL_FIELD_TELEPORTED_VELOCITY (1 << 2)

enum struct FrameInfo
{
	int        playerButtons;
	int        playerImpulse;
	float      actualVelocity[3];
	float      predictedVelocity[3];
	float      predictedAngles[2];    // Ignore roll
	CSWeaponID newWeapon;
	int        playerSubtype;
	int        playerSeed;
	int        additionalFields;    // see ADDITIONAL_FIELD_* defines
}

#define AT_ORIGIN   0
#define AT_ANGLES   1
#define AT_VELOCITY 2
#define AT_FLAGS    3

enum struct AdditionalTeleport
{
	float atOrigin[3];
	float atAngles[3];
	float atVelocity[3];
	int   atFlags;
}

enum struct FileHeader
{
	int       FH_binaryFormatVersion;
	int       FH_recordEndTime;
	char      FH_recordName[MAX_RECORD_NAME_LENGTH];
	int       FH_tickCount;
	int       FH_bookmarkCount;
	float     FH_initialPosition[3];
	float     FH_initialAngles[3];
	ArrayList FH_bookmarks;
	ArrayList FH_frames;
}

enum struct Bookmarks
{
	int  BKM_frame;
	int  BKM_additionalTeleportTick;
	char BKM_name[MAX_BOOKMARK_NAME_LENGTH];
}

// Used to fire the OnPlayerMimicBookmark effciently during playback
enum
{
	BWM_frame = 0,    // The frame this bookmark was saved in
	BWM_index,    // The index into the FH_bookmarks array in the fileheader for the corresponding bookmark (to get the name)
	BWM_SIZES
};

// Where did he start recording. The bot is teleported to this position on replay.
float     g_fInitialPosition[MAXPLAYERS + 1][3];
float     g_fInitialAngles[MAXPLAYERS + 1][3];
// Array of frames
ArrayList g_hRecording[MAXPLAYERS + 1];
ArrayList g_hRecordingAdditionalTeleport[MAXPLAYERS + 1];
ArrayList g_hRecordingBookmarks[MAXPLAYERS + 1];
int       g_iCurrentAdditionalTeleportIndex[MAXPLAYERS + 1];
// Is the recording currently paused?
bool      g_bRecordingPaused[MAXPLAYERS + 1];
bool      g_bSaveFullSnapshot[MAXPLAYERS + 1];
// How many calls to OnPlayerRunCmd were recorded?
int       g_iRecordedTicks[MAXPLAYERS + 1];
// What's the last active weapon
int       g_iRecordPreviousWeapon[MAXPLAYERS + 1];
// Count ticks till we save the position again
int       g_iOriginSnapshotInterval[MAXPLAYERS + 1];
// The name of this recording
char      g_sRecordName[MAXPLAYERS + 1][MAX_RECORD_NAME_LENGTH];
char      g_sRecordPath[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char      g_sRecordCategory[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char      g_sRecordSubDir[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

StringMap g_hLoadedRecords;
StringMap g_hLoadedRecordsAdditionalTeleport;
StringMap g_hLoadedRecordsCategory;
ArrayList g_hSortedRecordList;
ArrayList g_hSortedCategoryList;

ArrayList g_hBotMimicsRecord[MAXPLAYERS + 1]         = { null, ... };
int       g_iBotMimicTick[MAXPLAYERS + 1]            = { 0, ... };
int       g_iBotMimicRecordTickCount[MAXPLAYERS + 1] = { 0, ... };
int       g_iBotActiveWeapon[MAXPLAYERS + 1]         = { -1, ... };
bool      g_bBotSwitchedWeapon[MAXPLAYERS + 1];
bool      g_bValidTeleportCall[MAXPLAYERS + 1];
int       g_iBotMimicNextBookmarkTick[MAXPLAYERS + 1][BWM_SIZES];

Handle g_hfwdOnStartRecording;
Handle g_hfwdOnRecordingPauseStateChanged;
Handle g_hfwdOnRecordingBookmarkSaved;
Handle g_hfwdOnStopRecording;
Handle g_hfwdOnRecordSaved;
Handle g_hfwdOnRecordDeleted;
Handle g_hfwdOnPlayerStartsMimicing;
Handle g_hfwdOnPlayerStopsMimicing;
Handle g_hfwdOnPlayerMimicLoops;
Handle g_hfwdOnPlayerMimicBookmark;

// DHooks
Handle g_hTeleport;

ConVar g_hCVOriginSnapshotInterval;
ConVar g_hCVRespawnOnDeath;

public Plugin myinfo =
{
	name        = "Bot Mimic",
	author      = "Jannik \"Peace-Maker\" Hartung",
	description = "Bots mimic your movements!",
	version     = PLUGIN_VERSION,
	url         = "http://www.wcfan.de/"

}

public APLRes
	AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("botmimic");
	CreateNative("BotMimic_StartRecording", StartRecording);
	CreateNative("BotMimic_PauseRecording", PauseRecording);
	CreateNative("BotMimic_ResumeRecording", ResumeRecording);
	CreateNative("BotMimic_IsRecordingPaused", IsRecordingPaused);
	CreateNative("BotMimic_StopRecording", StopRecording);
	CreateNative("BotMimic_SaveBookmark", SaveBookmark);
	CreateNative("BotMimic_DeleteRecord", DeleteRecord);
	CreateNative("BotMimic_IsPlayerRecording", IsPlayerRecording);
	CreateNative("BotMimic_IsPlayerMimicing", IsPlayerMimicing);
	CreateNative("BotMimic_GetRecordPlayerMimics", GetRecordPlayerMimics);
	CreateNative("BotMimic_PlayRecordFromFile", PlayRecordFromFile);
	CreateNative("BotMimic_PlayRecordByName", PlayRecordByName);
	CreateNative("BotMimic_ResetPlayback", ResetPlayback);
	CreateNative("BotMimic_GoToBookmark", GoToBookmark);
	CreateNative("BotMimic_StopPlayerMimic", StopPlayerMimic);
	CreateNative("BotMimic_GetFileHeaders", GetFileHeaders);
	CreateNative("BotMimic_ChangeRecordName", ChangeRecordName);
	CreateNative("BotMimic_GetLoadedRecordCategoryList", GetLoadedRecordCategoryList);
	CreateNative("BotMimic_GetLoadedRecordList", GetLoadedRecordList);
	CreateNative("BotMimic_GetFileCategory", GetFileCategory);
	CreateNative("BotMimic_GetRecordBookmarks", GetRecordBookmarks);

	g_hfwdOnStartRecording             = CreateGlobalForward("BotMimic_OnStartRecording", ET_Hook, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	g_hfwdOnRecordingPauseStateChanged = CreateGlobalForward("BotMimic_OnRecordingPauseStateChanged", ET_Ignore, Param_Cell, Param_Cell);
	g_hfwdOnRecordingBookmarkSaved     = CreateGlobalForward("BotMimic_OnRecordingBookmarkSaved", ET_Ignore, Param_Cell, Param_String);
	g_hfwdOnStopRecording              = CreateGlobalForward("BotMimic_OnStopRecording", ET_Hook, Param_Cell, Param_String, Param_String, Param_String, Param_String, Param_CellByRef);
	g_hfwdOnRecordSaved                = CreateGlobalForward("BotMimic_OnRecordSaved", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	g_hfwdOnRecordDeleted              = CreateGlobalForward("BotMimic_OnRecordDeleted", ET_Ignore, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerStartsMimicing       = CreateGlobalForward("BotMimic_OnPlayerStartsMimicing", ET_Hook, Param_Cell, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerStopsMimicing        = CreateGlobalForward("BotMimic_OnPlayerStopsMimicing", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerMimicLoops           = CreateGlobalForward("BotMimic_OnPlayerMimicLoops", ET_Ignore, Param_Cell);
	g_hfwdOnPlayerMimicBookmark        = CreateGlobalForward("BotMimic_OnPlayerMimicBookmark", ET_Ignore, Param_Cell, Param_String);
}

public void OnPluginStart()
{
	ConVar hVersion = CreateConVar("sm_botmimic_version", PLUGIN_VERSION, "Bot Mimic version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	if (hVersion != null)
	{
		hVersion.SetString(PLUGIN_VERSION);
		hVersion.AddChangeHook(ConVar_VersionChanged);
	}

	// Save the position of clients every 10000 ticks
	// This is to avoid bots getting stuck in walls due to slightly lower jumps, if they don't touch the ground.
	g_hCVOriginSnapshotInterval = CreateConVar("sm_botmimic_snapshotinterval", "10000", "Save the position of clients every x ticks. This is to avoid bots getting stuck in walls during a long playback and lots of jumps.", _, true, 0.0);
	g_hCVRespawnOnDeath         = CreateConVar("sm_botmimic_respawnondeath", "1", "Respawn the bot when he dies during playback?", _, true, 0.0, true, 1.0);

	AutoExecConfig();

	// Maps path to .rec -> record enum
	g_hLoadedRecords                   = new StringMap();
	g_hLoadedRecordsAdditionalTeleport = new StringMap();

	// Maps path to .rec -> record category
	g_hLoadedRecordsCategory = new StringMap();

	// Save all paths to .rec files in the trie sorted by time
	g_hSortedRecordList   = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_hSortedCategoryList = new ArrayList(ByteCountToCells(64));

	HookEvent("player_spawn", Event_OnPlayerSpawn);
	HookEvent("player_death", Event_OnPlayerDeath);

	if (LibraryExists("dhooks"))
	{
		OnLibraryAdded("dhooks");
	}
}

public void ConVar_VersionChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	convar.SetString(PLUGIN_VERSION);
}

/**
 * Public forwards
 */
public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "dhooks") && g_hTeleport == null)
	{
		// Optionally setup a hook on CBaseEntity::Teleport to keep track of sudden place changes
		Handle hGameData = LoadGameConfigFile("sdktools.games");
		if (hGameData == null)
			return;
		int iOffset = GameConfGetOffset(hGameData, "Teleport");
		delete hGameData;
		if (iOffset == -1)
			return;

		g_hTeleport = DHookCreate(iOffset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, DHooks_OnTeleport);
		if (g_hTeleport == null)
			return;
		DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
		DHookAddParam(g_hTeleport, HookParamType_ObjectPtr);
		DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
		if (GetEngineVersion() == Engine_CSGO)
			DHookAddParam(g_hTeleport, HookParamType_Bool);

		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i))
				OnClientPutInServer(i);
		}
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "dhooks"))
	{
		g_hTeleport = null;
	}
}

public void OnMapStart()
{
	// Clear old records for old map
	int    iSize = g_hSortedRecordList.Length;
	char   sPath[PLATFORM_MAX_PATH];
	FileHeader header;
	Handle hAdditionalTeleport;
	for (int i = 0; i < iSize; i++)
	{
		g_hSortedRecordList.GetString(i, sPath, sizeof(sPath));
		if (!g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader)))
		{
			LogError("Internal state error. %s was in the sorted list, but not in the actual storage.", sPath);
			continue;
		}
		if (header.FH_frames != null)
			delete header.FH_frames;
		if (header.FH_bookmarks != null)
			delete header.FH_bookmarks;
		if (g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAdditionalTeleport))
			delete hAdditionalTeleport;
	}
	g_hLoadedRecords.Clear();
	g_hLoadedRecordsAdditionalTeleport.Clear();
	g_hLoadedRecordsCategory.Clear();
	g_hSortedRecordList.Clear();
	g_hSortedCategoryList.Clear();

	// Create our record directory
	BuildPath(Path_SM, sPath, sizeof(sPath), DEFAULT_RECORD_FOLDER);
	if (!DirExists(sPath))
		CreateDirectory(sPath, 511);

	// Check for categories
	DirectoryListing hDir = OpenDirectory(sPath);
	if (hDir == null)
		return;

	char     sFile[64];
	FileType fileType;
	while (hDir.GetNext(sFile, sizeof(sFile), fileType))
	{
		switch (fileType)
		{
			// Check all directories for records on this map
			case FileType_Directory:
			{
				// INFINITE RECURSION ANYONE?
				if (StrEqual(sFile, ".") || StrEqual(sFile, ".."))
					continue;

				BuildPath(Path_SM, sPath, sizeof(sPath), "%s%s", DEFAULT_RECORD_FOLDER, sFile);
				ParseRecordsInDirectory(sPath, sFile, false);
			}
		}
	}
	delete hDir;
}

public void OnClientPutInServer(int client)
{
	if (g_hTeleport != null)
		DHookEntity(g_hTeleport, false, client);
}

public void OnClientDisconnect(int client)
{
	if (g_hRecording[client] != null)
		BotMimic_StopRecording(client);

	if (g_hBotMimicsRecord[client] != null)
		BotMimic_StopPlayerMimic(client);
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	// Client isn't recording or recording is paused.
	if (g_hRecording[client] == null || g_bRecordingPaused[client])
		return;

	FrameInfo frame;
	frame.playerButtons = buttons;
	frame.playerImpulse = impulse;

	float vVel[3];
	Entity_GetAbsVelocity(client, vVel);
	frame.actualVelocity    = vVel;
	frame.predictedVelocity = vel;
	Array_Copy(angles, frame.predictedAngles, 2);
	frame.newWeapon     = CSWeapon_NONE;
	frame.playerSubtype = subtype;
	frame.playerSeed    = seed;

	// Save the origin, angles and velocity in this frame.
	if (g_bSaveFullSnapshot[client])
	{
		AdditionalTeleport cache;
		float fBuffer[3];
		GetClientAbsOrigin(client, fBuffer);
		Array_Copy(fBuffer, cache.atOrigin, 3);
		GetClientEyeAngles(client, fBuffer);
		Array_Copy(fBuffer, cache.atAngles, 3);
		Entity_GetAbsVelocity(client, fBuffer);
		Array_Copy(fBuffer, cache.atVelocity, 3);

		cache.atFlags = ADDITIONAL_FIELD_TELEPORTED_ORIGIN | ADDITIONAL_FIELD_TELEPORTED_ANGLES | ADDITIONAL_FIELD_TELEPORTED_VELOCITY;
		g_hRecordingAdditionalTeleport[client].PushArray(cache, sizeof(AdditionalTeleport));
		g_bSaveFullSnapshot[client] = false;
	}
	else
	{
		// Save the current position
		int iInterval = g_hCVOriginSnapshotInterval.IntValue;
		if (iInterval > 0 && g_iOriginSnapshotInterval[client] > iInterval)
		{
			AdditionalTeleport cache;
			float origin[3];
			GetClientAbsOrigin(client, origin);
			Array_Copy(origin, cache.atOrigin, 3);
			cache.atFlags |= ADDITIONAL_FIELD_TELEPORTED_ORIGIN;
			g_hRecordingAdditionalTeleport[client].PushArray(cache, sizeof(AdditionalTeleport));
			g_iOriginSnapshotInterval[client] = 0;
		}
	}

	g_iOriginSnapshotInterval[client]++;

	// Check for additional Teleports
	if (g_hRecordingAdditionalTeleport[client].Length > g_iCurrentAdditionalTeleportIndex[client])
	{
		AdditionalTeleport cache;
		g_hRecordingAdditionalTeleport[client].GetArray(g_iCurrentAdditionalTeleportIndex[client], cache, sizeof(AdditionalTeleport));
		// Remember, we were teleported this frame!
		frame.additionalFields |= cache.atFlags;
		g_iCurrentAdditionalTeleportIndex[client]++;
	}

	int iNewWeapon = -1;

	// Did he change his weapon?
	if (weapon)
	{
		iNewWeapon = weapon;
	}
	// Picked up a new one?
	else
	{
		int iWeapon = Client_GetActiveWeapon(client);

		// He's holding a weapon and
		if (iWeapon != -1 &&
		    // we just started recording. Always save the first weapon!
		    (g_iRecordedTicks[client] == 0 ||
		     // This is a new weapon, he didn't held before.
		     g_iRecordPreviousWeapon[client] != iWeapon))
		{
			iNewWeapon = iWeapon;
		}
	}

	if (iNewWeapon != -1)
	{
		// Save it
		if (IsValidEntity(iNewWeapon) && IsValidEdict(iNewWeapon))
		{
			g_iRecordPreviousWeapon[client] = iNewWeapon;

			char sClassName[64];
			GetEdictClassname(iNewWeapon, sClassName, sizeof(sClassName));
			ReplaceString(sClassName, sizeof(sClassName), "weapon_", "", false);

			char sWeaponAlias[64];
			CS_GetTranslatedWeaponAlias(sClassName, sWeaponAlias, sizeof(sWeaponAlias));
			CSWeaponID weaponId = CS_AliasToWeaponID(sWeaponAlias);

			frame.newWeapon = weaponId;
		}
	}

	g_hRecording[client].PushArray(frame, sizeof(FrameInfo));

	g_iRecordedTicks[client]++;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	// Bot is mimicing something
	if (g_hBotMimicsRecord[client] == null)
		return Plugin_Continue;

	// Is this a valid living bot?
	if (!IsPlayerAlive(client) || GetClientTeam(client) < CS_TEAM_T)
		return Plugin_Continue;

	if (g_iBotMimicTick[client] >= g_iBotMimicRecordTickCount[client])
	{
		g_iBotMimicTick[client]                   = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
	}

	FrameInfo frame;
	g_hBotMimicsRecord[client].GetArray(g_iBotMimicTick[client], frame, sizeof(FrameInfo));

	buttons = frame.playerButtons;
	impulse = frame.playerImpulse;
	Array_Copy(frame.predictedVelocity, vel, 3);
	Array_Copy(frame.predictedAngles, angles, 2);
	subtype = frame.playerSubtype;
	seed    = frame.playerSeed;
	weapon  = 0;

	float fActualVelocity[3];
	Array_Copy(frame.actualVelocity, fActualVelocity, 3);

	// We're supposed to teleport stuff?
	if (frame.additionalFields & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN | ADDITIONAL_FIELD_TELEPORTED_ANGLES | ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
	{
		AdditionalTeleport cache;
		ArrayList hAdditionalTeleport;
		char      sPath[PLATFORM_MAX_PATH];
		GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
		g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAdditionalTeleport);
		hAdditionalTeleport.GetArray(g_iCurrentAdditionalTeleportIndex[client], cache, sizeof(AdditionalTeleport));

		float fOrigin[3], fAngles[3], fVelocity[3];
		Array_Copy(cache.atOrigin, fOrigin, 3);
		Array_Copy(cache.atAngles, fAngles, 3);
		Array_Copy(cache.atVelocity, fVelocity, 3);

		// The next call to Teleport is ok.
		g_bValidTeleportCall[client] = true;

		// THATS STUPID!
		// Only pass the arguments, if they were set..
		if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
		{
			if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
			{
				if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
					TeleportEntity(client, fOrigin, fAngles, fVelocity);
				else
					TeleportEntity(client, fOrigin, fAngles, NULL_VECTOR);
			}
			else
			{
				if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
					TeleportEntity(client, fOrigin, NULL_VECTOR, fVelocity);
				else
					TeleportEntity(client, fOrigin, NULL_VECTOR, NULL_VECTOR);
			}
		}
		else
		{
			if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
			{
				if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
					TeleportEntity(client, NULL_VECTOR, fAngles, fVelocity);
				else
					TeleportEntity(client, NULL_VECTOR, fAngles, NULL_VECTOR);
			}
			else
			{
				if (cache.atFlags & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
					TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fVelocity);
			}
		}

		g_iCurrentAdditionalTeleportIndex[client]++;
	}

	// This is the first tick. Teleport him to the initial position
	if (g_iBotMimicTick[client] == 0)
	{
		g_bValidTeleportCall[client] = true;
		TeleportEntity(client, g_fInitialPosition[client], g_fInitialAngles[client], fActualVelocity);
		Client_RemoveAllWeapons(client);

		Call_StartForward(g_hfwdOnPlayerMimicLoops);
		Call_PushCell(client);
		Call_Finish();
	}
	else
	{
		g_bValidTeleportCall[client] = true;
		TeleportEntity(client, NULL_VECTOR, angles, fActualVelocity);
	}

	if (frame.newWeapon != CSWeapon_NONE)
	{
		char sAlias[64];
		CS_WeaponIDToAlias(frame.newWeapon, sAlias, sizeof(sAlias));

		Format(sAlias, sizeof(sAlias), "weapon_%s", sAlias);

		if (g_iBotMimicTick[client] > 0 && Client_HasWeapon(client, sAlias))
		{
			weapon                       = Client_GetWeapon(client, sAlias);
			g_iBotActiveWeapon[client]   = weapon;
			g_bBotSwitchedWeapon[client] = true;
		}
		else
		{
			weapon = GivePlayerItem(client, sAlias);
			if (weapon != INVALID_ENT_REFERENCE)
			{
				g_iBotActiveWeapon[client]   = weapon;
				// Switch to that new weapon on the next frame.
				g_bBotSwitchedWeapon[client] = true;

				// Grenades shouldn't be equipped.
				if (StrContains(sAlias, "grenade") == -1
				    && StrContains(sAlias, "flashbang") == -1
				    && StrContains(sAlias, "decoy") == -1
				    && StrContains(sAlias, "molotov") == -1)
				{
					EquipPlayerWeapon(client, weapon);
				}
			}
		}
	}
	// Switch the weapon on the next frame after it was selected.
	else if (g_bBotSwitchedWeapon[client])
	{
		g_bBotSwitchedWeapon[client] = false;
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", g_iBotActiveWeapon[client]);
		Client_SetActiveWeapon(client, g_iBotActiveWeapon[client]);
	}

	// See if there's a bookmark on this tick
	if (g_iBotMimicTick[client] == g_iBotMimicNextBookmarkTick[client][BWM_frame])
	{
		// Get the file header of the current playing record.
		char sPath[PLATFORM_MAX_PATH];
		GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
		FileHeader header;
		g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader));

		Bookmarks bmCache;
		header.FH_bookmarks.GetArray(g_iBotMimicNextBookmarkTick[client][BWM_index], bmCache, sizeof(Bookmarks));

		// Cache the next tick in which we should fire the forward.
		UpdateNextBookmarkTick(client);

		// Call the forward
		Call_StartForward(g_hfwdOnPlayerMimicBookmark);
		Call_PushCell(client);
		Call_PushString(bmCache.BKM_name);
		Call_Finish();
	}

	g_iBotMimicTick[client]++;

	return Plugin_Changed;
}

/**
 * Event Callbacks
 */
public void Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client)
		return;

	// Restart moving on spawn!
	if (g_hBotMimicsRecord[client] != null)
	{
		g_iBotMimicTick[client]                   = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
	}
}

public void Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client)
		return;

	// This one has been recording currently
	if (g_hRecording[client] != null)
	{
		BotMimic_StopRecording(client, true);
	}
	// This bot has been playing one
	else if (g_hBotMimicsRecord[client] != null)
	{
		// Respawn the bot after death!
		g_iBotMimicTick[client]                   = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
		if (g_hCVRespawnOnDeath.BoolValue && GetClientTeam(client) >= CS_TEAM_T)
			CreateTimer(1.0, Timer_DelayedRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

/**
 * Timer Callbacks
 */
public Action Timer_DelayedRespawn(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!client)
		return Plugin_Stop;

	if (g_hBotMimicsRecord[client] != null && IsClientInGame(client) && !IsPlayerAlive(client) && IsFakeClient(client) && GetClientTeam(client) >= CS_TEAM_T)
		CS_RespawnPlayer(client);

	return Plugin_Stop;
}

/**
 * SDKHooks Callbacks
 */
// Don't allow mimicing players any other weapon than the one recorded!!
public Action Hook_WeaponCanSwitchTo(int client, int weapon)
{
	if (g_hBotMimicsRecord[client] == null)
		return Plugin_Continue;

	if (g_iBotActiveWeapon[client] != weapon)
	{
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

/**
 * DHooks Callbacks
 */
public MRESReturn DHooks_OnTeleport(int client, Handle hParams)
{
	// This one is currently mimicing something.
	if (g_hBotMimicsRecord[client] != null)
	{
		// We didn't allow that teleporting. STOP THAT.
		if (!g_bValidTeleportCall[client])
			return MRES_Supercede;
		g_bValidTeleportCall[client] = false;
		return MRES_Ignored;
	}

	// Don't care if he's not recording.
	if (g_hRecording[client] == null)
		return MRES_Ignored;

	float origin[3], angles[3], velocity[3];
	bool  bOriginNull   = DHookIsNullParam(hParams, 1);
	bool  bAnglesNull   = DHookIsNullParam(hParams, 2);
	bool  bVelocityNull = DHookIsNullParam(hParams, 3);

	if (!bOriginNull)
		DHookGetParamVector(hParams, 1, origin);

	if (!bAnglesNull)
	{
		for (int i = 0; i < 3; i++)
			angles[i] = DHookGetParamObjectPtrVar(hParams, 2, i * 4, ObjectValueType_Float);
	}

	if (!bVelocityNull)
		DHookGetParamVector(hParams, 3, velocity);

	if (bOriginNull && bAnglesNull && bVelocityNull)
		return MRES_Ignored;

	AdditionalTeleport atCache;
	Array_Copy(origin, atCache.atOrigin, 3);
	Array_Copy(angles, atCache.atAngles, 3);
	Array_Copy(velocity, atCache.atVelocity, 3);

	// Remember,
	if (!bOriginNull)
		atCache.atFlags |= ADDITIONAL_FIELD_TELEPORTED_ORIGIN;
	if (!bAnglesNull)
		atCache.atFlags |= ADDITIONAL_FIELD_TELEPORTED_ANGLES;
	if (!bVelocityNull)
		atCache.atFlags |= ADDITIONAL_FIELD_TELEPORTED_VELOCITY;

	g_hRecordingAdditionalTeleport[client].PushArray(atCache, sizeof(AdditionalTeleport));

	return MRES_Ignored;
}

/**
 * Natives
 */
public int StartRecording(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (g_hRecording[client] != null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is already recording.");
		return;
	}

	if (g_hBotMimicsRecord[client] != null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is currently mimicing another record.");
		return;
	}

	g_hRecording[client]                   = new ArrayList(sizeof(FrameInfo));
	g_hRecordingAdditionalTeleport[client] = new ArrayList(sizeof(AdditionalTeleport));
	g_hRecordingBookmarks[client]          = new ArrayList(sizeof(Bookmarks));
	GetClientAbsOrigin(client, g_fInitialPosition[client]);
	GetClientEyeAngles(client, g_fInitialAngles[client]);
	g_iRecordedTicks[client]          = 0;
	g_iOriginSnapshotInterval[client] = 0;

	GetNativeString(2, g_sRecordName[client], MAX_RECORD_NAME_LENGTH);
	GetNativeString(3, g_sRecordCategory[client], PLATFORM_MAX_PATH);
	GetNativeString(4, g_sRecordSubDir[client], PLATFORM_MAX_PATH);

	if (g_sRecordCategory[client][0] == '\0')
		strcopy(g_sRecordCategory[client], sizeof(g_sRecordCategory[]), DEFAULT_CATEGORY);

	// Path:
	// data/botmimic/%CATEGORY%/map_name/%SUBDIR%/record.rec
	// subdir can be omitted, default category is "default"

	// All demos reside in the default path (data/botmimic)
	BuildPath(Path_SM, g_sRecordPath[client], PLATFORM_MAX_PATH, "%s%s", DEFAULT_RECORD_FOLDER, g_sRecordCategory[client]);

	// Remove trailing slashes
	if (g_sRecordPath[client][strlen(g_sRecordPath[client]) - 1] == '\\' || g_sRecordPath[client][strlen(g_sRecordPath[client]) - 1] == '/')
		g_sRecordPath[client][strlen(g_sRecordPath[client]) - 1] = '\0';

	Action result;
	Call_StartForward(g_hfwdOnStartRecording);
	Call_PushCell(client);
	Call_PushString(g_sRecordName[client]);
	Call_PushString(g_sRecordCategory[client]);
	Call_PushString(g_sRecordSubDir[client]);
	Call_PushString(g_sRecordPath[client]);
	Call_Finish(result);

	if (result >= Plugin_Handled)
		BotMimic_StopRecording(client, false);
}

public int PauseRecording(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}

	if (g_bRecordingPaused[client])
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Recording is already paused.");
		return;
	}

	g_bRecordingPaused[client] = true;

	Call_StartForward(g_hfwdOnRecordingPauseStateChanged);
	Call_PushCell(client);
	Call_PushCell(true);
	Call_Finish();
}

public int ResumeRecording(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}

	if (!g_bRecordingPaused[client])
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Recording is not paused.");
		return;
	}

	// Save the new full position, angles and velocity.
	g_bSaveFullSnapshot[client] = true;

	g_bRecordingPaused[client] = false;

	Call_StartForward(g_hfwdOnRecordingPauseStateChanged);
	Call_PushCell(client);
	Call_PushCell(false);
	Call_Finish();
}

public int IsRecordingPaused(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}

	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return false;
	}

	return g_bRecordingPaused[client];
}

public int StopRecording(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	// Not recording..
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}

	bool save = GetNativeCell(2);

	Action result;
	Call_StartForward(g_hfwdOnStopRecording);
	Call_PushCell(client);
	Call_PushString(g_sRecordName[client]);
	Call_PushString(g_sRecordCategory[client]);
	Call_PushString(g_sRecordSubDir[client]);
	Call_PushString(g_sRecordPath[client]);
	Call_PushCellRef(save);
	Call_Finish(result);

	// Don't stop recording?
	if (result >= Plugin_Handled)
		return;

	if (save)
	{
		int iEndTime = GetTime();

		char sMapName[64], sPath[PLATFORM_MAX_PATH];
		GetCurrentMap(sMapName, sizeof(sMapName));

		// Check if the default record folder exists?
		BuildPath(Path_SM, sPath, sizeof(sPath), DEFAULT_RECORD_FOLDER);
		// Remove trailing slashes
		if (sPath[strlen(sPath) - 1] == '\\' || sPath[strlen(sPath) - 1] == '/')
			sPath[strlen(sPath) - 1] = '\0';

		if (!CheckCreateDirectory(sPath, 511))
			return;

		// Check if the category folder exists?
		BuildPath(Path_SM, sPath, sizeof(sPath), "%s%s", DEFAULT_RECORD_FOLDER, g_sRecordCategory[client]);
		if (!CheckCreateDirectory(sPath, 511))
			return;

		// Check, if there is a folder for this map already
		Format(sPath, sizeof(sPath), "%s/%s", g_sRecordPath[client], sMapName);
		if (!CheckCreateDirectory(sPath, 511))
			return;

		// Check if the subdirectory exists
		if (g_sRecordSubDir[client][0] != '\0')
		{
			Format(sPath, sizeof(sPath), "%s/%s", sPath, g_sRecordSubDir[client]);
			if (!CheckCreateDirectory(sPath, 511))
				return;
		}

		Format(sPath, sizeof(sPath), "%s/%d.rec", sPath, iEndTime);

		// Add to our loaded record list
		FileHeader header;
		header.FH_binaryFormatVersion = BINARY_FORMAT_VERSION;
		header.FH_recordEndTime       = iEndTime;
		header.FH_tickCount           = g_hRecording[client].Length;
		strcopy(header.FH_recordName, MAX_RECORD_NAME_LENGTH, g_sRecordName[client]);
		Array_Copy(g_fInitialPosition[client], header.FH_initialPosition, 3);
		Array_Copy(g_fInitialAngles[client], header.FH_initialAngles, 3);
		header.FH_frames = g_hRecording[client];

		if (g_hRecordingBookmarks[client].Length > 0)
		{
			header.FH_bookmarkCount = g_hRecordingBookmarks[client].Length;
			header.FH_bookmarks     = g_hRecordingBookmarks[client];
		}
		else
		{
			delete g_hRecordingBookmarks[client];
		}

		if (g_hRecordingAdditionalTeleport[client].Length > 0)
		{
			g_hLoadedRecordsAdditionalTeleport.SetValue(sPath, g_hRecordingAdditionalTeleport[client]);
		}
		else
		{
			delete g_hRecordingAdditionalTeleport[client];
		}

		WriteRecordToDisk(sPath, header);

		g_hLoadedRecords.SetArray(sPath, header, sizeof(FileHeader));
		g_hLoadedRecordsCategory.SetString(sPath, g_sRecordCategory[client]);
		g_hSortedRecordList.PushString(sPath);
		if (g_hSortedCategoryList.FindString(g_sRecordCategory[client]) == -1)
			g_hSortedCategoryList.PushString(g_sRecordCategory[client]);
		SortRecordList();

		Call_StartForward(g_hfwdOnRecordSaved);
		Call_PushCell(client);
		Call_PushString(g_sRecordName[client]);
		Call_PushString(g_sRecordCategory[client]);
		Call_PushString(g_sRecordSubDir[client]);
		Call_PushString(sPath);
		Call_Finish();
	}
	else
	{
		delete g_hRecording[client];
		delete g_hRecordingAdditionalTeleport[client];
		delete g_hRecordingBookmarks[client];
	}

	g_hRecording[client]                      = null;
	g_hRecordingAdditionalTeleport[client]    = null;
	g_hRecordingBookmarks[client]             = null;
	g_iRecordedTicks[client]                  = 0;
	g_iRecordPreviousWeapon[client]           = 0;
	g_sRecordName[client][0]                  = 0;
	g_sRecordPath[client][0]                  = 0;
	g_sRecordCategory[client][0]              = 0;
	g_sRecordSubDir[client][0]                = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_iOriginSnapshotInterval[client]         = 0;
	g_bRecordingPaused[client]                = false;
	g_bSaveFullSnapshot[client]               = false;
}

public int SaveBookmark(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	// Not recording..
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}

	char sBookmarkName[MAX_BOOKMARK_NAME_LENGTH];
	GetNativeString(2, sBookmarkName, sizeof(sBookmarkName));

	// First check if there already is a bookmark with this name
	Bookmarks bmCache;
	int iSize = g_hRecordingBookmarks[client].Length;
	for (int i = 0; i < iSize; i++)
	{
		g_hRecordingBookmarks[client].GetArray(i, bmCache, sizeof(Bookmarks));
		if (StrEqual(bmCache.BKM_name, sBookmarkName, false))
		{
			ThrowNativeError(SP_ERROR_NATIVE, "There already is a bookmark named \"%s\".", sBookmarkName);
			return;
		}
	}

	// Save the current state so it can be restored when jumping to that frame.
	AdditionalTeleport atCache;
	float fBuffer[3];
	GetClientAbsOrigin(client, fBuffer);
	Array_Copy(fBuffer, atCache.atOrigin, 3);
	GetClientEyeAngles(client, fBuffer);
	Array_Copy(fBuffer, atCache.atAngles, 3);
	Entity_GetAbsVelocity(client, fBuffer);
	Array_Copy(fBuffer, atCache.atVelocity, 3);

	atCache.atFlags = ADDITIONAL_FIELD_TELEPORTED_ORIGIN | ADDITIONAL_FIELD_TELEPORTED_ANGLES | ADDITIONAL_FIELD_TELEPORTED_VELOCITY;

	FrameInfo frame;
	g_hRecording[client].GetArray(g_iRecordedTicks[client] - 1, frame, sizeof(FrameInfo));
	// There already is some Teleport call saved this frame :(
	if ((frame.additionalFields & atCache.atFlags) != 0)
	{
		// Purge it and replace it with this one as we might have more information.
		g_hRecordingAdditionalTeleport[client].SetArray(g_iCurrentAdditionalTeleportIndex[client] - 1, atCache, sizeof(AdditionalTeleport));
	}
	else
	{
		g_hRecordingAdditionalTeleport[client].PushArray(atCache, sizeof(AdditionalTeleport));
		g_iCurrentAdditionalTeleportIndex[client]++;
	}
	// Remember, we were teleported this frame!
	frame.additionalFields |= atCache.atFlags;

	int iWeapon = Client_GetActiveWeapon(client);
	if (iWeapon != INVALID_ENT_REFERENCE && frame.newWeapon == CSWeapon_NONE && IsValidEntity(iWeapon))
	{
		char sClassName[64];
		GetEntityClassname(iWeapon, sClassName, sizeof(sClassName));
		ReplaceString(sClassName, sizeof(sClassName), "weapon_", "", false);

		char sWeaponAlias[64];
		CS_GetTranslatedWeaponAlias(sClassName, sWeaponAlias, sizeof(sWeaponAlias));
		CSWeaponID weaponId = CS_AliasToWeaponID(sWeaponAlias);
		frame.newWeapon   = weaponId;
	}

	g_hRecording[client].SetArray(g_iRecordedTicks[client] - 1, frame, sizeof(FrameInfo));

	// Save the bookmark
	bmCache.BKM_frame                  = g_iRecordedTicks[client] - 1;
	bmCache.BKM_additionalTeleportTick = g_iCurrentAdditionalTeleportIndex[client] - 1;
	strcopy(bmCache.BKM_name, MAX_BOOKMARK_NAME_LENGTH, sBookmarkName);
	g_hRecordingBookmarks[client].PushArray(bmCache, sizeof(Bookmarks));

	// Inform other plugins, that there's been a bookmark saved.
	Call_StartForward(g_hfwdOnRecordingBookmarkSaved);
	Call_PushCell(client);
	Call_PushString(sBookmarkName);
	Call_Finish();
}

public int DeleteRecord(Handle plugin, int numParams)
{
	int iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen + 1];
	GetNativeString(1, sPath, iLen + 1);

	// Do we have this record loaded?
	FileHeader header;
	if (!g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader)))
	{
		if (!FileExists(sPath))
			return -1;

		// Try to load it to make sure it's a record file we're deleting here!
		BMError error = LoadRecordFromFile(sPath, DEFAULT_CATEGORY, header, true, false);
		if (error == BM_FileNotFound || error == BM_BadFile)
			return -1;
	}

	int iCount;
	if (header.FH_frames != null)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			// Stop the bots from mimicing this one
			if (g_hBotMimicsRecord[i] == header.FH_frames)
			{
				BotMimic_StopPlayerMimic(i);
				iCount++;
			}
		}

		// Discard the frames
		delete header.FH_frames;
	}

	if (header.FH_bookmarks != null)
	{
		delete header.FH_bookmarks;
	}

	char sCategory[64];
	g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory));

	g_hLoadedRecords.Remove(sPath);
	g_hLoadedRecordsCategory.Remove(sPath);
	g_hSortedRecordList.Erase(g_hSortedRecordList.FindString(sPath));
	ArrayList hAT;
	if (g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAT))
		delete hAT;
	g_hLoadedRecordsAdditionalTeleport.Remove(sPath);

	// Delete the file
	if (FileExists(sPath))
	{
		DeleteFile(sPath);
	}

	Call_StartForward(g_hfwdOnRecordDeleted);
	Call_PushString(header.FH_recordName);
	Call_PushString(sCategory);
	Call_PushString(sPath);
	Call_Finish();

	return iCount;
}

public int IsPlayerRecording(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}

	return g_hRecording[client] != null;
}

public int IsPlayerMimicing(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}

	return g_hBotMimicsRecord[client] != null;
}

public int GetRecordPlayerMimics(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}

	int iLen     = GetNativeCell(3);
	char[] sPath = new char[iLen];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, iLen);
	SetNativeString(2, sPath, iLen);
}

public int GoToBookmark(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}

	char sBookmarkName[MAX_BOOKMARK_NAME_LENGTH];
	GetNativeString(2, sBookmarkName, sizeof(sBookmarkName));

	// Get the file header
	char sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));

	FileHeader header;
	g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader));

	// Get the bookmark with this name
	Bookmarks bmCache;
	int iBookmarkIndex;
	bool bBookmarkFound;
	for (; iBookmarkIndex < header.FH_bookmarkCount; iBookmarkIndex++)
	{
		header.FH_bookmarks.GetArray(iBookmarkIndex, bmCache, sizeof(Bookmarks));
		if (StrEqual(bmCache.BKM_name, sBookmarkName, false))
		{
			bBookmarkFound = true;
			break;
		}
	}

	if (!bBookmarkFound)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "There is no bookmark named \"%s\" in this record.", sBookmarkName);
		return;
	}

	g_iBotMimicTick[client]                   = bmCache.BKM_frame;
	g_iCurrentAdditionalTeleportIndex[client] = bmCache.BKM_additionalTeleportTick;

	// Remember that we're now at this bookmark.
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = bmCache.BKM_frame;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = iBookmarkIndex;
}

public int StopPlayerMimic(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}

	char sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));

	g_hBotMimicsRecord[client]                     = null;
	g_iBotMimicTick[client]                        = 0;
	g_iCurrentAdditionalTeleportIndex[client]      = 0;
	g_iBotMimicRecordTickCount[client]             = 0;
	g_bValidTeleportCall[client]                   = false;
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;

	FileHeader header;
	g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader));

	SDKUnhook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);

	char sCategory[64];
	g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory));

	Call_StartForward(g_hfwdOnPlayerStopsMimicing);
	Call_PushCell(client);
	Call_PushString(header.FH_recordName);
	Call_PushString(sCategory);
	Call_PushString(sPath);
	Call_Finish();
}

public int PlayRecordFromFile(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return view_as<int>(BM_BadClient);
	}

	int iLen;
	GetNativeStringLength(2, iLen);
	char[] sPath = new char[iLen + 1];
	GetNativeString(2, sPath, iLen + 1);

	if (!FileExists(sPath))
		return view_as<int>(BM_FileNotFound);

	return view_as<int>(PlayRecord(client, sPath));
}

public int PlayRecordByName(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return view_as<int>(BM_BadClient);
	}

	int iLen;
	GetNativeStringLength(2, iLen);
	char[] sName = new char[iLen + 1];
	GetNativeString(2, sName, iLen + 1);

	char sPath[PLATFORM_MAX_PATH];
	int  iSize = g_hSortedRecordList.Length;
	FileHeader header;
	int iRecentTimeStamp;
	char sRecentPath[PLATFORM_MAX_PATH];
	for (int i = 0; i < iSize; i++)
	{
		g_hSortedRecordList.GetString(i, sPath, sizeof(sPath));
		g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader));
		if (StrEqual(sName, header.FH_recordName))
		{
			if (iRecentTimeStamp == 0 || iRecentTimeStamp < header.FH_recordEndTime)
			{
				iRecentTimeStamp = header.FH_recordEndTime;
				strcopy(sRecentPath, sizeof(sRecentPath), sPath);
			}
		}
	}

	if (!iRecentTimeStamp || !FileExists(sRecentPath))
		return view_as<int>(BM_FileNotFound);

	return view_as<int>(PlayRecord(client, sRecentPath));
}

public int ResetPlayback(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}

	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}

	g_iBotMimicTick[client]                        = 0;
	g_iCurrentAdditionalTeleportIndex[client]      = 0;
	g_bValidTeleportCall[client]                   = false;
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	UpdateNextBookmarkTick(client);
}

public int GetFileHeaders(Handle plugin, int numParams)
{
	int iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen + 1];
	GetNativeString(1, sPath, iLen + 1);

	if (!FileExists(sPath))
	{
		return view_as<int>(BM_FileNotFound);
	}

	FileHeader header;
	if (!g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader)))
	{
		char sCategory[64];
		if (!g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		BMError error = LoadRecordFromFile(sPath, sCategory, header, true, false);
		if (error != BM_NoError)
			return view_as<int>(error);
	}

	BMFileHeader bmHeader;
	bmHeader.BMFH_binaryFormatVersion = header.FH_binaryFormatVersion;
	bmHeader.BMFH_recordEndTime       = header.FH_recordEndTime;
	strcopy(bmHeader.BMFH_recordName, MAX_RECORD_NAME_LENGTH, header.FH_recordName);
	bmHeader.BMFH_tickCount = header.FH_tickCount;
	Array_Copy(header.FH_initialPosition, bmHeader.BMFH_initialPosition, 3);
	Array_Copy(header.FH_initialAngles, bmHeader.BMFH_initialAngles, 3);
	bmHeader.BMFH_bookmarkCount = header.FH_bookmarkCount;

	int iSize = sizeof(BMFileHeader);
	if (numParams > 2)
		iSize = GetNativeCell(3);
	if (iSize > sizeof(BMFileHeader))
		iSize = sizeof(BMFileHeader);

	SetNativeArray(2, bmHeader, iSize);
	return view_as<int>(BM_NoError);
}

public int ChangeRecordName(Handle plugin, int numParams)
{
	int iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen + 1];
	GetNativeString(1, sPath, iLen + 1);

	if (!FileExists(sPath))
	{
		return view_as<int>(BM_FileNotFound);
	}

	char sCategory[64];
	if (!g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory)))
		strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);

	FileHeader header;
	if (!g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader)))
	{
		BMError error = LoadRecordFromFile(sPath, sCategory, header, false, false);
		if (error != BM_NoError)
			return view_as<int>(error);
	}

	// Load the whole record first or we'd lose the frames!
	if (header.FH_frames == null)
		LoadRecordFromFile(sPath, sCategory, header, false, true);

	GetNativeStringLength(2, iLen);
	char[] sName = new char[iLen + 1];
	GetNativeString(2, sName, iLen + 1);

	strcopy(header.FH_recordName, MAX_RECORD_NAME_LENGTH, sName);
	g_hLoadedRecords.SetArray(sPath, header, sizeof(FileHeader));

	WriteRecordToDisk(sPath, header);

	return view_as<int>(BM_NoError);
}

public int GetLoadedRecordCategoryList(Handle plugin, int numParams)
{
	return view_as<int>(g_hSortedCategoryList);
}

public int GetLoadedRecordList(Handle plugin, int numParams)
{
	return view_as<int>(g_hSortedRecordList);
}

public int GetFileCategory(Handle plugin, int numParams)
{
	int iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen + 1];
	GetNativeString(1, sPath, iLen + 1);

	iLen             = GetNativeCell(3);
	char[] sCategory = new char[iLen];
	bool bFound      = g_hLoadedRecordsCategory.GetString(sPath, sCategory, iLen);

	SetNativeString(2, sCategory, iLen);
	return view_as<int>(bFound);
}

public int GetRecordBookmarks(Handle plugin, int numParams)
{
	int iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen + 1];
	GetNativeString(1, sPath, iLen + 1);

	if (!FileExists(sPath))
	{
		return view_as<int>(BM_FileNotFound);
	}

	FileHeader header;
	if (!g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader)))
	{
		char sCategory[64];
		if (!g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		BMError error = LoadRecordFromFile(sPath, sCategory, header, true, false);
		if (error != BM_NoError)
			return view_as<int>(error);
	}

	ArrayList hBookmarks = new ArrayList(ByteCountToCells(MAX_BOOKMARK_NAME_LENGTH));
	Bookmarks bmCache;
	for (int i = 0; i < header.FH_bookmarkCount; i++)
	{
		header.FH_bookmarks.GetArray(i, bmCache, sizeof(Bookmarks));
		hBookmarks.PushString(bmCache.BKM_name);
	}

	Handle hClone = CloneHandle(hBookmarks, plugin);
	delete hBookmarks;
	SetNativeCellRef(2, hClone);
	return view_as<int>(BM_NoError);
}

/**
 * Helper functions
 */

void ParseRecordsInDirectory(const char[] sPath, const char[] sCategory, bool subdir)
{
	char sMapFilePath[PLATFORM_MAX_PATH];
	// We already are in the map folder? Don't add it again!
	if (subdir)
	{
		strcopy(sMapFilePath, sizeof(sMapFilePath), sPath);
	}
	// We're in a category. add the mapname to load the correct records for the current map
	else
	{
		char sMapName[64];
		GetCurrentMap(sMapName, sizeof(sMapName));
		Format(sMapFilePath, sizeof(sMapFilePath), "%s/%s", sPath, sMapName);
	}

	DirectoryListing hDir = OpenDirectory(sMapFilePath);
	if (hDir == null)
		return;

	char     sFile[64], sFilePath[PLATFORM_MAX_PATH];
	FileType fileType;
	FileHeader header;
	while (hDir.GetNext(sFile, sizeof(sFile), fileType))
	{
		switch (fileType)
		{
			// This is a record for this map.
			case FileType_File:
			{
				Format(sFilePath, sizeof(sFilePath), "%s/%s", sMapFilePath, sFile);
				LoadRecordFromFile(sFilePath, sCategory, header, true, false);
			}
			// There's a subdir containing more records.
			case FileType_Directory:
			{
				// INFINITE RECURSION ANYONE?
				if (StrEqual(sFile, ".") || StrEqual(sFile, ".."))
					continue;

				Format(sFilePath, sizeof(sFilePath), "%s/%s", sMapFilePath, sFile);
				ParseRecordsInDirectory(sFilePath, sCategory, true);
			}
		}
	}

	delete hDir;
}

void WriteRecordToDisk(const char[] sPath, FileHeader header)
{
	File hFile = OpenFile(sPath, "wb");
	if (hFile == null)
	{
		LogError("Can't open the record file for writing! (%s)", sPath);
		return;
	}

	hFile.WriteInt32(BM_MAGIC);
	hFile.WriteInt8(header.FH_binaryFormatVersion);
	hFile.WriteInt32(header.FH_recordEndTime);
	hFile.WriteInt8(strlen(header.FH_recordName));
	hFile.WriteString(header.FH_recordName, false);

	hFile.Write(view_as<int>(header.FH_initialPosition), 3, 4);
	hFile.Write(view_as<int>(header.FH_initialAngles), 2, 4);

	ArrayList hAdditionalTeleport;
	int       iATIndex;
	g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAdditionalTeleport);

	int iTickCount = header.FH_tickCount;
	hFile.WriteInt32(iTickCount);

	int iBookmarkCount = header.FH_bookmarkCount;
	hFile.WriteInt32(iBookmarkCount);

	// Write all bookmarks
	ArrayList hBookmarks = header.FH_bookmarks;

	Bookmarks bmCache;
	for (int i = 0; i < iBookmarkCount; i++)
	{
		hBookmarks.GetArray(i, bmCache, sizeof(Bookmarks));

		hFile.WriteInt32(bmCache.BKM_frame);
		hFile.WriteInt32(bmCache.BKM_additionalTeleportTick);
		hFile.WriteString(bmCache.BKM_name, true);
	}

	any aFrameData[sizeof(FrameInfo)];
	for (int i = 0; i < iTickCount; i++)
	{
		header.FH_frames.GetArray(i, aFrameData, sizeof(FrameInfo));
		hFile.Write(aFrameData, sizeof(FrameInfo), 4);

		// Handle the optional Teleport call
		if (hAdditionalTeleport != null && aFrameData[FrameInfo::additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN | ADDITIONAL_FIELD_TELEPORTED_ANGLES | ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			any aATData[sizeof(AdditionalTeleport)];
			hAdditionalTeleport.GetArray(iATIndex, aATData, sizeof(AdditionalTeleport));
			if (aFrameData[FrameInfo::additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
				hFile.Write(aATData[AdditionalTeleport::atOrigin], 3, 4);
			if (aFrameData[FrameInfo::additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				hFile.Write(aATData[AdditionalTeleport::atAngles], 3, 4);
			if (aFrameData[FrameInfo::additionalFields] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
				hFile.Write(aATData[AdditionalTeleport::atVelocity], 3, 4);
			iATIndex++;
		}
	}

	delete hFile;
}

BMError LoadRecordFromFile(const char[] path, const char[] sCategory, FileHeader header, bool onlyHeader, bool forceReload)
{
	if (!FileExists(path))
		return BM_FileNotFound;

	// Make sure the handle references are null in the input structure.
	header.FH_frames    = null;
	header.FH_bookmarks = null;

	// Already loaded that file?
	bool bAlreadyLoaded = false;
	if (g_hLoadedRecords.GetArray(path, header, sizeof(FileHeader)))
	{
		// Header already loaded.
		if (onlyHeader && !forceReload)
			return BM_NoError;

		bAlreadyLoaded = true;
	}

	File hFile = OpenFile(path, "rb");
	if (hFile == null)
		return BM_FileNotFound;

	int iMagic;
	hFile.ReadInt32(iMagic);
	if (iMagic != BM_MAGIC)
	{
		delete hFile;
		return BM_BadFile;
	}

	int iBinaryFormatVersion;
	hFile.ReadUint8(iBinaryFormatVersion);
	header.FH_binaryFormatVersion = iBinaryFormatVersion;

	if (iBinaryFormatVersion > BINARY_FORMAT_VERSION)
	{
		delete hFile;
		return BM_NewerBinaryVersion;
	}

	int iRecordTime, iNameLength;
	hFile.ReadInt32(iRecordTime);
	hFile.ReadUint8(iNameLength);
	char[] sRecordName = new char[iNameLength + 1];
	hFile.ReadString(sRecordName, iNameLength + 1, iNameLength);
	sRecordName[iNameLength] = '\0';

	hFile.Read(view_as<int>(header.FH_initialPosition), 3, 4);
	hFile.Read(view_as<int>(header.FH_initialAngles), 2, 4);

	int iTickCount;
	hFile.ReadInt32(iTickCount);

	int iBookmarkCount;
	if (iBinaryFormatVersion >= 0x02)
	{
		hFile.ReadInt32(iBookmarkCount);
	}

	header.FH_bookmarkCount = iBookmarkCount;

	header.FH_recordEndTime = iRecordTime;
	strcopy(header.FH_recordName, MAX_RECORD_NAME_LENGTH, sRecordName);
	header.FH_tickCount = iTickCount;

	delete header.FH_frames;
	delete header.FH_bookmarks;

	ArrayList hAT;
	if (g_hLoadedRecordsAdditionalTeleport.GetValue(path, hAT))
	{
		delete hAT;
		g_hLoadedRecordsAdditionalTeleport.Remove(path);
	}

	// PrintToServer("Record %s:", sRecordName);
	// PrintToServer("File %s:", path);
	// PrintToServer("EndTime: %d, BinaryVersion: 0x%x, ticks: %d, initialPosition: %f,%f,%f, initialAngles: %f,%f,%f", iRecordTime, iBinaryFormatVersion, iTickCount, headerInfo[FH_initialPosition][0], headerInfo[FH_initialPosition][1], headerInfo[FH_initialPosition][2], headerInfo[FH_initialAngles][0], headerInfo[FH_initialAngles][1], headerInfo[FH_initialAngles][2]);

	if (iBookmarkCount > 0)
	{
		// Read in all bookmarks
		ArrayList hBookmarks = new ArrayList(sizeof(Bookmarks));

		Bookmarks bmCache;
		for (int i = 0; i < iBookmarkCount; i++)
		{
			hFile.ReadInt32(bmCache.BKM_frame);
			hFile.ReadInt32(bmCache.BKM_additionalTeleportTick);
			hFile.ReadString(bmCache.BKM_name, MAX_BOOKMARK_NAME_LENGTH);
			hBookmarks.PushArray(bmCache, sizeof(Bookmarks));
		}

		header.FH_bookmarks = hBookmarks;
	}

	g_hLoadedRecords.SetArray(path, header, sizeof(FileHeader));
	g_hLoadedRecordsCategory.SetString(path, sCategory);

	if (!bAlreadyLoaded)
		g_hSortedRecordList.PushString(path);

	if (g_hSortedCategoryList.FindString(sCategory) == -1)
		g_hSortedCategoryList.PushString(sCategory);

	// Sort it by record end time
	SortRecordList();

	if (onlyHeader)
	{
		delete hFile;
		return BM_NoError;
	}

	// Read in all the saved frames
	ArrayList hRecordFrames       = new ArrayList(sizeof(FrameInfo));
	ArrayList hAdditionalTeleport = new ArrayList(sizeof(AdditionalTeleport));

	any aFrameData[sizeof(FrameInfo)];
	for (int i = 0; i < iTickCount; i++)
	{
		hFile.Read(aFrameData, sizeof(FrameInfo), 4);
		hRecordFrames.PushArray(aFrameData, sizeof(FrameInfo));

		if (aFrameData[FrameInfo::additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN | ADDITIONAL_FIELD_TELEPORTED_ANGLES | ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			any aATData[sizeof(AdditionalTeleport)];
			if (aFrameData[FrameInfo::additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
				hFile.Read(aATData[AdditionalTeleport::atOrigin], 3, 4);
			if (aFrameData[FrameInfo::additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				hFile.Read(aATData[AdditionalTeleport::atAngles], 3, 4);
			if (aFrameData[FrameInfo::additionalFields] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
				hFile.Read(aATData[AdditionalTeleport::atVelocity], 3, 4);
			aATData[AdditionalTeleport::atFlags] = aFrameData[FrameInfo::additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN | ADDITIONAL_FIELD_TELEPORTED_ANGLES | ADDITIONAL_FIELD_TELEPORTED_VELOCITY);
			hAdditionalTeleport.PushArray(aATData, sizeof(AdditionalTeleport));
		}
	}

	header.FH_frames = hRecordFrames;

	g_hLoadedRecords.SetArray(path, header, sizeof(FileHeader));
	if (hAdditionalTeleport.Length > 0)
		g_hLoadedRecordsAdditionalTeleport.SetValue(path, hAdditionalTeleport);
	else
		delete hAdditionalTeleport;

	delete hFile;

	return BM_NoError;
}

void SortRecordList()
{
	SortADTArrayCustom(g_hSortedRecordList, SortFuncADT_ByEndTime);
	SortADTArray(g_hSortedCategoryList, Sort_Descending, Sort_String);
}

public int SortFuncADT_ByEndTime(int index1, int index2, Handle arrayHndl, Handle hndl)
{
	char      path1[PLATFORM_MAX_PATH], path2[PLATFORM_MAX_PATH];
	ArrayList array = view_as<ArrayList>(arrayHndl);
	array.GetString(index1, path1, sizeof(path1));
	array.GetString(index2, path2, sizeof(path2));

	FileHeader header1, header2;
	g_hLoadedRecords.GetArray(path1, header1, sizeof(FileHeader));
	g_hLoadedRecords.GetArray(path2, header2, sizeof(FileHeader));

	return header1.FH_recordEndTime - header2.FH_recordEndTime;
}

BMError PlayRecord(int client, const char[] path)
{
	// He's currently recording. Don't start to play some record on him at the same time.
	if (g_hRecording[client] != null)
	{
		return BM_BadClient;
	}

	FileHeader header;
	g_hLoadedRecords.GetArray(path, header, sizeof(FileHeader));

	// That record isn't fully loaded yet. Do that now.
	if (header.FH_frames == null)
	{
		char sCategory[64];
		if (!g_hLoadedRecordsCategory.GetString(path, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		BMError error = LoadRecordFromFile(path, sCategory, header, false, true);
		if (error != BM_NoError)
			return error;
	}

	g_hBotMimicsRecord[client]                = header.FH_frames;
	g_iBotMimicTick[client]                   = 0;
	g_iBotMimicRecordTickCount[client]        = header.FH_tickCount;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_iBotActiveWeapon[client]                = INVALID_ENT_REFERENCE;
	g_bBotSwitchedWeapon[client]              = false;

	// Cache at which tick we should fire the first OnPlayerMimicBookmark forward.
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	UpdateNextBookmarkTick(client);

	Array_Copy(header.FH_initialPosition, g_fInitialPosition[client], 3);
	Array_Copy(header.FH_initialAngles, g_fInitialAngles[client], 3);

	SDKHook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);

	// Respawn him to get him moving!
	if (IsClientInGame(client) && !IsPlayerAlive(client) && GetClientTeam(client) >= CS_TEAM_T)
		CS_RespawnPlayer(client);

	char sCategory[64];
	g_hLoadedRecordsCategory.GetString(path, sCategory, sizeof(sCategory));

	Action result;
	Call_StartForward(g_hfwdOnPlayerStartsMimicing);
	Call_PushCell(client);
	Call_PushString(header.FH_recordName);
	Call_PushString(sCategory);
	Call_PushString(path);
	Call_Finish(result);

	// Someone doesn't want this guy to play that record.
	if (result >= Plugin_Handled)
	{
		g_hBotMimicsRecord[client]                     = null;
		g_iBotMimicRecordTickCount[client]             = 0;
		g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
		g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	}

	return BM_NoError;
}

// Find the next frame in which a bookmark was saved, so the OnPlayerMimicBookmark forward can be called.
void UpdateNextBookmarkTick(int client)
{
	// Not mimicing anything.
	if (g_hBotMimicsRecord[client] == null)
		return;

	char sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));

	FileHeader header;
	g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader));

	if (header.FH_bookmarks == null)
		return;

	int iSize = header.FH_bookmarks.Length;
	if (iSize == 0)
		return;

	int iCurrentIndex = g_iBotMimicNextBookmarkTick[client][BWM_index];
	// We just reached some bookmark regularly and want to proceed to wait for the next one sequentially.
	// If there is no further bookmarks, restart from the first one.
	iCurrentIndex++;
	if (iCurrentIndex >= iSize)
		iCurrentIndex = 0;

	Bookmarks bmCache;
	header.FH_bookmarks.GetArray(iCurrentIndex, bmCache, sizeof(Bookmarks));
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = bmCache.BKM_frame;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = iCurrentIndex;
}

stock bool CheckCreateDirectory(const char[] sPath, int mode)
{
	if (!DirExists(sPath))
	{
		CreateDirectory(sPath, mode);
		if (!DirExists(sPath))
		{
			LogError("Can't create a new directory. Please create one manually! (%s)", sPath);
			return false;
		}
	}
	return true;
}

stock void GetFileFromFrameHandle(ArrayList frames, char[] path, int maxlen)
{
	int  iSize = g_hSortedRecordList.Length;
	char sPath[PLATFORM_MAX_PATH];
	FileHeader header;
	for (int i = 0; i < iSize; i++)
	{
		g_hSortedRecordList.GetString(i, sPath, sizeof(sPath));
		g_hLoadedRecords.GetArray(sPath, header, sizeof(FileHeader));
		if (header.FH_frames != frames)
			continue;

		strcopy(path, maxlen, sPath);
		break;
	}
}
