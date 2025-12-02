#include <sourcemod>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo = 
{
    name = "Bot Voice",
    author = "Tasty cup",
    description = "Makes bots play voice audio",
    version = "1.0.1",
    url = ""
};

// 语音任务数据结构
enum struct VoiceTask
{
    char filePath[PLATFORM_MAX_PATH];
    Handle timer;
}

ArrayList g_aVoiceTasks[MAXPLAYERS+1];

// 前向声明
Handle g_hOnBotStartSpeaking = null;
Handle g_hOnBotStopSpeaking = null;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("BotVoice_StartSpeaking", Native_StartSpeaking);
    CreateNative("BotVoice_StopSpeaking", Native_StopSpeaking);
    CreateNative("BotVoice_IsSpeaking", Native_IsSpeaking);
    
    g_hOnBotStartSpeaking = CreateGlobalForward("BotVoice_OnBotStartSpeaking", ET_Ignore, Param_Cell);
    g_hOnBotStopSpeaking = CreateGlobalForward("BotVoice_OnBotStopSpeaking", ET_Ignore, Param_Cell);
    
    RegPluginLibrary("bot_voice");
    return APLRes_Success;
}

public void OnPluginStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_aVoiceTasks[i] = new ArrayList(sizeof(VoiceTask));
        
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
    
    PrintToServer("[Bot Voice] Plugin loaded - Multi-voice support");
}

public void OnClientPutInServer(int client)
{
    if (g_aVoiceTasks[client] == null)
        g_aVoiceTasks[client] = new ArrayList(sizeof(VoiceTask));
    else
        g_aVoiceTasks[client].Clear();
}

public void OnClientDisconnect(int client)
{
    ClearAllVoiceTasks(client);
}

void StartSpeaking(int client, const char[] voiceFile, float duration)
{
    if (!IsValidClient(client))
        return;

    VoiceTask task;
    strcopy(task.filePath, PLATFORM_MAX_PATH, voiceFile);
    
    PlayVoiceToAll(client, voiceFile);
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(voiceFile);
    
    task.timer = CreateTimer(duration, Timer_AutoStopSpeaking, pack);
    g_aVoiceTasks[client].PushArray(task);
    
    Call_StartForward(g_hOnBotStartSpeaking);
    Call_PushCell(client);
    Call_Finish();
}

void StopSpeaking(int client)
{
    if (!IsValidClient(client))
        return;
    
    if (g_aVoiceTasks[client].Length == 0)
        return;
    
    VoiceTask task;
    g_aVoiceTasks[client].GetArray(0, task);
    
    StopVoiceSound(task.filePath);
    
    if (task.timer != null)
    {
        KillTimer(task.timer);
    }
    
    g_aVoiceTasks[client].Erase(0);
    
    Call_StartForward(g_hOnBotStopSpeaking);
    Call_PushCell(client);
    Call_Finish();
}

void ClearAllVoiceTasks(int client)
{
    if (!IsValidClient(client))
        return;
    
    VoiceTask task;
    for (int i = 0; i < g_aVoiceTasks[client].Length; i++)
    {
        g_aVoiceTasks[client].GetArray(i, task);
        
        StopVoiceSound(task.filePath);
        
        if (task.timer != null)
        {
            KillTimer(task.timer);
        }
    }
    
    g_aVoiceTasks[client].Clear();
}

void PlayVoiceToAll(int client, const char[] voiceFile)
{
    int speakerTeam = GetClientTeam(client);
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        
        if (GetClientTeam(i) != speakerTeam)
            continue;
        
        EmitSoundToClient(i, voiceFile, client, SNDCHAN_VOICE, 
            SNDLEVEL_NONE, SND_NOFLAGS, 1.0, SNDPITCH_NORMAL);
    }
}

void StopVoiceSound(const char[] voiceFile)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        
        StopSound(i, SNDCHAN_VOICE, voiceFile);
    }
}

public Action Timer_AutoStopSpeaking(Handle timer, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    char voiceFile[PLATFORM_MAX_PATH];
    pack.ReadString(voiceFile, sizeof(voiceFile));
    delete pack;
    
    int client = GetClientOfUserId(userId);
    if (client > 0 && IsValidClient(client))
    {
        StopVoiceSound(voiceFile);
        
        VoiceTask task;
        for (int i = 0; i < g_aVoiceTasks[client].Length; i++)
        {
            g_aVoiceTasks[client].GetArray(i, task);
            
            if (StrEqual(task.filePath, voiceFile))
            {
                g_aVoiceTasks[client].Erase(i);
                break;
            }
        }
    }
    
    return Plugin_Stop;
}

public int Native_StartSpeaking(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    
    char voiceFile[PLATFORM_MAX_PATH];
    GetNativeString(2, voiceFile, sizeof(voiceFile));
    
    float duration = GetNativeCell(3);
    
    StartSpeaking(client, voiceFile, duration);
    return 0;
}

public int Native_StopSpeaking(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    StopSpeaking(client);
    return 0;
}

public int Native_IsSpeaking(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return g_aVoiceTasks[client].Length > 0;
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && 
            IsClientConnected(client) && 
            IsClientInGame(client));
}