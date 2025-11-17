#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "4.3"
#define MAX_PAUSE_TIME 360
#define DEFAULT_PAUSE_TIME 30
#define MAX_TEAM_PAUSES 4

bool g_bGamePaused = false;
Handle g_hPauseTimer = null;

int g_iTeamPausesLeft[4]; // 0=未分配, 2=T, 3=CT

// 存储原生函数调用
Handle g_hForward_OnBotPause = null;

public Plugin myinfo = {
    name = "CSGO Simple Pause System",
    author = "Tasty cup",
    description = "简单的暂停系统，每队4次暂停机会",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    // 创建原生函数供其他插件调用
    CreateNative("BotPause_ExecutePause", Native_ExecutePause);
    CreateNative("BotPause_GetTeamPausesLeft", Native_GetTeamPausesLeft);
    
    RegPluginLibrary("bot_pause");
    return APLRes_Success;
}

public void OnPluginStart() {
    // 加载翻译文件
    LoadTranslations("bot_pause.phrases");
    
    RegConsoleCmd("sm_p", Command_Pause, "暂停游戏");
    RegConsoleCmd("sm_pause", Command_Pause, "暂停游戏");
    
    AddCommandListener(ChatListener, "say");
    AddCommandListener(ChatListener, "say_team");
    
    HookEvent("round_start", Event_RoundStart); 
    HookEvent("round_end", Event_RoundEnd);
    
    // 初始化暂停次数
    g_iTeamPausesLeft[2] = MAX_TEAM_PAUSES; // T队
    g_iTeamPausesLeft[3] = MAX_TEAM_PAUSES; // CT队
    
    // 创建Forward
    g_hForward_OnBotPause = CreateGlobalForward("BotPause_OnPauseExecuted", ET_Ignore, Param_Cell, Param_Cell);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // 当前回合为0时重置暂停次数
    int iCurrentRound = GameRules_GetProp("m_totalRoundsPlayed");
    if (iCurrentRound == 0) {
        g_iTeamPausesLeft[2] = MAX_TEAM_PAUSES;
        g_iTeamPausesLeft[3] = MAX_TEAM_PAUSES;
    }
}

public Action ChatListener(int client, const char[] command, int argc) {
    if (!client || !IsClientInGame(client))
        return Plugin_Continue;
    
    char text[192];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);
    
    if (StrEqual(text, ".p", false)) {
        Command_Pause(client, 0);
        return Plugin_Continue;
    }
    else if (strncmp(text, ".p ", 3, false) == 0) {
        char args[32];
        strcopy(args, sizeof(args), text[3]);
        TrimString(args);
        FakeClientCommand(client, "sm_p %s", args);
        return Plugin_Continue;
    }
    
    return Plugin_Continue;
}

public Action Command_Pause(int client, int args) {
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;
    
    if (g_bGamePaused) {
        char message[128];
        Format(message, sizeof(message), "%T", "Already_Paused", client);
        PrintToChat(client, " [\x04CSGO\x01] %s", message);
        return Plugin_Handled;
    }
    
    int team = GetClientTeam(client);
    if (team != 2 && team != 3) {
        char message[128];
        Format(message, sizeof(message), "%T", "Team_Only", client);
        PrintToChat(client, " [\x04CSGO\x01] %s", message);
        return Plugin_Handled;
    }
    
    if (g_iTeamPausesLeft[team] <= 0) {
        char message[128];
        Format(message, sizeof(message), "%T", "No_Pauses_Left", client);
        PrintToChat(client, " [\x04CSGO\x01] %s", message);
        return Plugin_Handled;
    }
    
    int pauseTime = DEFAULT_PAUSE_TIME;
    
    if (args > 0) {
        char arg[32];
        GetCmdArg(1, arg, sizeof(arg));
        pauseTime = StringToInt(arg);
        
        if (pauseTime < 1) {
            char message[128];
            Format(message, sizeof(message), "%T", "Invalid_Time", client);
            PrintToChat(client, " [\x04CSGO\x01] %s", message);
            return Plugin_Handled;
        }
        
        if (pauseTime > MAX_PAUSE_TIME) {
            pauseTime = MAX_PAUSE_TIME;
        }
    }
    
    ExecutePause(client, team, pauseTime);
    return Plugin_Handled;
}

void ExecutePause(int client, int team, int pauseTime) {
    g_bGamePaused = true;
    g_iTeamPausesLeft[team]--;
    
    char clientName[64];
    GetClientName(client, clientName, sizeof(clientName));
    
    char teamName[16];
    if (team == 2) {
        strcopy(teamName, sizeof(teamName), "T");
    } else {
        strcopy(teamName, sizeof(teamName), "CT");
    }
    
    char message[256];
    char coloredCount[32];
    Format(coloredCount, sizeof(coloredCount), "\x04%d\x01", g_iTeamPausesLeft[team]);
    
    // 使用 LANG_SERVER 来广播给所有玩家，每个玩家会看到自己语言的版本
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) {
            continue;
        }
        
        // 如果是默认暂停时间，不显示时间
        if (pauseTime == DEFAULT_PAUSE_TIME) {
            Format(message, sizeof(message), "%T", "Pause_No_Time", i, clientName, teamName, coloredCount);
            PrintToChat(i, " [\x04CSGO\x01] %s", message);
        } else {
            Format(message, sizeof(message), "%T", "Pause_With_Time", i, clientName, pauseTime, teamName, coloredCount);
            PrintToChat(i, " [\x04CSGO\x01] %s", message);
        }
    }
    
    ServerCommand("mp_pause_match");
    
    g_hPauseTimer = CreateTimer(float(pauseTime), Timer_AutoUnpause);
    
    // 触发Forward通知其他插件
    Call_StartForward(g_hForward_OnBotPause);
    Call_PushCell(client);
    Call_PushCell(pauseTime);
    Call_Finish();
}

public Action Timer_AutoUnpause(Handle timer) {
    g_hPauseTimer = null;
    
    if (g_bGamePaused) {
        ServerCommand("mp_unpause_match");
        g_bGamePaused = false;
    }
    
    return Plugin_Stop;
}

public void OnPluginEnd() {
    if (g_hPauseTimer != null) {
        KillTimer(g_hPauseTimer);
        g_hPauseTimer = null;
    }
    
    if (g_bGamePaused) {
        ServerCommand("mp_unpause_match");
    }
}

/**
 * 执行暂停
 * 
 * @param plugin        调用插件句柄
 * @param numParams     参数数量
 * @return              1=成功, 0=失败
 */
public int Native_ExecutePause(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    int pauseTime = GetNativeCell(2);
    
    if (!IsValidClient(client)) {
        return 0;
    }
    
    if (g_bGamePaused) {
        return 0;
    }
    
    int team = GetClientTeam(client);
    if (team != 2 && team != 3) {
        return 0;
    }
    
    if (g_iTeamPausesLeft[team] <= 0) {
        return 0;
    }
    
    if (pauseTime < 1) {
        pauseTime = DEFAULT_PAUSE_TIME;
    }
    
    if (pauseTime > MAX_PAUSE_TIME) {
        pauseTime = MAX_PAUSE_TIME;
    }
    
    ExecutePause(client, team, pauseTime);
    return 1;
}

/**
 * 获取队伍剩余暂停次数
 * 
 * @param plugin        调用插件句柄
 * @param numParams     参数数量
 * @return              剩余次数
 */
public int Native_GetTeamPausesLeft(Handle plugin, int numParams) {
    int team = GetNativeCell(1);
    
    if (team != 2 && team != 3) {
        return 0;
    }
    
    return g_iTeamPausesLeft[team];
}

//取消暂停
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    // 回合结束时立即取消暂停
    if (g_hPauseTimer != null) {
        KillTimer(g_hPauseTimer);
        g_hPauseTimer = null;
    }
    
    if (g_bGamePaused) {
        ServerCommand("mp_unpause_match");
        g_bGamePaused = false;
        PrintToServer("[Bot Pause] Round ended, auto-unpausing");
    }
}

// ============================================================================
// 辅助函数
// ============================================================================

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && 
            IsClientConnected(client) && 
            IsClientInGame(client));
}