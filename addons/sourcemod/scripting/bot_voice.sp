#include <sourcemod>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo = 
{
    name = "Bot Voice",
    author = "Tasty cup",
    description = "Makes bots play voice audio",
    version = "1.0.0",
    url = ""
};

// 全局变量
bool g_bIsSpeaking[MAXPLAYERS+1];
Handle g_hVoiceTimer[MAXPLAYERS+1];
char g_szCurrentVoiceFile[MAXPLAYERS+1][PLATFORM_MAX_PATH];

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
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
    
    PrintToServer("[Bot Voice] Plugin loaded - Audio only mode");
}

public void OnClientPutInServer(int client)
{
    g_bIsSpeaking[client] = false;
    g_hVoiceTimer[client] = null;
    g_szCurrentVoiceFile[client][0] = '\0';
}

public void OnClientDisconnect(int client)
{
    StopSpeaking(client);
}

void StartSpeaking(int client, const char[] voiceFile, float duration)
{
    if (!IsValidClient(client))
        return;
    
    if (g_bIsSpeaking[client])
    {
        StopSpeaking(client);
    }
    
    g_bIsSpeaking[client] = true;
    strcopy(g_szCurrentVoiceFile[client], PLATFORM_MAX_PATH, voiceFile);
    
    // 播放语音
    PlayVoiceToAll(client, voiceFile);
    
    // 自动停止定时器
    if (g_hVoiceTimer[client] != null)
    {
        KillTimer(g_hVoiceTimer[client]);
    }
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    g_hVoiceTimer[client] = CreateTimer(duration, Timer_AutoStopSpeaking, pack);
    
    Call_StartForward(g_hOnBotStartSpeaking);
    Call_PushCell(client);
    Call_Finish();
}

void StopSpeaking(int client)
{
    if (!IsValidClient(client))
        return;
    
    if (!g_bIsSpeaking[client])
        return;
    
    g_bIsSpeaking[client] = false;
    
    // 停止语音
    if (g_szCurrentVoiceFile[client][0] != '\0')
    {
        StopVoiceSound(g_szCurrentVoiceFile[client]);
        g_szCurrentVoiceFile[client][0] = '\0';
    }
    
    // 清理定时器
    if (g_hVoiceTimer[client] != null)
    {
        KillTimer(g_hVoiceTimer[client]);
        g_hVoiceTimer[client] = null;
    }
    
    Call_StartForward(g_hOnBotStopSpeaking);
    Call_PushCell(client);
    Call_Finish();
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
    delete pack;
    
    int client = GetClientOfUserId(userId);
    if (client > 0)
    {
        g_hVoiceTimer[client] = null;
        StopSpeaking(client);
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
    return g_bIsSpeaking[client];
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && 
            IsClientConnected(client) && 
            IsClientInGame(client));
}