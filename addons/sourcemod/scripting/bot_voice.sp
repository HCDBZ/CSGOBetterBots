#include <sourcemod>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo = 
{
    name = "Bot Voice",
    author = "Tasty cup",
    description = "Makes bots play voice audio with multi-track support",
    version = "1.0.2",
    url = ""
};

// 单个语音轨道数据结构
enum struct VoiceTrack
{
    char filePath[PLATFORM_MAX_PATH];
    Handle stopTimer;
    float startTime;
    float duration;
    int trackId;  
}

ArrayList g_aVoiceTracks[MAXPLAYERS+1];  // 每个客户端的多轨道列表
int g_iNextTrackId[MAXPLAYERS+1];        // 轨道ID计数器

// 前向声明
Handle g_hOnBotStartSpeaking = null;
Handle g_hOnBotStopSpeaking = null;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("BotVoice_StartSpeaking", Native_StartSpeaking);
    CreateNative("BotVoice_StopSpeaking", Native_StopSpeaking);
    CreateNative("BotVoice_StopAllSpeaking", Native_StopAllSpeaking);
    CreateNative("BotVoice_IsSpeaking", Native_IsSpeaking);
    CreateNative("BotVoice_GetActiveTrackCount", Native_GetActiveTrackCount);
    
    g_hOnBotStartSpeaking = CreateGlobalForward("BotVoice_OnBotStartSpeaking", ET_Ignore, Param_Cell, Param_String);
    g_hOnBotStopSpeaking = CreateGlobalForward("BotVoice_OnBotStopSpeaking", ET_Ignore, Param_Cell, Param_String);
    
    RegPluginLibrary("bot_voice");
    return APLRes_Success;
}

public void OnPluginStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_aVoiceTracks[i] = new ArrayList(sizeof(VoiceTrack));
        g_iNextTrackId[i] = 1;
        
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
    
    PrintToServer("[Bot Voice] Plugin loaded - Multi-track mixing support enabled");
}

public void OnClientPutInServer(int client)
{
    if (g_aVoiceTracks[client] == null)
    {
        g_aVoiceTracks[client] = new ArrayList(sizeof(VoiceTrack));
    }
    else
    {
        ClearAllVoiceTracks(client);
    }
    
    g_iNextTrackId[client] = 1;
}

public void OnClientDisconnect(int client)
{
    ClearAllVoiceTracks(client);
}

/**
 * 开始播放语音(支持多轨道混音)
 * 
 * @param client        客户端索引
 * @param voiceFile     语音文件路径
 * @param duration      持续时间
 * @return              轨道ID,失败返回-1
 */
int StartSpeaking(int client, const char[] voiceFile, float duration)
{
    if (!IsValidClient(client))
        return -1;
    
    // 创建新轨道
    VoiceTrack track;
    strcopy(track.filePath, PLATFORM_MAX_PATH, voiceFile);
    track.startTime = GetGameTime();
    track.duration = duration;
    track.trackId = g_iNextTrackId[client]++;
    
    // 立即播放音频
    PlayVoiceToTeam(client, voiceFile);
    
    // 创建自动停止定时器
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(track.trackId);
    pack.WriteString(voiceFile);
    
    track.stopTimer = CreateTimer(duration, Timer_AutoStopTrack, pack, TIMER_FLAG_NO_MAPCHANGE);
    
    // 添加到轨道列表
    g_aVoiceTracks[client].PushArray(track);
    
    // 触发前向回调
    Call_StartForward(g_hOnBotStartSpeaking);
    Call_PushCell(client);
    Call_PushString(voiceFile);
    Call_Finish();
    
    return track.trackId;
}

// 停止指定客户端的最早播放的语音
void StopSpeaking(int client)
{
    if (!IsValidClient(client) || g_aVoiceTracks[client].Length == 0)
        return;
    
    // 停止第一个轨道
    VoiceTrack track;
    g_aVoiceTracks[client].GetArray(0, track);
    
    StopVoiceTrack(client, track);
    g_aVoiceTracks[client].Erase(0);
}

// 停止客户端的所有语音
void StopAllSpeaking(int client)
{
    if (!IsValidClient(client))
        return;
    
    ClearAllVoiceTracks(client);
}

// 停止并清理单个语音轨道
void StopVoiceTrack(int client, VoiceTrack track)
{
    // 停止音频播放
    StopVoiceSound(client, track.filePath);
    
    // 取消定时器
    if (track.stopTimer != null)
    {
        KillTimer(track.stopTimer);
    }
    
    // 触发前向回调
    Call_StartForward(g_hOnBotStopSpeaking);
    Call_PushCell(client);
    Call_PushString(track.filePath);
    Call_Finish();
}

// 清理客户端的所有语音轨道
void ClearAllVoiceTracks(int client)
{
    if (!IsValidClient(client))
        return;
    
    VoiceTrack track;
    for (int i = 0; i < g_aVoiceTracks[client].Length; i++)
    {
        g_aVoiceTracks[client].GetArray(i, track);
        StopVoiceTrack(client, track);
    }
    
    g_aVoiceTracks[client].Clear();
}

// 播放语音给同队玩家
void PlayVoiceToTeam(int client, const char[] voiceFile)
{
    int speakerTeam = GetClientTeam(client);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        if (GetClientTeam(i) != speakerTeam)
            continue;
        
        EmitSoundToClient(i, voiceFile, 
            SOUND_FROM_LOCAL_PLAYER,  
            SNDCHAN_AUTO,             
            SNDLEVEL_NONE,         
            SND_NOFLAGS,           
            1.0,     
            SNDPITCH_NORMAL,        
            -1,                     
            NULL_VECTOR,           
            NULL_VECTOR,              
            true,                    
            0.0);
    }
}

// 停止语音播放
 
void StopVoiceSound(int client, const char[] voiceFile)
{
    int speakerTeam = GetClientTeam(client);
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        
        if (GetClientTeam(i) != speakerTeam)
            continue;

        StopSound(i, SNDCHAN_AUTO, voiceFile);
    }
}

//自动停止轨道定时器
public Action Timer_AutoStopTrack(Handle timer, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    int trackId = pack.ReadCell();
    char voiceFile[PLATFORM_MAX_PATH];
    pack.ReadString(voiceFile, sizeof(voiceFile));
    delete pack;
    
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsValidClient(client))
        return Plugin_Stop;
    
    // 查找并删除对应轨道
    VoiceTrack track;
    for (int i = 0; i < g_aVoiceTracks[client].Length; i++)
    {
        g_aVoiceTracks[client].GetArray(i, track);
        
        if (track.trackId == trackId)
        {
            StopVoiceSound(client, voiceFile);
            
            // 触发回调
            Call_StartForward(g_hOnBotStopSpeaking);
            Call_PushCell(client);
            Call_PushString(voiceFile);
            Call_Finish();
            
            g_aVoiceTracks[client].Erase(i);
            break;
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
    
    return StartSpeaking(client, voiceFile, duration);
}

public int Native_StopSpeaking(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    StopSpeaking(client);
    return 0;
}

public int Native_StopAllSpeaking(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    StopAllSpeaking(client);
    return 0;
}

public int Native_IsSpeaking(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return (g_aVoiceTracks[client].Length > 0);
}

public int Native_GetActiveTrackCount(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return g_aVoiceTracks[client].Length;
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && 
            IsClientConnected(client) && 
            IsClientInGame(client));
}