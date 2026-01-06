#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <botmimic>
#include <ripext>
#include <bot_pause>
#include <bot_voice>

#pragma newdecls required
#pragma semicolon 1

// ============================================================================
// 插件信息
// ============================================================================
public Plugin myinfo = 
{
	name = "Bot Replay", 
	author = "Tasty cup", 
	description = "Play recordings for bots at round start", 
	version = "1.2.0", 
	url = ""
};


// 插件灵感来源于 chunchun 的回放插件
// 本插件由本人独立实现，并进行了功能优化
// 感谢 chunchun 的启发与理解


// ============================================================================
// 全局变量
// ============================================================================

// Bot状态枚举
enum BotState
{
    BotState_Normal = 0,     // 正常状态
    BotState_PlayingREC      // 正在播放REC
}

// 回合选择模式 
enum RoundSelectionMode
{
    Round_FullMatch = 0,    // 全局回合模式（按当前回合播放）
    Round_Economy          // 经济回合模式（根据经济选择）
}

// 回放模式
enum PlaybackMode
{
    Playback_Full = 0,      // 完整回合模式(从回合开始播放)
    Playback_PreGame = 1    // 赛前模式(冻结时间前1秒播放)
}

// 经济选择模式
enum EconomySelectionMode
{
    Economy_SingleTeam = 0,     // 单队经济模式（默认）
    Economy_BothTeams = 1      // 双队经济模式
}

// 经济需求类型
enum EconomyDemandType
{
    Demand_Eco = 0,      // eco局
    Demand_SemiForce,    // 半起
    Demand_FullForce     // 强起
}

// REC装备信息
enum struct RecEquipmentInfo
{
    char recName[PLATFORM_MAX_PATH];  // REC文件名
    int totalCost;           // 总成本
    int totalValue;          // 总价值
}

// 回合候选信息(用于双队经济模式)
enum struct RoundCandidate
{
    int round;                          // 回合编号
    char demoFolder[PLATFORM_MAX_PATH]; // demo文件夹
    int totalValue;                     // 总价值
    float freezeTime;                   // 冻结时间
    int assignment[MAXPLAYERS+1];       // 分配方案
}

// Bot状态
bool g_bPlayingRoundStartRec[MAXPLAYERS+1];           // 是否正在播放REC
bool g_bPurchaseSystemActive[MAXPLAYERS+1];           // 购买系统是否激活
char g_szRoundStartRecPath[MAXPLAYERS+1][PLATFORM_MAX_PATH];  // REC路径
char g_szCurrentRecName[MAXPLAYERS+1][PLATFORM_MAX_PATH];     // 当前REC文件名
char g_szAssignedRecName[MAXPLAYERS+1][PLATFORM_MAX_PATH];    // 经济模式下分配的REC名称
int g_iAssignedRecIndex[MAXPLAYERS+1];                // 分配的REC索引
int g_iRecStartMoney[MAXPLAYERS+1];                   // REC开始时的金钱
bool g_bRecMoneySet[MAXPLAYERS+1];                    // 金钱是否已设置
float g_fRecStartTime[MAXPLAYERS+1];                  // REC开始时间
BotState g_BotShared_State[MAXPLAYERS+1];             // 每个Bot的状态

// 文件夹选择
char g_szCurrentRecFolder[PLATFORM_MAX_PATH];         // 当前选择的REC文件夹
char g_szBotRecFolder[MAXPLAYERS+1][PLATFORM_MAX_PATH];  // 每个bot使用的demo文件夹
bool g_bRecFolderSelected = false;                    // 文件夹是否已选择

// 回合信息
int g_iCurrentRound = 0;                              // 当前回合数
bool g_bBombPlanted = false;                          // 炸弹是否已安装
bool g_bBombPlantedThisRound = false;                 // 本回合是否已下包

// 模式设置
RoundSelectionMode g_iRoundMode = Round_Economy;     // 回合选择模式
EconomySelectionMode g_iEconomyMode = Economy_SingleTeam;  // 经济选择模式
PlaybackMode g_iPlaybackMode = Playback_Full;         // 回放模式
int g_iSelectedRoundForTeam[4] = {-1, ...};           // 每个阵营选择的回合数
bool g_bEconomyBasedSelection = false;                // 标记是否使用经济模式选择
char g_szSelectedDemoForTeam[4][PLATFORM_MAX_PATH];   // 每个阵营选择的demo文件夹
ArrayList g_hAssignedRecsForTeam[4];                  // 每个阵营已分配的REC列表

// 冻结时间验证
float g_fValidRoundFreezeTimes[31];                   // 存储每个回合的有效冻结时间（经济系统用）
bool g_bRoundFreezeTimeValid[31];                     // 标记该回合的冻结时间是否有效（经济系统用）
float g_fAllRoundFreezeTimes[31];                     // 存储所有回合的冻结时间（暂停系统用）
bool g_bAllRoundFreezeTimeValid[31];                  // 标记所有回合的冻结时间（暂停系统用）
float g_fStandardFreezeTime = 20.0;                   // 标准冻结时间
float g_fTeamVerifyDelay[4];                          // 存储每个阵营的验证延迟时间

// SDK偏移量
int g_BotShared_EnemyVisibleOffset = -1;    // 敌人可见偏移
int g_BotShared_EnemyOffset = -1;           // 敌人偏移

// 敌人缓存
int g_BotShared_CachedEnemy[MAXPLAYERS+1] = {-1, ...};        // 缓存的敌人
float g_BotShared_EnemyCacheTime[MAXPLAYERS+1] = {0.0, ...};  // 缓存时间

// 武器类型常量定义
#define WEAPON_TYPE_RIFLE 1
#define WEAPON_TYPE_SNIPER 2
#define WEAPON_TYPE_SMG 4
#define WEAPON_TYPE_UTILITY 8
#define WEAPON_TYPE_DEFAULT_PISTOL 16

// ConVars
ConVar g_cvEconomyMode;
ConVar g_cvRoundMode;
ConVar g_cvPlaybackMode;

// 武器数据表 
StringMap g_hWeaponPrices;
StringMap g_hWeaponConversion_T;
StringMap g_hWeaponConversion_CT;
StringMap g_hWeaponTypes;

// 暂停系统(用于全局模式)
bool g_bPausePluginLoaded = false;                // 使用bot_pause插件

// 聊天系统
JSONArray g_jChatData = null;                     // 聊天数据
ArrayList g_hChatActions[MAXPLAYERS+1];           // 每个bot的聊天队列
int g_iChatActionIndex[MAXPLAYERS+1];             // 当前聊天动作索引
Handle g_hChatTimer[MAXPLAYERS+1];                // 每个bot的聊天timer

// 语音系统
JSONArray g_jVoiceData = null;                    // 语音数据
ArrayList g_hVoiceActions[MAXPLAYERS+1];          // 每个bot的语音队列
int g_iVoiceActionIndex[MAXPLAYERS+1];            // 当前语音动作索引
Handle g_hVoiceTimer[MAXPLAYERS+1];               // 每个bot的语音timer
ArrayList g_hVoiceFiles[MAXPLAYERS+1];            // 存储每个bot的语音文件列表

enum struct VoiceActionEntry
{
    float startTime;
    float duration;
    int fileIndex; 
    bool isAlive;
}

// 出生点系统
JSONObject g_jSpawnData = null;                   // spawns.json缓存
ArrayList g_hTeamSpawnPoints[4];                  // 每个队伍的所有出生点
float g_fAssignedSpawnPos[MAXPLAYERS+1][3];      // 每个玩家分配好的出生点
bool g_bHasAssignedSpawn[MAXPLAYERS+1];          // 是否已分配出生点

// 购买数据（用于经济模式）
JSONObject g_jPurchaseData = null;
JSONArray g_jC4HolderData = null;                 // C4持有者数据
JSONObject g_jMoneyData = null;                   // money.json缓存

// 购买系统
ArrayList g_hPurchaseActions[MAXPLAYERS+1];       // 每个bot的购买队列
int g_iPurchaseActionIndex[MAXPLAYERS+1];         // 当前购买动作索引
Handle g_hPurchaseTimer[MAXPLAYERS+1];            // 每个bot的购买timer
ArrayList g_hFinalInventory[MAXPLAYERS+1];        // 每个bot应该拥有的最终装备
ArrayList g_hInitialInventory[MAXPLAYERS+1];      // 每个bot回合开始的初始装备
bool g_bInitialInventoryApplied[MAXPLAYERS+1];    // 初始装备是否已应用
bool g_bAllowPurchase[MAXPLAYERS+1];              // 标记是否允许购买（用于区分系统购买和手动购买）
float g_fRoundStartGameTime = 0.0;                // 记录回合开始的GameTime

// 带包检测
Handle g_hBombCarrierCheckTimer = null;              // 带包检测timer

// 伤害检测
int g_iLastAttacker[MAXPLAYERS+1];                // 上次攻击者
int g_iLastDamageType[MAXPLAYERS+1];              // 上次伤害类型

// 购买优先级
int GetItemBuyPriority(const char[] szItem)
{
    // 道具工具
    if (StrEqual(szItem, "smokegrenade") || StrEqual(szItem, "flashbang") || 
        StrEqual(szItem, "hegrenade") || StrEqual(szItem, "molotov") || 
        StrEqual(szItem, "incgrenade") || StrEqual(szItem, "decoy"))
        return 1;
    
    // 护甲
    if (StrEqual(szItem, "vest") || StrEqual(szItem, "vesthelm"))
        return 2;
    
    // 拆弹器
    if (StrEqual(szItem, "defuser"))
        return 3;
    
    // 副武器
    if (StrEqual(szItem, "deagle") || StrEqual(szItem, "p250") || 
        StrEqual(szItem, "tec9") || StrEqual(szItem, "fn57") || 
        StrEqual(szItem, "cz75a") || StrEqual(szItem, "elite") || 
        StrEqual(szItem, "revolver"))
        return 4;
    
    // 主武器 
    return 5;
}

// ============================================================================
// 插件生命周期
// ============================================================================

public void OnPluginStart()
{
    // 初始化武器数据  
    InitWeaponData();    

    // 初始化共享库
    if (!BotShared_Init())
    {
        SetFailState("[Bot REC] Failed to initialize Bot Shared library");
    }

    // 检测 bot_pause 插件是否加载
    g_bPausePluginLoaded = LibraryExists("bot_pause");

    // 创建ConVars
    g_cvEconomyMode = CreateConVar("sm_botrec_economy_mode", "0", 
        "Economy selection mode: 0=Single Team (default), 1=Both Teams", 
        FCVAR_NOTIFY, true, 0.0, true, 1.0);  
    
    g_cvRoundMode = CreateConVar("sm_botrec_round_mode", "0", 
        "Round selection mode: 0=Full Match (default), 1=Economy Based", 
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvPlaybackMode = CreateConVar("sm_botrec_playback_mode", "0",
        "Playback mode: 0=Full Round (default), 1=PreGame (start 1s before freeze ends)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    
    // 注册管理员命令
    RegAdminCmd("sm_botrec_economy", Command_SetEconomyMode, ADMFLAG_GENERIC, 
        "Set economy mode: 0=Off, 1=Single Team, 2=Both Teams");
    
    RegAdminCmd("sm_botrec_round", Command_SetRoundMode, ADMFLAG_GENERIC, 
        "Set round mode: 0=Full Match, 1=Economy Based");
    
    RegAdminCmd("sm_botrec_status", Command_ShowStatus, ADMFLAG_GENERIC, 
        "Show current bot REC status");

    RegAdminCmd("sm_botrec_debug", Command_DebugInfo, ADMFLAG_GENERIC, 
        "Show detailed debug information");     

    RegAdminCmd("sm_botrec_playback", Command_SetPlaybackMode, ADMFLAG_GENERIC,
        "Set playback mode: 0=Full, 1=PreGame"); 

    RegAdminCmd("sm_botrec_select", Command_SelectDemo, ADMFLAG_GENERIC,
        "Select specific demo folder");          

    // Hook游戏事件
    HookEvent("round_prestart", Event_RoundPreStart);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("player_spawn", Event_PlayerSpawn);
    
    // 初始化所有客户端数据
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientData(i);
        
        // 初始化购买数据
        g_hPurchaseTimer[i] = null;
        g_hPurchaseActions[i] = null;
        g_iPurchaseActionIndex[i] = 0;
        g_hFinalInventory[i] = null;
        g_bAllowPurchase[i] = false;
        g_hInitialInventory[i] = null;
        g_bInitialInventoryApplied[i] = false;
        g_bPurchaseSystemActive[i] = false;

        // 初始化聊天数据 
        g_hChatTimer[i] = null;
        g_hChatActions[i] = null;
        g_iChatActionIndex[i] = 0;   

        // 初始化语音数据
        g_hVoiceTimer[i] = null;
        g_hVoiceActions[i] = null;
        g_iVoiceActionIndex[i] = 0;     
        g_hVoiceFiles[i] = null;  

        // 初始化出生点数据
        g_bHasAssignedSpawn[i] = false;
    }
    
    // 重置阵营回合选择
    for (int i = 0; i < sizeof(g_iSelectedRoundForTeam); i++)
    {
        g_iSelectedRoundForTeam[i] = -1;
        g_szSelectedDemoForTeam[i][0] = '\0';  
        g_hAssignedRecsForTeam[i] = null;
    }     
    
    PrintToServer("[Bot REC] Plugin loaded");
}

public void OnMapStart()
{
    for (int i = 0; i < 4; i++)
    {
        g_fTeamVerifyDelay[i] = 0.0;
        
        // 初始化出生点数组
        if (g_hTeamSpawnPoints[i] != null)
            delete g_hTeamSpawnPoints[i];
        g_hTeamSpawnPoints[i] = new ArrayList(3);  
    }
    
    // 重置rec文件夹选择
    g_szCurrentRecFolder[0] = '\0';
    g_bRecFolderSelected = false;
    
    // 重置阵营回合选择
    for (int i = 0; i < sizeof(g_iSelectedRoundForTeam); i++)
    {
        g_iSelectedRoundForTeam[i] = -1;
        g_szSelectedDemoForTeam[i][0] = '\0';    

        // 清理已分配REC列表
        if (g_hAssignedRecsForTeam[i] != null)
        {
            delete g_hAssignedRecsForTeam[i];
            g_hAssignedRecsForTeam[i] = null;
        }
    }
    
    // 初始化暂停系统的冻结时间数组
    for (int i = 0; i < 31; i++)
    {
        g_bAllRoundFreezeTimeValid[i] = false;
        g_fAllRoundFreezeTimes[i] = 0.0;
    }
    
    // 初始化所有客户端数据
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientData(i);
    }
    
    // 清理购买数据
    if (g_jPurchaseData != null)
    {
        delete g_jPurchaseData;
        g_jPurchaseData = null;
    }

    // 清理语音数据
    if (g_jVoiceData != null)
    {
        delete g_jVoiceData;
        g_jVoiceData = null;
    }

    // 清理C4持有者数据
    if (g_jC4HolderData != null)
    {
        delete g_jC4HolderData;
        g_jC4HolderData = null;
    }
    
    // 获取地图名称
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    PrintToServer("[Bot REC] Map started: %s", szMap);
}

public void OnMapEnd()
{
    // 清理所有缓存数据
    ClearAllCachedData();
    
    // 清理带包检测timer
    KillClientTimer(g_hBombCarrierCheckTimer);
    
    // 清理出生点数组
    for (int i = 0; i < 4; i++)
    {
        if (g_hTeamSpawnPoints[i] != null)
        {
            delete g_hTeamSpawnPoints[i];
            g_hTeamSpawnPoints[i] = null;
        }
    }
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client))
        return;
    
    ResetClientData(client);
}

public void OnClientDisconnect(int client)
{
    ResetClientData(client);
    CleanupClientTimers(client);
}

// ============================================================================
// 游戏事件处理
// ============================================================================

public void Event_RoundPreStart(Event event, const char[] name, bool dontBroadcast)
{
    g_iCurrentRound = GameRules_GetProp("m_totalRoundsPlayed");
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // 记录回合开始时间
    g_fRoundStartGameTime = GetGameTime();

    // 清理所有玩家的出生点分配
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bHasAssignedSpawn[i] = false;
    }

    // 清理所有bot上一回合的语音
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && IsFakeClient(i))
        {
            KillClientTimer(g_hVoiceTimer[i]);
            
            if (BotVoice_IsSpeaking(i))
            {
                BotVoice_StopAllSpeaking(i);
            }
            
            if (g_hVoiceActions[i] != null)
            {
                delete g_hVoiceActions[i];
                g_hVoiceActions[i] = null;
            }
            
            if (g_hVoiceFiles[i] != null)
            {
                delete g_hVoiceFiles[i];
                g_hVoiceFiles[i] = null;
            }
            
            g_iVoiceActionIndex[i] = 0;
        }
    }  

    BotShared_ResetBombState();
    
    // 从 ConVar 读取当前模式
    g_iPlaybackMode = view_as<PlaybackMode>(g_cvPlaybackMode.IntValue);
    g_iEconomyMode = view_as<EconomySelectionMode>(g_cvEconomyMode.IntValue);
    g_iRoundMode = view_as<RoundSelectionMode>(g_cvRoundMode.IntValue);
    
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    

    // 第一回合选择rec文件夹
    if (g_iCurrentRound == 0)
    {
        if (SelectRandomRecFolder(szMap))
        {
            PrintToServer("[Bot REC] Selected folder: %s", g_szCurrentRecFolder);
            LoadAllDemoData(szMap, g_szCurrentRecFolder); 
        }
        else
        {
            g_szCurrentRecFolder[0] = '\0';
            g_bRecFolderSelected = false;
        }
    }
    else if (g_bRecFolderSelected && !g_bRoundFreezeTimeValid[g_iCurrentRound])
    {
        float fDummy[31];
        bool bDummy[31];
        LoadFreezeTimes(szMap, g_szCurrentRecFolder, fDummy, bDummy);
    }
    
    // 如果是经济回合模式
    if (g_iRoundMode == Round_Economy && g_bRecFolderSelected)
    {
        g_bEconomyBasedSelection = true;
        
        // 重置阵营回合选择
        g_iSelectedRoundForTeam[CS_TEAM_T] = -1;
        g_iSelectedRoundForTeam[CS_TEAM_CT] = -1;
        g_szSelectedDemoForTeam[CS_TEAM_T][0] = '\0';  
        g_szSelectedDemoForTeam[CS_TEAM_CT][0] = '\0';  
        
        // 清理已分配REC列表
        if (g_hAssignedRecsForTeam[CS_TEAM_T] != null)
            delete g_hAssignedRecsForTeam[CS_TEAM_T];
        if (g_hAssignedRecsForTeam[CS_TEAM_CT] != null)
            delete g_hAssignedRecsForTeam[CS_TEAM_CT];
        
        g_hAssignedRecsForTeam[CS_TEAM_T] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
        g_hAssignedRecsForTeam[CS_TEAM_CT] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
        
        // 根据经济模式选择
        if (g_iEconomyMode == Economy_SingleTeam)
        {
            SelectRoundByEconomy(CS_TEAM_T);
            SelectRoundByEconomy(CS_TEAM_CT);
        }
        else if (g_iEconomyMode == Economy_BothTeams)
        {
            int iSelectedRound = SelectRoundByBothTeamsEconomy();
            g_iSelectedRoundForTeam[CS_TEAM_T] = iSelectedRound;
            g_iSelectedRoundForTeam[CS_TEAM_CT] = iSelectedRound;
        }
    }
    else if (g_iRoundMode == Round_FullMatch)
    {
        g_bEconomyBasedSelection = false;
        
        if (g_bRecFolderSelected && g_szCurrentRecFolder[0] != '\0')
        {
            if (g_bAllRoundFreezeTimeValid[g_iCurrentRound])
            {
                float fDemoFreeze = g_fAllRoundFreezeTimes[g_iCurrentRound];
                float fVerifyDelay = fDemoFreeze - 3.0;
                if (fVerifyDelay < 0.1)
                    fVerifyDelay = 0.1;
                
                g_fTeamVerifyDelay[CS_TEAM_T] = fVerifyDelay;
                g_fTeamVerifyDelay[CS_TEAM_CT] = fVerifyDelay;
            }
            else
            {
                g_fTeamVerifyDelay[CS_TEAM_T] = 7.0;
                g_fTeamVerifyDelay[CS_TEAM_CT] = 7.0;
            }
        }
    } 
    
    // 全局模式下的动态暂停系统
    if (g_iRoundMode == Round_FullMatch && g_bRecFolderSelected)
    {
        ScheduleDynamicPause(g_iCurrentRound);
    }
    
    // 为所有bot分配并播放REC
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        AssignAndPlayRec(i);
    }

    // 在冻结时间开始时立即分配C4
    if (g_bRecFolderSelected)
    {
        // 延迟0.1秒
        CreateTimer(0.1, Timer_AssignC4AtFreezeStart, _, TIMER_FLAG_NO_MAPCHANGE);
    }

    // 预分配玩家出生点
    if (g_bRecFolderSelected)
    {
        PreAssignPlayerSpawns();
    }

    // pregame模式下的播放逻辑
    if (g_iPlaybackMode == Playback_PreGame && g_bRecFolderSelected)
    {
        CreateTimer(0.0, Timer_InstantPlayForPosition, _, TIMER_FLAG_NO_MAPCHANGE);
        
        ConVar cvFreezeTime = FindConVar("mp_freezetime");
        float fFreezeTime = (cvFreezeTime != null) ? cvFreezeTime.FloatValue : 15.0;
        float fStartDelay = fFreezeTime - 1.0;
        
        if (fStartDelay < 0.1)
            fStartDelay = 0.1;
        
        CreateTimer(fStartDelay, Timer_StartAllBotsPlayback, _, TIMER_FLAG_NO_MAPCHANGE);
    }
    
    // 清理旧的timer
    if (g_hBombCarrierCheckTimer != null)
    {
        CloseHandle(g_hBombCarrierCheckTimer);
        g_hBombCarrierCheckTimer = null;
    }
    
    // 获取冻结时间
    ConVar cvFreezeTime = FindConVar("mp_freezetime");
    float fFreezeTime = (cvFreezeTime != null) ? cvFreezeTime.FloatValue : 15.0;
    
    // 冻结结束后90秒检查带包T
    float fBombCheckDelay = fFreezeTime + 90.0;
    g_hBombCarrierCheckTimer = CreateTimer(fBombCheckDelay, Timer_CheckBombCarrier, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    
    if (!IsValidClient(client))
        return;
    
    // Bot数据重置
    if (IsFakeClient(client))
    {
        g_iAssignedRecIndex[client] = -1;
        g_bRecMoneySet[client] = false;
        g_bInitialInventoryApplied[client] = false;
        
        if (g_iPlaybackMode == Playback_PreGame && g_bPlayingRoundStartRec[client])
        {
            return;
        }
        
        return;
    }
    
    // 应用预分配的出生点
    if (g_bHasAssignedSpawn[client] && IsPlayerAlive(client))
    {
        if (GameRules_GetProp("m_bFreezePeriod"))
        {
            CreateTimer(0.01, Timer_TeleportPlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}
// ============================================================================
// OnPlayerRunCmd - 检测炸弹安装和敌人
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (client < 1 || client > MaxClients)
        return Plugin_Continue;
    
    // 检测炸弹安装
    g_bBombPlanted = !!GameRules_GetProp("m_bBombPlanted");
    
    if (g_bBombPlanted && !g_bBombPlantedThisRound)
    {
        g_bBombPlantedThisRound = true;
        
        // 根据模式决定是否停止 REC
        if (g_iRoundMode == Round_Economy && g_iEconomyMode == Economy_SingleTeam)
        {
            StopTeamBotsRec(CS_TEAM_CT, false);
        }
        else if (g_iRoundMode == Round_FullMatch || 
                (g_iRoundMode == Round_Economy && g_iEconomyMode == Economy_BothTeams))
        {
            StopTeamBotsRec(CS_TEAM_CT, true);
        }
    }
    
    if (!IsValidClient(client) || !IsPlayerAlive(client) || !IsFakeClient(client))
        return Plugin_Continue;
    
    if (g_bPlayingRoundStartRec[client] && BotMimic_IsPlayerMimicing(client))
    {
        static int iCheckCounter[MAXPLAYERS+1];
        static int iLastHealth[MAXPLAYERS+1];
    
        iCheckCounter[client]++;
    
        if (iCheckCounter[client] >= 10)
        {
            iCheckCounter[client] = 0;
        
            //每次都重新获取
            int iEnemy = BotShared_GetEnemy(client);  
            bool bSeeEnemy = false;
        
            // 先验证敌人有效性
            if (iEnemy != -1 && BotShared_IsValidClient(iEnemy) && IsPlayerAlive(iEnemy))
            {
                int iClientTeam = GetClientTeam(client);
                int iEnemyTeam = GetClientTeam(iEnemy);
        
                // 确保是真正的敌人
                if (iClientTeam != iEnemyTeam)
                {
                    if (g_iRoundMode == Round_FullMatch || 
                        (g_iRoundMode == Round_Economy && g_iEconomyMode == Economy_BothTeams))
                    {
                        // 敌人必须"正在播放且仍在播放中"
                        if (g_bPlayingRoundStartRec[iEnemy] && BotMimic_IsPlayerMimicing(iEnemy))
                        {
                            bSeeEnemy = false;  
                        }
                        else
                        {
                            bSeeEnemy = BotShared_CanSeeEnemy(client);
                        }
                    }
                    else
                    {
                        bSeeEnemy = BotShared_CanSeeEnemy(client);
                    }
                }
            }
        
            // 伤害检测增加时间窗口验证
            int iCurrentHealth = GetClientHealth(client);
            int iDamage = iLastHealth[client] - iCurrentHealth;
            bool bShouldStopFromDamage = false;
        
            if (iDamage > 0 && iLastHealth[client] > 0)
            {
                if (g_iRoundMode == Round_FullMatch || 
                    (g_iRoundMode == Round_Economy && g_iEconomyMode == Economy_BothTeams))
                {
                    int iAttacker = g_iLastAttacker[client];
                
                    // 同时检查播放状态和Mimic状态
                    if (BotShared_IsValidClient(iAttacker) && 
                        IsFakeClient(iAttacker) && 
                        IsPlayerAlive(iAttacker) &&  // 攻击者必须存活
                        g_bPlayingRoundStartRec[iAttacker] && 
                        BotMimic_IsPlayerMimicing(iAttacker))  // 必须确实在播放
                    {
                        bShouldStopFromDamage = false;
                    }
                    else
                    {
                        bShouldStopFromDamage = ShouldStopFromDamage(iDamage, g_iLastDamageType[client]);
                    }
                }
                else
                {
                    bShouldStopFromDamage = ShouldStopFromDamage(iDamage, g_iLastDamageType[client]);
                }
            }
        
            iLastHealth[client] = iCurrentHealth;
        
            if (bSeeEnemy || bShouldStopFromDamage)
            {
                BotMimic_StopPlayerMimic(client);
                g_bPlayingRoundStartRec[client] = false;
            }
        }
    }
    
    return Plugin_Continue;
}

// ============================================================================
// BotMimic回调
// ============================================================================

public void BotMimic_OnPlayerStopsMimicing(int client, char[] name, char[] category, char[] path)
{
    if (g_bPlayingRoundStartRec[client])
    {
        // 重置Bot状态为正常
        BotShared_ResetBotState(client);

        g_bPlayingRoundStartRec[client] = false;
        
        KillClientTimer(g_hChatTimer[client]);
        
        if (g_hChatActions[client] != null)
        {
            delete g_hChatActions[client];
            g_hChatActions[client] = null;
        }
        g_iChatActionIndex[client] = 0;
        
        g_bAllowPurchase[client] = false;

        if (g_hInitialInventory[client] != null)
        {
            delete g_hInitialInventory[client];
            g_hInitialInventory[client] = null;
        }
        
        g_bInitialInventoryApplied[client] = false;
        
        // Unhook伤害
        SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

// ============================================================================
// 伤害Hook - 防止播放REC时摔伤，记录伤害信息
// ============================================================================

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    // 记录伤害信息供后续判断
    g_iLastAttacker[victim] = attacker;
    g_iLastDamageType[victim] = damagetype;
    
    // 如果正在播放REC
    if (g_bPlayingRoundStartRec[victim])
    {
        // 摔落伤害 - 完全阻止
        if (damagetype & DMG_FALL)
        {
            return Plugin_Handled;
        }
    }
    
    return Plugin_Continue;
}

// ============================================================================
// REC分配和播放
// ============================================================================

void AssignAndPlayRec(int client)
{
    char szBotName[MAX_NAME_LENGTH];
    GetClientName(client, szBotName, sizeof(szBotName));
    
    char szRecPath[PLATFORM_MAX_PATH];
    bool bFoundRec = false;
    int iRoundToUse = g_iCurrentRound;
    
    // 根据模式选择rec
    if (g_bEconomyBasedSelection)
    {
        int iClientTeam = GetClientTeam(client);
        int iSelectedRound = g_iSelectedRoundForTeam[iClientTeam];
        
        if (iSelectedRound != -1)
        {
            iRoundToUse = iSelectedRound;
            bFoundRec = GetRoundStartRecForRound(client, iSelectedRound, szRecPath, sizeof(szRecPath));
        }
    }
    else
    {
        bFoundRec = GetRoundStartRec(client, g_iCurrentRound, szRecPath, sizeof(szRecPath));
    }
    
    if (bFoundRec)
    {
        strcopy(g_szRoundStartRecPath[client], sizeof(g_szRoundStartRecPath[]), szRecPath);
        
        // 设置金钱 只在全局模式下设置
        if (g_iRoundMode == Round_FullMatch && !g_bRecMoneySet[client] && g_iRecStartMoney[client] > 0)
        {
            SetEntProp(client, Prop_Send, "m_iAccount", g_iRecStartMoney[client]);
            g_bRecMoneySet[client] = true;
        }
        
        // 根据模式选择购买系统
        bool bPurchaseLoaded = false;
        if (g_iPlaybackMode == Playback_PreGame)
        {
            bPurchaseLoaded = LoadPreGamePurchaseList(client, iRoundToUse);
        }
        else
        {
            bPurchaseLoaded = LoadPurchaseActionsForBot(client, iRoundToUse);
        }
        
        if (bPurchaseLoaded)
        {
            // 拦截bot的默认购买
            g_bPurchaseSystemActive[client] = true;
            
            // 清理旧的购买timer
            KillClientTimer(g_hPurchaseTimer[client]);

            // 创建购买执行timer
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            g_hPurchaseTimer[client] = CreateTimer(0.1, Timer_ExecutePurchaseAction, pack, 
                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }

        // 加载聊天数据
        bool bChatLoaded = LoadChatActionsForBot(client, iRoundToUse);
        
        if (bChatLoaded)
        {
            // 清理旧的聊天timer
            KillClientTimer(g_hChatTimer[client]);
            
            // 创建聊天执行timer
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            g_hChatTimer[client] = CreateTimer(0.1, Timer_ExecuteChatAction, pack, 
                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }

        // 加载语音数据
        bool bVoiceLoaded = LoadVoiceActionsForBot(client, iRoundToUse);

        if (bVoiceLoaded)
        {
            // 清理旧的语音timer
            KillClientTimer(g_hVoiceTimer[client]);
    
            // 创建语音执行timer
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            g_hVoiceTimer[client] = CreateTimer(0.1, Timer_ExecuteVoiceAction, pack, 
                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }

        
        // 根据模式决定播放时机
        if (g_iPlaybackMode == Playback_PreGame)
        {
        }
        else
        {
            StartBotRecPlayback(client);
        }
    }
}

// ============================================================================
// REC文件选择
// ============================================================================

bool SelectRandomRecFolder(const char[] szMap)
{
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szMapBasePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/%s/%s", szModeBase, szMap);
    
    if (!DirExists(szMapBasePath))
        return false;
    
    ArrayList hFolders = new ArrayList(PLATFORM_MAX_PATH);
    DirectoryListing hMapDir = OpenDirectory(szMapBasePath);
    if (hMapDir == null)
        return false;
    
    char szFolderName[PLATFORM_MAX_PATH];
    FileType iFileType;
    
    while (hMapDir.GetNext(szFolderName, sizeof(szFolderName), iFileType))
    {
        if (iFileType == FileType_Directory && strcmp(szFolderName, ".") != 0 && strcmp(szFolderName, "..") != 0)
        {
            hFolders.PushString(szFolderName);
        }
    }
    
    delete hMapDir;
    
    if (hFolders.Length == 0)
    {
        delete hFolders;
        return false;
    }
    
    // 随机选择一个文件夹
    int iRandomFolder = GetRandomInt(0, hFolders.Length - 1);
    hFolders.GetString(iRandomFolder, g_szCurrentRecFolder, sizeof(g_szCurrentRecFolder));
    delete hFolders;
    
    g_bRecFolderSelected = true;

    // 加载C4持有者数据
    LoadC4HolderDataFile(g_szCurrentRecFolder);   

    return true;
}

bool GetRoundStartRec(int client, int iRound, char[] szPath, int iMaxLen)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    int iClientTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iClientTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iClientTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    // 使用bot专属的demo文件夹
    char szUseDemoFolder[PLATFORM_MAX_PATH];
    GetUseDemoFolder(client, szUseDemoFolder, sizeof(szUseDemoFolder));
    
    if (szUseDemoFolder[0] == '\0')
    {
        return false;
    }
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szRoundPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szRoundPath, sizeof(szRoundPath), "data/botmimic/%s/%s/%s/round%d/%s", 
        szModeBase, szMap, szUseDemoFolder, iRound + 1, szTeamName);
    
    if (!DirExists(szRoundPath))
        return false;
    
    DirectoryListing hDir = OpenDirectory(szRoundPath);
    if (hDir == null)
        return false;
    
    ArrayList hRecFiles = new ArrayList(PLATFORM_MAX_PATH);
    char szFileName[PLATFORM_MAX_PATH];
    FileType iFileType;
    
    while (hDir.GetNext(szFileName, sizeof(szFileName), iFileType))
    {
        if (iFileType == FileType_File && StrContains(szFileName, ".rec") != -1)
        {
            char szFullPath[PLATFORM_MAX_PATH];
            Format(szFullPath, sizeof(szFullPath), "%s/%s", szRoundPath, szFileName);
            hRecFiles.PushString(szFullPath);
        }
    }
    
    delete hDir;
    
    if (hRecFiles.Length == 0)
    {
        delete hRecFiles;
        return false;
    }
    
    // 在经济模式下，按照已分配的顺序获取REC
    if (g_bEconomyBasedSelection && g_szAssignedRecName[client][0] != '\0')
    {
        char szAssignedRecName[PLATFORM_MAX_PATH];
        strcopy(szAssignedRecName, sizeof(szAssignedRecName), g_szAssignedRecName[client]);
        
        // 查找匹配的REC文件
        for (int r = 0; r < hRecFiles.Length; r++)
        {
            char szRecPath[PLATFORM_MAX_PATH];
            hRecFiles.GetString(r, szRecPath, sizeof(szRecPath));
            
            if (StrContains(szRecPath, szAssignedRecName) != -1)
            {
                strcopy(szPath, iMaxLen, szRecPath);
                
                // 提取并保存rec文件名
                char szRecFileName[PLATFORM_MAX_PATH];
                int iLastSlash = FindCharInString(szPath, '/', true);
                if (iLastSlash != -1)
                    strcopy(szRecFileName, sizeof(szRecFileName), szPath[iLastSlash + 1]);
                else
                    strcopy(szRecFileName, sizeof(szRecFileName), szPath);
                
                ReplaceString(szRecFileName, sizeof(szRecFileName), ".rec", "");
                strcopy(g_szCurrentRecName[client], sizeof(g_szCurrentRecName[]), szRecFileName);
                
                // 保存已分配的索引，避免fallback逻辑重复分配
                g_iAssignedRecIndex[client] = r;
                
                GetRoundStartMoney(client, iRound);
                
                delete hRecFiles;
                return true;
            }
        }
        
        // 如果找不到匹配的REC文件，返回false
        delete hRecFiles;
        return false;
    }
    else if (g_bEconomyBasedSelection)
    {
        // 经济模式下，如果找不到分配列表，返回false
        delete hRecFiles;
        return false;
    }
    
    // 原有的循环分配逻辑（仅用于非经济模式）
    if (g_iAssignedRecIndex[client] == -1)
    {
        int iAssignedCount = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (i == client || !IsValidClient(i) || !IsFakeClient(i))
                continue;
            if (GetClientTeam(i) == iClientTeam && g_iAssignedRecIndex[i] != -1)
                iAssignedCount++;
        }
        g_iAssignedRecIndex[client] = iAssignedCount % hRecFiles.Length;
    }
    
    int iIndex = g_iAssignedRecIndex[client] % hRecFiles.Length;
    hRecFiles.GetString(iIndex, szPath, iMaxLen);
    
    // 提取rec文件名
    char szRecFileName[PLATFORM_MAX_PATH];
    int iLastSlash = FindCharInString(szPath, '/', true);
    if (iLastSlash != -1)
        strcopy(szRecFileName, sizeof(szRecFileName), szPath[iLastSlash + 1]);
    else
        strcopy(szRecFileName, sizeof(szRecFileName), szPath);
    
    ReplaceString(szRecFileName, sizeof(szRecFileName), ".rec", "");
    strcopy(g_szCurrentRecName[client], sizeof(g_szCurrentRecName[]), szRecFileName);
    
    GetRoundStartMoney(client, iRound);
    
    delete hRecFiles;
    return true;
}

bool GetRoundStartRecForRound(int client, int iRound, char[] szPath, int iMaxLen)
{
    // 与GetRoundStartRec类似,但使用指定的回合
    return GetRoundStartRec(client, iRound, szPath, iMaxLen);
}

bool GetRoundStartMoney(int client, int iRound)
{
    int iClientTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iClientTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iClientTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    // 使用缓存的money数据
    if (g_jMoneyData == null)
    {
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
    
    if (!g_jMoneyData.HasKey(szRoundKey))
    {
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    JSONObject jRound = view_as<JSONObject>(g_jMoneyData.Get(szRoundKey));
    if (!jRound.HasKey(szTeamName))
    {
        delete jRound;
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
    
    // 使用REC名称获取金钱
    if (g_szCurrentRecName[client][0] != '\0' && jTeam.HasKey(g_szCurrentRecName[client]))
    {
        g_iRecStartMoney[client] = jTeam.GetInt(g_szCurrentRecName[client]);
        
        delete jTeam;
        delete jRound;
        return true;
    }
    
    // 失败则使用默认值
    delete jTeam;
    delete jRound;
    
    g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
    return true;
}

// ============================================================================
// 经济模式 - 单队回合选择
// ============================================================================

void SelectRoundByEconomy(int iTeam)
{
    if (iTeam < 0 || iTeam >= 4)
        return;
    
    char szTeamName[4];
    if (iTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return;
    
    // 收集该队伍所有bot
    ArrayList hTeamBots = new ArrayList();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && IsFakeClient(i) && IsPlayerAlive(i) && GetClientTeam(i) == iTeam)
            hTeamBots.Push(i);
    }
    
    int iBotCount = hTeamBots.Length;
    if (iBotCount == 0)
    {
        delete hTeamBots;
        return;
    }
    
    // 按经济从低到高排序
    SortADTArrayCustom(hTeamBots, Sort_BotsByMoney);
    
    // 判断当前是否手枪局
    bool bCurrentIsPistol = IsCurrentRoundPistol();
    
    // 确定经济需求类型
    EconomyDemandType demandType = Demand_FullForce;  // 默认强起
    
    if (!bCurrentIsPistol)  // 非手枪局才判断经济需求
    {
        // 检查是否所有bot经济≤3000
        bool bAllLowEconomy = true;
        for (int b = 0; b < iBotCount; b++)
        {
            int client = hTeamBots.Get(b);
            int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
            if (clientMoney > 3000)
            {
                bAllLowEconomy = false;
                break;
            }
        }
        
        // 如果所有bot经济≤3000,随机决定需求类型
        if (bAllLowEconomy)
        {
            int iRandom = GetRandomInt(1, 100);
            if (iRandom <= 55) 
                demandType = Demand_Eco;
            else if (iRandom <= 80)  
                demandType = Demand_SemiForce;
            else  
                demandType = Demand_FullForce;
        }
    }
    
    // 获取地图和所有demo文件夹
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szMapBasePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/%s/%s", szMap);
    
    if (!DirExists(szMapBasePath))
    {
        delete hTeamBots;
        return;
    }
    
    // 获取所有demo文件夹
    ArrayList hDemoFolders = new ArrayList(PLATFORM_MAX_PATH);
    DirectoryListing hMapDir = OpenDirectory(szMapBasePath);
    if (hMapDir != null)
    {
        char szFolderName[PLATFORM_MAX_PATH];
        FileType iFileType;
        
        while (hMapDir.GetNext(szFolderName, sizeof(szFolderName), iFileType))
        {
            if (iFileType == FileType_Directory && strcmp(szFolderName, ".") != 0 && strcmp(szFolderName, "..") != 0)
            {
                hDemoFolders.PushString(szFolderName);
            }
        }
        delete hMapDir;
    }
    
    // 寻找最佳回合
    int iBestRound = -1;
    char szBestDemo[PLATFORM_MAX_PATH];
    int iBestScore = -999999;  
    int bestAssignment[MAXPLAYERS+1];
    
    for (int i = 0; i <= MAXPLAYERS; i++)
        bestAssignment[i] = -1;
    
    // 遍历所有demo
    for (int d = 0; d < hDemoFolders.Length; d++)
    {
        char szDemoFolder[PLATFORM_MAX_PATH];
        hDemoFolders.GetString(d, szDemoFolder, sizeof(szDemoFolder));
        
        // 加载该demo的freeze时间
        float fDemoFreezeTimes[31];
        bool bDemoFreezeValid[31];
        if (!LoadFreezeTimes(szMap, szDemoFolder, fDemoFreezeTimes, bDemoFreezeValid))
        {
            continue;
        }
        
        // 加载该demo的购买数据
        JSONObject jDemoPurchaseData = LoadPurchaseDataForDemo(szMap, szDemoFolder);
        if (jDemoPurchaseData == null)
        {
            continue;
        }
        
        // 扫描该demo的所有回合
        for (int iRound = 0; iRound <= 30; iRound++)
        {
            if (!bDemoFreezeValid[iRound])
                continue;
            
            // 手枪局匹配检查
            bool bRoundIsPistol = IsPistolRound(iRound);
            if (bCurrentIsPistol != bRoundIsPistol)
                continue;
            
            char szRoundKey[32];
            Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
            
            if (!jDemoPurchaseData.HasKey(szRoundKey))
                continue;
            
            JSONObject jRound = view_as<JSONObject>(jDemoPurchaseData.Get(szRoundKey));
            if (!jRound.HasKey(szTeamName))
            {
                delete jRound;
                continue;
            }
            
            JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
            
            // 获取该回合的REC文件列表
            ArrayList hRecFiles = GetRecFilesForRound(szMap, szDemoFolder, iRound, szTeamName);
            if (hRecFiles.Length < iBotCount)
            {
                delete hRecFiles;
                delete jTeam;
                delete jRound;
                continue;
            }
            
            // 构建REC装备信息缓存
            ArrayList hRecInfoList = BuildRecEquipmentInfo(hRecFiles, jTeam, iTeam);
            
            if (hRecInfoList.Length < iBotCount)
            {
                delete hRecInfoList;
                delete hRecFiles;
                delete jTeam;
                delete jRound;
                continue;
            }
            
            // 尝试为每个Bot分配REC
            int tempAssignment[MAXPLAYERS+1];
            for (int i = 0; i <= MAXPLAYERS; i++)
                tempAssignment[i] = -1;
            
            ArrayList usedRecIndices = new ArrayList();
            int iTotalValue = 0;
            int iTotalCost = 0;
            bool bAllAssigned = true;
            
            // 从钱最少的Bot开始分配
            for (int b = 0; b < iBotCount; b++)
            {
                int client = hTeamBots.Get(b);
                int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
                
                // 找到该Bot能买得起且价值最高的REC
                int iBestRecIndex = -1;
                int iBestRecValue = -1;
                
                for (int r = 0; r < hRecInfoList.Length; r++)
                {
                    // 检查是否已被使用
                    if (usedRecIndices.FindValue(r) != -1)
                        continue;
                    
                    RecEquipmentInfo recInfo;
                    hRecInfoList.GetArray(r, recInfo, sizeof(RecEquipmentInfo));
                    
                    // 检查Bot是否买得起
                    if (recInfo.totalCost > clientMoney)
                        continue;
                    
                    // 选择价值最高的
                    if (recInfo.totalValue > iBestRecValue)
                    {
                        iBestRecIndex = r;
                        iBestRecValue = recInfo.totalValue;
                    }
                }
                
                // 如果找不到能买得起的REC,这个回合不合格
                if (iBestRecIndex == -1)
                {
                    bAllAssigned = false;
                    break;
                }
                
                // 分配REC
                tempAssignment[b] = iBestRecIndex;
                usedRecIndices.Push(iBestRecIndex);
                
                RecEquipmentInfo recInfo;
                hRecInfoList.GetArray(iBestRecIndex, recInfo, sizeof(RecEquipmentInfo));
                iTotalValue += recInfo.totalValue;
                iTotalCost += recInfo.totalCost;
            }
            
            delete usedRecIndices;
            
            // 如果所有Bot都分配成功,根据需求类型计算分数
            if (bAllAssigned)
            {
                int iScore = 0;
                
                if (demandType == Demand_Eco)
                {
                    // Eco模式:花费越低越好
                    iScore = -iTotalCost;
                }
                else if (demandType == Demand_SemiForce)
                {
                    // 半起模式
                    int iTargetCost = iBotCount * 1750;  
                    int iDeviation = (iTotalCost - iTargetCost);
                    if (iDeviation < 0) iDeviation = -iDeviation;
                    iScore = -iDeviation;  // 偏离越小越好
                }
                else  
                {
                    // 强起模式:价值越高越好
                    iScore = iTotalValue;
                }
                
                // 更新最佳回合
                if (iScore > iBestScore)
                {
                    iBestRound = iRound;
                    strcopy(szBestDemo, sizeof(szBestDemo), szDemoFolder);
                    iBestScore = iScore;
                    
                    for (int i = 0; i <= MAXPLAYERS; i++)
                        bestAssignment[i] = tempAssignment[i];
                }
            }
            
            delete hRecInfoList;
            delete hRecFiles;
            delete jTeam;
            delete jRound;
        }
        
        delete jDemoPurchaseData;
    }
    
    delete hDemoFolders;
    
    // 如果没找到合适的回合
    if (iBestRound == -1)
    {
        delete hTeamBots;
        return;
    }
    
    // 应用最终分配
    g_iSelectedRoundForTeam[iTeam] = iBestRound;
    strcopy(g_szSelectedDemoForTeam[iTeam], PLATFORM_MAX_PATH, szBestDemo);
    
    // 设置验证延迟时间
    float fDemoFreezeTimes[31];
    bool bDemoFreezeValid[31];
    if (LoadFreezeTimes(szMap, szBestDemo, fDemoFreezeTimes, bDemoFreezeValid))
    {
        if (bDemoFreezeValid[iBestRound])
        {
            float fDemoFreeze = fDemoFreezeTimes[iBestRound];
            g_fTeamVerifyDelay[iTeam] = fDemoFreeze - 3.0;
            if (g_fTeamVerifyDelay[iTeam] < 0.1)
                g_fTeamVerifyDelay[iTeam] = 0.1;
        }
        else
        {
            g_fTeamVerifyDelay[iTeam] = 7.0;
        }
    }
    else
    {
        g_fTeamVerifyDelay[iTeam] = 7.0;
    }
    
    // 清理旧的分配列表
    if (g_hAssignedRecsForTeam[iTeam] != null)
        delete g_hAssignedRecsForTeam[iTeam];
    g_hAssignedRecsForTeam[iTeam] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    
    // 重新加载最佳回合的数据并分配
    JSONObject jBestPurchaseData = LoadPurchaseDataForDemo(szMap, szBestDemo);
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iBestRound + 1);
    JSONObject jBestRound = view_as<JSONObject>(jBestPurchaseData.Get(szRoundKey));
    JSONObject jBestTeam = view_as<JSONObject>(jBestRound.Get(szTeamName));
    
    ArrayList hBestRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, szTeamName);
    ArrayList hBestRecInfoList = BuildRecEquipmentInfo(hBestRecFiles, jBestTeam, iTeam);
    
    // 给每个Bot分配REC
    for (int b = 0; b < iBotCount; b++)
    {
        int client = hTeamBots.Get(b);
        int recIndex = bestAssignment[b];
        
        if (recIndex >= 0 && recIndex < hBestRecInfoList.Length)
        {
            RecEquipmentInfo recInfo;
            hBestRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            g_hAssignedRecsForTeam[iTeam].PushString(recInfo.recName);
            
            // 保存到bot专属变量
            strcopy(g_szAssignedRecName[client], PLATFORM_MAX_PATH, recInfo.recName);
            strcopy(g_szBotRecFolder[client], PLATFORM_MAX_PATH, szBestDemo);
        }
        else
        {
            // 清空未分配bot的数据
            g_szAssignedRecName[client][0] = '\0';
            g_szBotRecFolder[client][0] = '\0';
        }
    }
    
    // 清理资源
    delete hBestRecInfoList;
    delete hBestRecFiles;
    delete jBestTeam;
    delete jBestRound;
    delete jBestPurchaseData;
    delete hTeamBots;
}

// ============================================================================
// 经济模式 - 双队回合选择
// ============================================================================

int SelectRoundByBothTeamsEconomy()
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    // 收集两个阵营的所有bot
    ArrayList hTBots = new ArrayList();
    ArrayList hCTBots = new ArrayList();
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        int iTeam = GetClientTeam(i);
        if (iTeam == CS_TEAM_T)
            hTBots.Push(i);
        else if (iTeam == CS_TEAM_CT)
            hCTBots.Push(i);
    }
    
    // 按经济排序
    SortADTArrayCustom(hTBots, Sort_BotsByMoney);
    SortADTArrayCustom(hCTBots, Sort_BotsByMoney);
    
    int iTBotCount = hTBots.Length;
    int iCTBotCount = hCTBots.Length;
    
    if (iTBotCount == 0 && iCTBotCount == 0)
    {
        delete hTBots;
        delete hCTBots;
        return g_iCurrentRound;
    }
    
    // 判断当前是否手枪局
    bool bCurrentIsPistol = IsCurrentRoundPistol();
    
    // 确定T队的经济需求类型
    EconomyDemandType tDemandType = Demand_FullForce;
    if (!bCurrentIsPistol && iTBotCount > 0)
    {
        bool bTAllLowEconomy = true;
        for (int b = 0; b < iTBotCount; b++)
        {
            int client = hTBots.Get(b);
            int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
            if (clientMoney > 3000)
            {
                bTAllLowEconomy = false;
                break;
            }
        }
        
        if (bTAllLowEconomy)
        {
            int iRandom = GetRandomInt(1, 100);
            if (iRandom <= 55)
                tDemandType = Demand_Eco;
            else if (iRandom <= 80)
                tDemandType = Demand_SemiForce;
            else
                tDemandType = Demand_FullForce;
        }
    }
    
    // 确定CT队的经济需求类型
    EconomyDemandType ctDemandType = Demand_FullForce;
    if (!bCurrentIsPistol && iCTBotCount > 0)
    {
        bool bCTAllLowEconomy = true;
        for (int b = 0; b < iCTBotCount; b++)
        {
            int client = hCTBots.Get(b);
            int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
            if (clientMoney > 3000)
            {
                bCTAllLowEconomy = false;
                break;
            }
        }
        
        if (bCTAllLowEconomy)
        {
            int iRandom = GetRandomInt(1, 100);
            if (iRandom <= 55)
                ctDemandType = Demand_Eco;
            else if (iRandom <= 80)
                ctDemandType = Demand_SemiForce;
            else
                ctDemandType = Demand_FullForce;
        }
    }
    
    // 获取所有demo文件夹
    char szMapBasePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/%s/%s", szMap);
    
    if (!DirExists(szMapBasePath))
    {
        delete hTBots;
        delete hCTBots;
        return g_iCurrentRound;
    }
    
    ArrayList hDemoFolders = new ArrayList(PLATFORM_MAX_PATH);
    DirectoryListing hMapDir = OpenDirectory(szMapBasePath);
    if (hMapDir != null)
    {
        char szFolderName[PLATFORM_MAX_PATH];
        FileType iFileType;
        
        while (hMapDir.GetNext(szFolderName, sizeof(szFolderName), iFileType))
        {
            if (iFileType == FileType_Directory && strcmp(szFolderName, ".") != 0 && strcmp(szFolderName, "..") != 0)
            {
                hDemoFolders.PushString(szFolderName);
            }
        }
        delete hMapDir;
    }
    
    // 收集所有可行回合
    ArrayList hTSatisfiedRounds = new ArrayList(sizeof(RoundCandidate));
    ArrayList hCTSatisfiedRounds = new ArrayList(sizeof(RoundCandidate));
    
    // 遍历所有demo和回合
    for (int d = 0; d < hDemoFolders.Length; d++)
    {
        char szDemoFolder[PLATFORM_MAX_PATH];
        hDemoFolders.GetString(d, szDemoFolder, sizeof(szDemoFolder));
        
        // 加载freeze时间
        float fDemoFreezeTimes[31];
        bool bDemoFreezeValid[31];
        LoadFreezeTimes(szMap, szDemoFolder, fDemoFreezeTimes, bDemoFreezeValid);
        
        // 加载购买数据
        JSONObject jDemoPurchaseData = LoadPurchaseDataForDemo(szMap, szDemoFolder);
        if (jDemoPurchaseData == null)
            continue;
        
        // 扫描该demo的所有回合
        for (int iRound = 0; iRound <= 30; iRound++)
        {
            if (!bDemoFreezeValid[iRound])
                continue;
            
            // 手枪局匹配检查
            bool bRoundIsPistol = IsPistolRound(iRound);
            if (bCurrentIsPistol != bRoundIsPistol)
                continue;
            
            char szRoundKey[32];
            Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
            
            if (!jDemoPurchaseData.HasKey(szRoundKey))
                continue;
            
            JSONObject jRound = view_as<JSONObject>(jDemoPurchaseData.Get(szRoundKey));
            
            // 检查T队 - 只要能分配就加入候选
            if (iTBotCount > 0 && jRound.HasKey("T"))
            {
                JSONObject jTeamT = view_as<JSONObject>(jRound.Get("T"));
                ArrayList hTRecFiles = GetRecFilesForRound(szMap, szDemoFolder, iRound, "T");
                ArrayList hTRecInfoList = null;
                
                if (hTRecFiles.Length >= iTBotCount)
                {
                    hTRecInfoList = BuildRecEquipmentInfo(hTRecFiles, jTeamT, CS_TEAM_T);
                    
                    if (hTRecInfoList != null && hTRecInfoList.Length >= iTBotCount)
                    {
                        int tempTAssignment[MAXPLAYERS+1];
                        for (int i = 0; i <= MAXPLAYERS; i++)
                            tempTAssignment[i] = -1;
                        
                        int iTTotalValue = 0;
                        int iTTotalCost = 0;
                        bool bTAssigned = TryAssignRecsToTeamWithCost(hTBots, hTRecInfoList, 
                                                                       tempTAssignment, 
                                                                       iTTotalValue, 
                                                                       iTTotalCost);
                        
                        if (bTAssigned)
                        {
                            RoundCandidate candidate;
                            candidate.round = iRound;
                            strcopy(candidate.demoFolder, PLATFORM_MAX_PATH, szDemoFolder);
                            
                            if (tDemandType == Demand_Eco)
                                candidate.totalValue = -iTTotalCost;
                            else if (tDemandType == Demand_SemiForce)
                            {
                                int iTargetCost = iTBotCount * 1750;
                                int iDeviation = (iTTotalCost - iTargetCost);
                                if (iDeviation < 0) iDeviation = -iDeviation;
                                candidate.totalValue = -iDeviation;
                            }
                            else
                                candidate.totalValue = iTTotalValue;
                            
                            candidate.freezeTime = fDemoFreezeTimes[iRound];
                            
                            for (int i = 0; i < iTBotCount; i++)
                                candidate.assignment[i] = tempTAssignment[i];
                            
                            hTSatisfiedRounds.PushArray(candidate, sizeof(RoundCandidate));
                        }
                    }
                }
                
                // 统一清理，无论执行了哪个分支
                if (hTRecInfoList != null)
                    delete hTRecInfoList;
                delete hTRecFiles;
                delete jTeamT;
            }
            
            // 检查CT队 - 只要能分配就加入候选
            if (iCTBotCount > 0 && jRound.HasKey("CT"))
            {
                JSONObject jTeamCT = view_as<JSONObject>(jRound.Get("CT"));
                ArrayList hCTRecFiles = GetRecFilesForRound(szMap, szDemoFolder, iRound, "CT");
                ArrayList hCTRecInfoList = null;
                
                if (hCTRecFiles.Length >= iCTBotCount)
                {
                    hCTRecInfoList = BuildRecEquipmentInfo(hCTRecFiles, jTeamCT, CS_TEAM_CT);
                    
                    if (hCTRecInfoList != null && hCTRecInfoList.Length >= iCTBotCount)
                    {
                        int tempCTAssignment[MAXPLAYERS+1];
                        for (int i = 0; i <= MAXPLAYERS; i++)
                            tempCTAssignment[i] = -1;
                        
                        int iCTTotalValue = 0;
                        int iCTTotalCost = 0;
                        bool bCTAssigned = TryAssignRecsToTeamWithCost(hCTBots, hCTRecInfoList, 
                                                                        tempCTAssignment, 
                                                                        iCTTotalValue, 
                                                                        iCTTotalCost);
                        
                        if (bCTAssigned)
                        {
                            RoundCandidate candidate;
                            candidate.round = iRound;
                            strcopy(candidate.demoFolder, PLATFORM_MAX_PATH, szDemoFolder);
                            
                            if (ctDemandType == Demand_Eco)
                                candidate.totalValue = -iCTTotalCost;
                            else if (ctDemandType == Demand_SemiForce)
                            {
                                int iTargetCost = iCTBotCount * 1750;
                                int iDeviation = (iCTTotalCost - iTargetCost);
                                if (iDeviation < 0) iDeviation = -iDeviation;
                                candidate.totalValue = -iDeviation;
                            }
                            else
                                candidate.totalValue = iCTTotalValue;
                            
                            candidate.freezeTime = fDemoFreezeTimes[iRound];
                            
                            for (int i = 0; i < iCTBotCount; i++)
                                candidate.assignment[i] = tempCTAssignment[i];
                            
                            hCTSatisfiedRounds.PushArray(candidate, sizeof(RoundCandidate));
                        }
                    }
                }
                
                if (hCTRecInfoList != null)
                    delete hCTRecInfoList;
                delete hCTRecFiles;
                delete jTeamCT;
            }
            
            delete jRound;
        }
        
        delete jDemoPurchaseData;
    }
    
    delete hDemoFolders;
    
    // 选择两边都相对满意的回合 
    int iBestRound = -1;
    char szBestDemo[PLATFORM_MAX_PATH];
    float fBestSatisfaction = -999999.0; 
    int bestTAssignment[MAXPLAYERS+1];
    int bestCTAssignment[MAXPLAYERS+1];
    
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        bestTAssignment[i] = -1;
        bestCTAssignment[i] = -1;
    }
    
    // 计算每队的理论最大分数
    int iTMaxPossibleScore = -999999;
    int iCTMaxPossibleScore = -999999;
    
    for (int t = 0; t < hTSatisfiedRounds.Length; t++)
    {
        RoundCandidate tCandidate;
        hTSatisfiedRounds.GetArray(t, tCandidate, sizeof(RoundCandidate));
        if (tCandidate.totalValue > iTMaxPossibleScore)
            iTMaxPossibleScore = tCandidate.totalValue;
    }
    
    for (int ct = 0; ct < hCTSatisfiedRounds.Length; ct++)
    {
        RoundCandidate ctCandidate;
        hCTSatisfiedRounds.GetArray(ct, ctCandidate, sizeof(RoundCandidate));
        if (ctCandidate.totalValue > iCTMaxPossibleScore)
            iCTMaxPossibleScore = ctCandidate.totalValue;
    }
    
    // 计算每队的理论最小分数
    int iTMinPossibleScore = 999999;
    int iCTMinPossibleScore = 999999;
    
    for (int t = 0; t < hTSatisfiedRounds.Length; t++)
    {
        RoundCandidate tCandidate;
        hTSatisfiedRounds.GetArray(t, tCandidate, sizeof(RoundCandidate));
        if (tCandidate.totalValue < iTMinPossibleScore)
            iTMinPossibleScore = tCandidate.totalValue;
    }
    
    for (int ct = 0; ct < hCTSatisfiedRounds.Length; ct++)
    {
        RoundCandidate ctCandidate;
        hCTSatisfiedRounds.GetArray(ct, ctCandidate, sizeof(RoundCandidate));
        if (ctCandidate.totalValue < iCTMinPossibleScore)
            iCTMinPossibleScore = ctCandidate.totalValue;
    }
    
    // 遍历T队回合,寻找CT队也有的回合
    for (int t = 0; t < hTSatisfiedRounds.Length; t++)
    {
        RoundCandidate tCandidate;
        hTSatisfiedRounds.GetArray(t, tCandidate, sizeof(RoundCandidate));
        
        for (int ct = 0; ct < hCTSatisfiedRounds.Length; ct++)
        {
            RoundCandidate ctCandidate;
            hCTSatisfiedRounds.GetArray(ct, ctCandidate, sizeof(RoundCandidate));
            
            // 检查是否为同一回合同一demo
            if (tCandidate.round == ctCandidate.round && 
                StrEqual(tCandidate.demoFolder, ctCandidate.demoFolder, false))
            {
                // 归一化满意度(0.0-1.0)
                float fTSatisfaction = 0.0;
                float fCTSatisfaction = 0.0;
                
                // 归一化T队分数
                if (iTMaxPossibleScore != iTMinPossibleScore)
                {
                    fTSatisfaction = float(tCandidate.totalValue - iTMinPossibleScore) / 
                                    float(iTMaxPossibleScore - iTMinPossibleScore);
                }
                else
                {
                    fTSatisfaction = 1.0;
                }
                
                // 归一化CT队分数
                if (iCTMaxPossibleScore != iCTMinPossibleScore)
                {
                    fCTSatisfaction = float(ctCandidate.totalValue - iCTMinPossibleScore) / 
                                     float(iCTMaxPossibleScore - iCTMinPossibleScore);
                }
                else
                {
                    fCTSatisfaction = 1.0;
                }
                
                // 使用调和平均数作为综合满意度
                float fCombinedSatisfaction = -999999.0;
                if (fTSatisfaction > 0.0 && fCTSatisfaction > 0.0)
                {
                    fCombinedSatisfaction = 2.0 * fTSatisfaction * fCTSatisfaction / 
                                          (fTSatisfaction + fCTSatisfaction);
                }
                
                if (fCombinedSatisfaction > fBestSatisfaction)
                {
                    iBestRound = tCandidate.round;
                    strcopy(szBestDemo, sizeof(szBestDemo), tCandidate.demoFolder);
                    fBestSatisfaction = fCombinedSatisfaction;
                    
                    // 保存两队的分配方案
                    for (int i = 0; i < iTBotCount; i++)
                        bestTAssignment[i] = tCandidate.assignment[i];
                    
                    for (int i = 0; i < iCTBotCount; i++)
                        bestCTAssignment[i] = ctCandidate.assignment[i];
                }
                
                break;
            }
        }
    }
    
    // 清理候选列表
    delete hTSatisfiedRounds;
    delete hCTSatisfiedRounds;
    
    if (iBestRound == -1)
    {
        PrintToServer("[Bot REC] No suitable round found for both teams!");
        delete hTBots;
        delete hCTBots;
        return g_iCurrentRound;
    }
    
    // 应用最终分配
    strcopy(g_szCurrentRecFolder, sizeof(g_szCurrentRecFolder), szBestDemo);
    g_iSelectedRoundForTeam[CS_TEAM_T] = iBestRound;
    g_iSelectedRoundForTeam[CS_TEAM_CT] = iBestRound;
    strcopy(g_szSelectedDemoForTeam[CS_TEAM_T], PLATFORM_MAX_PATH, szBestDemo);
    strcopy(g_szSelectedDemoForTeam[CS_TEAM_CT], PLATFORM_MAX_PATH, szBestDemo);
    
    PrintToServer("[Bot REC] Selected round %d from demo %s (Satisfaction: %.2f)", 
        iBestRound + 1, szBestDemo, fBestSatisfaction);
    
    // 设置验证延迟
    float fDemoFreezeTimes[31];
    bool bDemoFreezeValid[31];
    if (LoadFreezeTimes(szMap, szBestDemo, fDemoFreezeTimes, bDemoFreezeValid))
    {
        if (bDemoFreezeValid[iBestRound])
        {
            float fDemoFreeze = fDemoFreezeTimes[iBestRound];
            float fVerifyDelay = fDemoFreeze - 3.0;
            if (fVerifyDelay < 0.1)
                fVerifyDelay = 0.1;
            
            g_fTeamVerifyDelay[CS_TEAM_T] = fVerifyDelay;
            g_fTeamVerifyDelay[CS_TEAM_CT] = fVerifyDelay;
        }
        else
        {
            g_fTeamVerifyDelay[CS_TEAM_T] = 7.0;
            g_fTeamVerifyDelay[CS_TEAM_CT] = 7.0;
        }
    }
    else
    {
        g_fTeamVerifyDelay[CS_TEAM_T] = 7.0;
        g_fTeamVerifyDelay[CS_TEAM_CT] = 7.0;
    }
    
    // 清理旧分配列表
    if (g_hAssignedRecsForTeam[CS_TEAM_T] != null)
        delete g_hAssignedRecsForTeam[CS_TEAM_T];
    if (g_hAssignedRecsForTeam[CS_TEAM_CT] != null)
        delete g_hAssignedRecsForTeam[CS_TEAM_CT];
    
    g_hAssignedRecsForTeam[CS_TEAM_T] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_hAssignedRecsForTeam[CS_TEAM_CT] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    
    // 重新加载最佳回合的数据
    JSONObject jBestPurchaseData = LoadPurchaseDataForDemo(szMap, szBestDemo);
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iBestRound + 1);
    JSONObject jBestRound = view_as<JSONObject>(jBestPurchaseData.Get(szRoundKey));
    
    // 为T队应用分配
    if (iTBotCount > 0 && jBestRound.HasKey("T"))
    {
        JSONObject jTeamT = view_as<JSONObject>(jBestRound.Get("T"));
        ArrayList hTRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, "T");
        ArrayList hTRecInfoList = BuildRecEquipmentInfo(hTRecFiles, jTeamT, CS_TEAM_T);
        
        // 为T队应用分配
        for (int b = 0; b < iTBotCount; b++)
        {
            int client = hTBots.Get(b);
            int recIndex = bestTAssignment[b];
            
            if (recIndex >= 0 && recIndex < hTRecInfoList.Length)
            {
                RecEquipmentInfo recInfo;
                hTRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
                
                g_hAssignedRecsForTeam[CS_TEAM_T].PushString(recInfo.recName);
                strcopy(g_szAssignedRecName[client], PLATFORM_MAX_PATH, recInfo.recName);
                strcopy(g_szBotRecFolder[client], PLATFORM_MAX_PATH, szBestDemo);
            }
            else
            {
                g_szAssignedRecName[client][0] = '\0';
                g_szBotRecFolder[client][0] = '\0';
            }
        }
        
        delete hTRecInfoList;
        delete hTRecFiles;
        delete jTeamT;
    }
    
    // 为CT队应用分配
    if (iCTBotCount > 0 && jBestRound.HasKey("CT"))
    {
        JSONObject jTeamCT = view_as<JSONObject>(jBestRound.Get("CT"));
        ArrayList hCTRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, "CT");
        ArrayList hCTRecInfoList = BuildRecEquipmentInfo(hCTRecFiles, jTeamCT, CS_TEAM_CT);
        
        for (int b = 0; b < iCTBotCount; b++)
        {
            int client = hCTBots.Get(b);
            int recIndex = bestCTAssignment[b];
            
            if (recIndex >= 0 && recIndex < hCTRecInfoList.Length)
            {
                RecEquipmentInfo recInfo;
                hCTRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
                
                g_hAssignedRecsForTeam[CS_TEAM_CT].PushString(recInfo.recName);
                strcopy(g_szAssignedRecName[client], PLATFORM_MAX_PATH, recInfo.recName);
                strcopy(g_szBotRecFolder[client], PLATFORM_MAX_PATH, szBestDemo);
            }
            else
            {
                g_szAssignedRecName[client][0] = '\0';
                g_szBotRecFolder[client][0] = '\0';
            }
        }
        
        delete hCTRecInfoList;
        delete hCTRecFiles;
        delete jTeamCT;
    }
    
    delete jBestRound;
    delete jBestPurchaseData;
    delete hTBots;
    delete hCTBots;
    
    return iBestRound;
}

// ============================================================================
// 数据加载
// ============================================================================

bool LoadPurchaseDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/%s/%s/%s/purchases.json", szModeBase, szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        return false;
    }
    
    if (g_jPurchaseData != null)
        delete g_jPurchaseData;
    
    g_jPurchaseData = JSONObject.FromFile(szPath);
    if (g_jPurchaseData == null)
    {
        return false;
    }
    
    PrintToServer("[Bot REC] Loaded purchase data from: %s", szPath);
    return true;
}

bool LoadFreezeTimes(const char[] szMap, const char[] szRecFolder, float fFreezeTimes[31], bool bValid[31])
{
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szFreezePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szFreezePath, sizeof(szFreezePath), 
        "data/botmimic/%s/%s/%s/freeze.txt", szModeBase, szMap, szRecFolder);
    
    PrintToServer("[Freeze Loader] Loading freeze times from: %s", szFreezePath);
    
    // 初始化所有回合为无效
    for (int i = 0; i < sizeof(g_bRoundFreezeTimeValid); i++)
    {
        g_bRoundFreezeTimeValid[i] = false;
        g_fValidRoundFreezeTimes[i] = 0.0;
        
        g_bAllRoundFreezeTimeValid[i] = false;
        g_fAllRoundFreezeTimes[i] = 0.0;

        bValid[i] = false;
        fFreezeTimes[i] = 0.0;
    }
    
    g_fStandardFreezeTime = 20.0;
    
    if (!FileExists(szFreezePath))
    {
        PrintToServer("[Freeze Loader] File not found: %s", szFreezePath);
        return false;
    }
    
    File hFile = OpenFile(szFreezePath, "r");
    if (hFile == null)
    {
        return false;
    }
    
    char szLine[128];
    int iValidRoundsForEconomy = 0;
    int iValidRoundsForPause = 0;
    const float TOLERANCE = 2.0;
    
    // 先扫描一遍找标准冻结时间
    while (hFile.ReadLine(szLine, sizeof(szLine)))
    {
        TrimString(szLine);
        
        if (StrContains(szLine, "冻结时间", false) != -1 || 
            StrContains(szLine, "standard", false) != -1 ||
            StrContains(szLine, "freeze", false) != -1)
        {
            char szParts[2][64];
            int iParts = ExplodeString(szLine, ":", szParts, sizeof(szParts), sizeof(szParts[]));
            
            if (iParts >= 2)
            {
                TrimString(szParts[1]);
                ReplaceString(szParts[1], sizeof(szParts[]), "秒", "");
                ReplaceString(szParts[1], sizeof(szParts[]), "s", "", false);
                g_fStandardFreezeTime = StringToFloat(szParts[1]);
            }
            break;
        }
    }
    
    // 重置文件指针到开头
    delete hFile;
    hFile = OpenFile(szFreezePath, "r");
    if (hFile == null)
    {
        return false;
    }
    
    // 第二遍扫描：解析回合数据
    while (hFile.ReadLine(szLine, sizeof(szLine)))
    {
        TrimString(szLine);
        
        // 跳过空行和注释
        if (strlen(szLine) == 0 || szLine[0] == '/' || szLine[0] == '#')
        {
            continue;
        }
        
        // 跳过标准时间定义行
        if (StrContains(szLine, "冻结时间", false) != -1 || 
            StrContains(szLine, "standard", false) != -1 ||
            StrContains(szLine, "freeze", false) != -1)
        {
            continue;
        }
        
        char szParts[2][64];
        int iParts = ExplodeString(szLine, ":", szParts, sizeof(szParts), sizeof(szParts[]));
        
        if (iParts < 2)
        {
            continue;
        }
        
        TrimString(szParts[0]);
        int iRoundNum = -1;
        
        // 解析回合号
        if (StrContains(szParts[0], "round", false) != -1)
        {
            ReplaceString(szParts[0], sizeof(szParts[]), "round", "", false);
            ReplaceString(szParts[0], sizeof(szParts[]), "Round", "", false);
            ReplaceString(szParts[0], sizeof(szParts[]), "ROUND", "", false);
            TrimString(szParts[0]);
            iRoundNum = StringToInt(szParts[0]);
        }
        else
        {
            iRoundNum = StringToInt(szParts[0]);
        }
        
        if (iRoundNum < 1 || iRoundNum > 30)
        {
            continue;
        }
        
        // 解析冻结时间
        TrimString(szParts[1]);
        ReplaceString(szParts[1], sizeof(szParts[]), "秒", "");
        ReplaceString(szParts[1], sizeof(szParts[]), "s", "", false);
        float fFreezeTime = StringToFloat(szParts[1]);
        
        if (fFreezeTime <= 0.0)
        {
            continue;
        }
        
        // 数组索引 = 回合号 - 1
        int iArrayIndex = iRoundNum - 1;
        
        // 暂停系统：无条件加载所有时间
        g_bAllRoundFreezeTimeValid[iArrayIndex] = true;
        g_fAllRoundFreezeTimes[iArrayIndex] = fFreezeTime;
        iValidRoundsForPause++;
        
        // 经济模式：只加载tolerance范围内的时间
        float fDifference = FloatAbs(fFreezeTime - g_fStandardFreezeTime);
        
        if (fDifference <= TOLERANCE)
        {
            g_bRoundFreezeTimeValid[iArrayIndex] = true;
            g_fValidRoundFreezeTimes[iArrayIndex] = fFreezeTime;
            iValidRoundsForEconomy++;
            
            bValid[iArrayIndex] = true;
            fFreezeTimes[iArrayIndex] = fFreezeTime;
        }
    }
    
    delete hFile;
    
    PrintToServer("[Freeze Loader] Loaded %d rounds for pause, %d rounds for economy", 
        iValidRoundsForPause, iValidRoundsForEconomy);
    
    // 全局模式才设置服务器冻结时间
    if (g_iRoundMode == Round_FullMatch && g_iPlaybackMode == Playback_Full && g_fStandardFreezeTime > 0.0)
    {
        ServerCommand("mp_freezetime %.2f", g_fStandardFreezeTime);
        PrintToServer("[Freeze Loader] Set server freeze time to %.2f seconds", g_fStandardFreezeTime);
    }
    
    return (iValidRoundsForPause > 0 || iValidRoundsForEconomy > 0);
}

// 聊天
bool LoadChatDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/%s/%s/%s/chat.json", szModeBase, szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        return false;
    }
    
    if (g_jChatData != null)
        delete g_jChatData;
    
    g_jChatData = view_as<JSONArray>(JSONArray.FromFile(szPath));
    if (g_jChatData == null)
    {
        return false;
    }
    
    PrintToServer("[Bot REC] Loaded chat data from: %s", szPath);
    return true;
}

bool LoadChatActionsForBot(int client, int iRound)
{
    if (IsInWarmup())
    {
        return false;  
    }

    if (g_jChatData == null)
    {
        return false;
    }
    
    // 获取bot的REC名称
    if (g_szCurrentRecName[client][0] == '\0')
    {
        return false;
    }
    
    char szBotRecName[PLATFORM_MAX_PATH];
    strcopy(szBotRecName, sizeof(szBotRecName), g_szCurrentRecName[client]);
    
    if (g_hChatActions[client] != null)
        delete g_hChatActions[client];
    
    g_hChatActions[client] = new ArrayList(ByteCountToCells(256));
    g_iChatActionIndex[client] = 0;
    
    int iChatCount = 0;
    int iTargetRound = iRound + 1;  
    
    // 遍历所有聊天消息
    for (int i = 0; i < g_jChatData.Length; i++)
    {
        JSONObject jMessage = view_as<JSONObject>(g_jChatData.Get(i));
        
        int iMsgRound = jMessage.GetInt("round");
        
        // 只加载当前回合的消息
        if (iMsgRound != iTargetRound)
        {
            delete jMessage;
            continue;
        }
        
        char szPlayerName[MAX_NAME_LENGTH];
        jMessage.GetString("player_name", szPlayerName, sizeof(szPlayerName));
        
        // 检查是否是这个bot的消息
        if (!StrEqual(szPlayerName, szBotRecName, false))
        {
            delete jMessage;
            continue;
        }
        
        // 读取消息数据
        float fTime = jMessage.GetFloat("time");
        char szMessage[256];
        jMessage.GetString("message", szMessage, sizeof(szMessage));
        bool bIsTeamChat = jMessage.GetBool("is_team_chat");
        
        // 构建聊天动作字符串
        char szChatAction[256];
        Format(szChatAction, sizeof(szChatAction), "%.3f|%s|%d", 
            fTime, szMessage, bIsTeamChat ? 1 : 0);
        
        g_hChatActions[client].PushString(szChatAction);
        iChatCount++;
        
        delete jMessage;
    }
    
    return (iChatCount > 0);
}

// ============================================================================
// 购买系统
// ============================================================================

// 拦截bot购买命令
public Action CS_OnBuyCommand(int client, const char[] szWeapon)
{
    if (!IsValidClient(client) || !IsFakeClient(client))
        return Plugin_Continue;

    if (g_bAllowPurchase[client])
    {
        g_bAllowPurchase[client] = false;
        return Plugin_Continue;
    }

    if (g_bPurchaseSystemActive[client])
    {
        return Plugin_Handled;
    }

    if (g_bPlayingRoundStartRec[client])
    {
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}


// 购买优先级排序
public int SortByBuyPriority(int idx1, int idx2, Handle array, Handle hndl)
{
    ArrayList list = view_as<ArrayList>(array);
    
    char item1[128], item2[128];
    list.GetString(idx1, item1, sizeof(item1));
    list.GetString(idx2, item2, sizeof(item2));
    
    char parts1[3][64], parts2[3][64];
    ExplodeString(item1, "|", parts1, 3, 64);
    ExplodeString(item2, "|", parts2, 3, 64);
    
    int priority1 = GetItemBuyPriority(parts1[1]);
    int priority2 = GetItemBuyPriority(parts2[1]);
    
    if (priority1 < priority2) return -1;
    if (priority1 > priority2) return 1;
    
    return 0;
}

// PreGame模式加载购买动作
bool LoadPreGamePurchaseList(int client, int iRound)
{
    if (IsInWarmup())
        return false;

    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    JSONObject jUsePurchaseData = null;
    
    if (g_szBotRecFolder[client][0] != '\0')
    {
        jUsePurchaseData = LoadPurchaseDataForDemo(szMap, g_szBotRecFolder[client]);
    }
    
    if (jUsePurchaseData == null)
        jUsePurchaseData = g_jPurchaseData;
    
    if (jUsePurchaseData == null)
        return false;
    
    int iClientTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iClientTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iClientTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
    
    if (!jUsePurchaseData.HasKey(szRoundKey))
    {
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    JSONObject jRound = view_as<JSONObject>(jUsePurchaseData.Get(szRoundKey));
    if (jRound == null || !jRound.HasKey(szTeamName))
    {
        if (jRound != null) delete jRound;
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
    if (jTeam == null)
    {
        delete jRound;
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    if (g_szCurrentRecName[client][0] == '\0')
    {
        delete jTeam;
        delete jRound;
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    if (!jTeam.HasKey(g_szCurrentRecName[client]))
    {
        delete jTeam;
        delete jRound;
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    // 读取物品数组
    JSONArray jItems = view_as<JSONArray>(jTeam.Get(g_szCurrentRecName[client]));
    if (jItems == null)
    {
        delete jTeam;
        delete jRound;
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    // 清理旧数据
    if (g_hPurchaseActions[client] != null)
        delete g_hPurchaseActions[client];
    
    g_hPurchaseActions[client] = new ArrayList(ByteCountToCells(128));
    g_iPurchaseActionIndex[client] = 0;
    g_bInitialInventoryApplied[client] = false;
    
    int iItemCount = jItems.Length;
    if (iItemCount == 0)
    {
        delete jItems;
        delete jTeam;
        delete jRound;
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        return false;
    }
    
    // 获取冻结时间
    ConVar cvFreezeTime = FindConVar("mp_freezetime");
    float fFreezeTime = (cvFreezeTime != null) ? cvFreezeTime.FloatValue : 15.0;
    
    // 购买总时间
    float fTotalBuyTime = float(iItemCount) * 0.2;
    
    // 随机选择开始时间，确保能在冻结时间内完成
    float fMaxStartTime = fFreezeTime - fTotalBuyTime - 0.5; // 预留0.5秒
    if (fMaxStartTime < 0.1)
        fMaxStartTime = 0.1;
    
    float fStartTime = GetRandomFloat(0.1, fMaxStartTime);
    
    // 生成购买序列
    int iClientTeamInt = GetClientTeam(client);
    for (int i = 0; i < iItemCount; i++)
    {
        char szItem[64];
        jItems.GetString(i, szItem, sizeof(szItem));
        
        if (IsDefaultPistol(szItem))
            continue;
        
        // 转换阵营武器
        char szBuyItem[64];
        GetTeamSpecificWeapon(szItem, iClientTeamInt, szBuyItem, sizeof(szBuyItem));
        
        // 计算这个物品的购买时间
        float fBuyTime = fStartTime + (float(i) * 0.2);
        
        // 构建购买动作字符串
        char szActionStr[128];
        Format(szActionStr, sizeof(szActionStr), "%.1f|%s|unknown", fBuyTime, szBuyItem);
        g_hPurchaseActions[client].PushString(szActionStr);
    }
    
    if (g_hPurchaseActions[client].Length > 0)
    {
        g_hPurchaseActions[client].SortCustom(SortByBuyPriority);
        
        // 重新分配购买时间
        for (int i = 0; i < g_hPurchaseActions[client].Length; i++)
        {
            char szAction[128];
            g_hPurchaseActions[client].GetString(i, szAction, sizeof(szAction));
            
            char szParts[3][64];
            ExplodeString(szAction, "|", szParts, 3, 64);
            
            // 更新时间
            float fNewTime = fStartTime + (float(i) * 0.2);
            Format(szAction, sizeof(szAction), "%.1f|%s|%s", fNewTime, szParts[1], szParts[2]);
            g_hPurchaseActions[client].SetString(i, szAction);
        }
    }
    
    delete jItems;
    delete jTeam;
    delete jRound;
    if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
        delete jUsePurchaseData;
    
    return true;
}

// 普通模式加载购买动作
bool LoadPurchaseActionsForBot(int client, int iRound)
{
    if (IsInWarmup())
    {
        return false;  
    }

    // 加载bot专属demo的购买数据
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    JSONObject jUsePurchaseData = null;
    
    // 如果bot有专属demo，加载专属demo的购买数据
    if (g_szBotRecFolder[client][0] != '\0')
    {
        jUsePurchaseData = LoadPurchaseDataForDemo(szMap, g_szBotRecFolder[client]);
    }
    
    // 如果没有专属数据，使用全局数据
    if (jUsePurchaseData == null)
    {
        jUsePurchaseData = g_jPurchaseData;
    }
    
    if (jUsePurchaseData == null)
    {
        return false;
    }
    
    // 获取队伍信息
    int iClientTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iClientTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iClientTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    // 构建回合键
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
    
    // 使用正确的数据源
    if (!jUsePurchaseData.HasKey(szRoundKey))
    {
        // 清理临时数据
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    JSONObject jRound = view_as<JSONObject>(jUsePurchaseData.Get(szRoundKey));
    if (jRound == null || !jRound.HasKey(szTeamName))
    {
        if (jRound != null)
            delete jRound;
        
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
    if (jTeam == null)
    {
        delete jRound;
        
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    // 使用rec文件名作为bot的键
    if (g_szCurrentRecName[client][0] == '\0')
    {
        delete jTeam;
        delete jRound;
        
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    if (!jTeam.HasKey(g_szCurrentRecName[client]))
    {
        delete jTeam;
        delete jRound;
        
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    JSONObject jBotData = view_as<JSONObject>(jTeam.Get(g_szCurrentRecName[client]));
    if (jBotData == null)
    {
        delete jTeam;
        delete jRound;
        
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    // 清理旧数据
    if (g_hPurchaseActions[client] != null)
        delete g_hPurchaseActions[client];
    if (g_hInitialInventory[client] != null)
        delete g_hInitialInventory[client];
    
    g_hPurchaseActions[client] = new ArrayList(ByteCountToCells(128));
    g_hInitialInventory[client] = new ArrayList(ByteCountToCells(64));
    g_iPurchaseActionIndex[client] = 0;
    g_bInitialInventoryApplied[client] = false;

    int iPurchaseCount = 0;
    
    // 加载初始装备
    int iInitialCount = 0;
    if (jBotData.HasKey("initial_inventory"))
    {
        JSONArray jInitial = view_as<JSONArray>(jBotData.Get("initial_inventory"));
        
        for (int i = 0; i < jInitial.Length; i++)
        {
            char szItem[64];
            jInitial.GetString(i, szItem, sizeof(szItem));
            g_hInitialInventory[client].PushString(szItem);
            
            iInitialCount++;
        }
        
        delete jInitial;
    }
    
    // 加载购买动作和丢弃动作
    if (jBotData.HasKey("purchases"))
    {
        JSONArray jPurchases = view_as<JSONArray>(jBotData.Get("purchases"));
        
        for (int i = 0; i < jPurchases.Length; i++)
        {
            JSONObject jAction = view_as<JSONObject>(jPurchases.Get(i));
    
            char szAction[32];
            jAction.GetString("action", szAction, sizeof(szAction));
            
            if (StrEqual(szAction, "purchased", false))
            {
                float fTime = jAction.GetFloat("time");
                char szItem[64], szSlot[32];
                jAction.GetString("item", szItem, sizeof(szItem));
                jAction.GetString("slot", szSlot, sizeof(szSlot));
                
                if (IsDefaultPistol(szItem))
                {
                    delete jAction;
                    continue;
                }
                
                char szActionStr[128];
                Format(szActionStr, sizeof(szActionStr), "%.1f|%s|%s", fTime, szItem, szSlot);
                g_hPurchaseActions[client].PushString(szActionStr);
                
                iPurchaseCount++;
            }
    
            delete jAction;
        }
        
        delete jPurchases;
    }
    
    // 设置初始装备应用定时器
    ConVar cvFreezeTime = FindConVar("mp_freezetime");
    if (cvFreezeTime != null)
    {
        // 如果有初始装备需要应用
        if (g_hInitialInventory[client].Length > 0)
        {
            // 找到purchases中第一个动作的时间和第一个丢弃时间
            float fFirstActionTime = 9999.0;
            float fFirstDropTime = 9999.0;
            
            if (jBotData.HasKey("purchases"))
            {
                JSONArray jPurchases = view_as<JSONArray>(jBotData.Get("purchases"));
                
                for (int i = 0; i < jPurchases.Length; i++)
                {
                    JSONObject jAction = view_as<JSONObject>(jPurchases.Get(i));
                    
                    float fTime = jAction.GetFloat("time");
                    char szAction[32];
                    jAction.GetString("action", szAction, sizeof(szAction));
                    
                    if (StrEqual(szAction, "purchased", false) || StrEqual(szAction, "dropped", false))
                    {
                        if (fTime < fFirstActionTime)
                            fFirstActionTime = fTime;
                        
                        if (StrEqual(szAction, "dropped", false) && fTime < fFirstDropTime)
                            fFirstDropTime = fTime;
                    }
                    
                    delete jAction;
                }
                
                delete jPurchases;
            }
            
            // 计算需要的时间
            float fNeededTime = g_hInitialInventory[client].Length * 0.2;
            
            // 决定截止时间
            float fDeadline;
            if (fFirstDropTime < 9999.0)
            {
                // 如果有丢弃行为,必须在丢弃时间2秒前完成
                fDeadline = fFirstDropTime - 2.0;
            }
            else
            {
                // 没有丢弃行为,在第一个动作前0.5秒完成即可
                fDeadline = fFirstActionTime - 0.5;
            }
            
            float fStartTime = fDeadline - fNeededTime;
            
            // 计算购买间隔
            float fBuyInterval = 0.2;
            
            if (fStartTime < 0.1)
            {
                fStartTime = 0.1;  
                
                if (fDeadline > fStartTime)
                {
                    fBuyInterval = (fDeadline - fStartTime) / g_hInitialInventory[client].Length;
                    if (fBuyInterval < 0.05)
                        fBuyInterval = 0.05; 
                }
                else
                {
                    fBuyInterval = 0.05;
                }
            }
            
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            pack.WriteFloat(fBuyInterval);  
            CreateTimer(fStartTime, Timer_ApplyInitialInventory, pack);
        }
    }
    
    delete jBotData;
    delete jTeam;
    delete jRound;
    
    if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
    {
        delete jUsePurchaseData;
    }
    
    return true;
}

// 执行购买动作的定时器
public Action Timer_ExecutePurchaseAction(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    int client = GetClientOfUserId(iUserId);
    if (client <= 0 || client > MaxClients)
    {
        delete pack;
        return Plugin_Stop;
    }
    
    if (!IsValidClient(client) || !IsPlayerAlive(client) || !IsFakeClient(client))
    {
        g_hPurchaseTimer[client] = null;
        g_bPurchaseSystemActive[client] = false; 
        delete pack;
        return Plugin_Stop;
    }
    
    if (!g_bPurchaseSystemActive[client])
    {
        g_hPurchaseTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    if (g_hPurchaseActions[client] == null)
    {
        g_hPurchaseTimer[client] = null;
        g_bPurchaseSystemActive[client] = false; 
        delete pack;
        return Plugin_Stop;
    }
    
    bool bInBuyZone = !!GetEntProp(client, Prop_Send, "m_bInBuyZone");
    if (!bInBuyZone)
        return Plugin_Continue;
    
    float fCurrentTime;
    if (g_iPlaybackMode == Playback_PreGame)
    {
        fCurrentTime = GetGameTime() - GetRoundStartTime();
    }
    else
    {
        fCurrentTime = GetGameTime() - g_fRecStartTime[client];
    }
    
    while (g_iPurchaseActionIndex[client] < g_hPurchaseActions[client].Length)
    {
        char szAction[128];
        g_hPurchaseActions[client].GetString(g_iPurchaseActionIndex[client], szAction, sizeof(szAction));
        
        char szParts[3][64];
        int iParts = ExplodeString(szAction, "|", szParts, sizeof(szParts), sizeof(szParts[]));
        
        if (iParts < 3)
        {
            g_iPurchaseActionIndex[client]++;
            continue;
        }
        
        float fActionTime = StringToFloat(szParts[0]);
        
        if (fCurrentTime < fActionTime)
            break;
        
        char szOriginalItem[64], szSlot[32];
        strcopy(szOriginalItem, sizeof(szOriginalItem), szParts[1]);
        strcopy(szSlot, sizeof(szSlot), szParts[2]);
        
        if (g_iPlaybackMode != Playback_PreGame && ShouldSkipPurchase(client, szOriginalItem))
        {
            g_iPurchaseActionIndex[client]++;
            continue;
        }
        
        char szBuyItem[64];
        int iClientTeam = GetClientTeam(client);
        bool bNeedConvert = GetTeamSpecificWeapon(szOriginalItem, iClientTeam, szBuyItem, sizeof(szBuyItem));
        
        if (!bNeedConvert)
        {
            strcopy(szBuyItem, sizeof(szBuyItem), szOriginalItem);
        }
        
        g_bAllowPurchase[client] = true;
        
        FakeClientCommand(client, "buy %s", szBuyItem);
        
        CreateTimer(0.05, Timer_ResetPurchaseFlag, GetClientUserId(client));
        
        g_iPurchaseActionIndex[client]++;
        
        break;
    }
    
    if (g_iPurchaseActionIndex[client] >= g_hPurchaseActions[client].Length)
    {
        g_hPurchaseTimer[client] = null;
        g_bPurchaseSystemActive[client] = false; 
        delete pack;
        return Plugin_Stop;
    }
    
    return Plugin_Continue;
}

// 应用初始装备的定时器
public Action Timer_ApplyInitialInventory(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    float fBuyInterval = pack.ReadFloat();  
    delete pack;
    
    int client = GetClientOfUserId(iUserId);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client) || !IsFakeClient(client))
        return Plugin_Stop;
    
    if (g_bInitialInventoryApplied[client])
        return Plugin_Stop;
    
    if (g_hInitialInventory[client] == null || g_hInitialInventory[client].Length == 0)
        return Plugin_Stop;
    
    bool bInBuyZone = !!GetEntProp(client, Prop_Send, "m_bInBuyZone");
    if (!bInBuyZone)
        return Plugin_Stop;
    
    int iClientTeam = GetClientTeam(client);
    
    ArrayList hCurrentInventory = new ArrayList(ByteCountToCells(64));
    CollectCurrentInventory(client, hCurrentInventory);
    
    ArrayList hMissingItems = new ArrayList(ByteCountToCells(64));
    
    for (int i = 0; i < g_hInitialInventory[client].Length; i++)
    {
        char szRequiredItem[64];
        g_hInitialInventory[client].GetString(i, szRequiredItem, sizeof(szRequiredItem));
        
        if (IsDefaultPistol(szRequiredItem))
            continue;

        bool bHasItem = IsItemInInventory(hCurrentInventory, szRequiredItem);
        
        if (!bHasItem)
        {
            char szBuyItem[64];
            GetTeamSpecificWeapon(szRequiredItem, iClientTeam, szBuyItem, sizeof(szBuyItem));
            
            hMissingItems.PushString(szBuyItem);
        }
    }
    
    delete hCurrentInventory;
    
    // 如果没有缺少的装备
    if (hMissingItems.Length == 0)
    {
        delete hMissingItems;
        g_bInitialInventoryApplied[client] = true;
        return Plugin_Stop;
    }
    
    // 开始购买缺少的装备
    DataPack buyPack = new DataPack();
    buyPack.WriteCell(GetClientUserId(client));
    buyPack.WriteCell(hMissingItems);  
    buyPack.WriteCell(0); 
    buyPack.WriteFloat(fBuyInterval);  
    
    CreateTimer(0.1, Timer_BuyInitialItems, buyPack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    
    g_bInitialInventoryApplied[client] = true;
    
    return Plugin_Stop;
}

public Action Timer_BuyInitialItems(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    ArrayList hMissingItems = pack.ReadCell();
    int iCurrentIndex = pack.ReadCell();
    float fBuyInterval = pack.ReadFloat();  // 读取购买间隔
    
    int client = GetClientOfUserId(iUserId);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client))
    {
        delete hMissingItems;
        delete pack;
        return Plugin_Stop;
    }
    
    bool bInBuyZone = !!GetEntProp(client, Prop_Send, "m_bInBuyZone");
    if (!bInBuyZone)
    {
        delete hMissingItems;
        delete pack;
        return Plugin_Stop;
    }
    
    // 如果已经买完所有物品
    if (iCurrentIndex >= hMissingItems.Length)
    {
        delete hMissingItems;
        delete pack;
        return Plugin_Stop;
    }
    
    // 购买当前物品
    char szItem[64];
    hMissingItems.GetString(iCurrentIndex, szItem, sizeof(szItem));
    
    g_bAllowPurchase[client] = true;
    FakeClientCommand(client, "buy %s", szItem);
    CreateTimer(0.05, Timer_ResetPurchaseFlag, GetClientUserId(client));
    
    pack.Reset();
    pack.WriteCell(iUserId);
    pack.WriteCell(hMissingItems);
    pack.WriteCell(iCurrentIndex + 1);
    pack.WriteFloat(fBuyInterval);
    
    return Plugin_Continue;
}

public Action Timer_ResetPurchaseFlag(Handle hTimer, any iUserId)
{
    int client = GetClientOfUserId(iUserId);
    if (IsValidClient(client))
        g_bAllowPurchase[client] = false;
    
    return Plugin_Stop;
}

// 聊天计时器
public Action Timer_ExecuteChatAction(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    int client = GetClientOfUserId(iUserId);
    if (client <= 0 || client > MaxClients)
    {
        delete pack;
        return Plugin_Stop;
    }
    
    if (!IsValidClient(client))
    {
        g_hChatTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    // 热身期间停止聊天timer
    if (IsInWarmup())
    {
        g_hChatTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    if (!g_bPlayingRoundStartRec[client])
    {
        g_hChatTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    if (g_hChatActions[client] == null)
    {
        g_hChatTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    if (!IsPlayerAlive(client))
        return Plugin_Continue;
    
    float fCurrentTime = GetGameTime() - g_fRecStartTime[client];
    
    while (g_iChatActionIndex[client] < g_hChatActions[client].Length)
    {
        char szAction[256];
        g_hChatActions[client].GetString(g_iChatActionIndex[client], szAction, sizeof(szAction));
        
        char szParts[3][256];
        int iParts = ExplodeString(szAction, "|", szParts, sizeof(szParts), sizeof(szParts[]));
        
        if (iParts < 3)
        {
            g_iChatActionIndex[client]++;
            continue;
        }
        
        float fActionTime = StringToFloat(szParts[0]);
        
        if (fCurrentTime < fActionTime)
            break;
        
        char szMessage[256];
        strcopy(szMessage, sizeof(szMessage), szParts[1]);
        bool bIsTeamChat = (StringToInt(szParts[2]) == 1);
        
        if (bIsTeamChat)
        {
            FakeClientCommand(client, "say_team %s", szMessage);
        }
        else
        {
            FakeClientCommand(client, "say %s", szMessage);
        }
        
        g_iChatActionIndex[client]++;
    }
    
    if (g_iChatActionIndex[client] >= g_hChatActions[client].Length)
    {
        g_hChatTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    return Plugin_Continue;
}

// ============================================================================
// 带包检测和枪枪系统
// ============================================================================

// 检查带包T是否在播放REC
public Action Timer_CheckBombCarrier(Handle hTimer)
{
    g_hBombCarrierCheckTimer = null;
    
    int iBombCarrier = -1;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        int iC4 = GetPlayerWeaponSlot(i, CS_SLOT_C4);
        if (IsValidEntity(iC4))
        {
            char szClass[64];
            GetEntityClassname(iC4, szClass, sizeof(szClass));
            
            if (StrEqual(szClass, "weapon_c4", false))
            {
                iBombCarrier = i;
                break;
            }
        }
    }
    
    if (iBombCarrier == -1)
    {
        return Plugin_Stop;
    }
    
    if (g_bPlayingRoundStartRec[iBombCarrier] && BotMimic_IsPlayerMimicing(iBombCarrier))
    {
        BotMimic_StopPlayerMimic(iBombCarrier);
        g_bPlayingRoundStartRec[iBombCarrier] = false;
    }
    
    return Plugin_Stop;
}

// 收集当前装备
void CollectCurrentInventory(int client, ArrayList hInventory)
{
    int iPrimary = GetPlayerWeaponSlot(client, CS_SLOT_PRIMARY);
    if (IsValidEntity(iPrimary))
    {
        char szClass[64];
        GetEntityClassname(iPrimary, szClass, sizeof(szClass));
        ReplaceString(szClass, sizeof(szClass), "weapon_", "");
        hInventory.PushString(szClass);
    }
    
    int iSecondary = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
    if (IsValidEntity(iSecondary))
    {
        char szClass[64];
        GetEntityClassname(iSecondary, szClass, sizeof(szClass));
        ReplaceString(szClass, sizeof(szClass), "weapon_", "");
        hInventory.PushString(szClass);
    }
    
    for (int slot = CS_SLOT_GRENADE; slot <= CS_SLOT_C4; slot++)
    {
        int iWeapon = GetPlayerWeaponSlot(client, slot);
        if (IsValidEntity(iWeapon))
        {
            char szClass[64];
            GetEntityClassname(iWeapon, szClass, sizeof(szClass));
            ReplaceString(szClass, sizeof(szClass), "weapon_", "");
            hInventory.PushString(szClass);
        }
    }
    
    int iArmor = GetEntProp(client, Prop_Send, "m_ArmorValue");
    bool bHasHelmet = !!GetEntProp(client, Prop_Send, "m_bHasHelmet");
    
    if (iArmor > 0)
    {
        if (bHasHelmet)
            hInventory.PushString("vesthelm");
        else
            hInventory.PushString("vest");
    }
    
    if (GetClientTeam(client) == CS_TEAM_CT)
    {
        bool bHasDefuser = !!GetEntProp(client, Prop_Send, "m_bHasDefuser");
        if (bHasDefuser)
            hInventory.PushString("defuser");
    }
}

bool IsItemInInventory(ArrayList hInventory, const char[] szItem)
{
    char szNormalizedItem[64], szCheckItem[64];
    NormalizeItemName(szItem, szNormalizedItem, sizeof(szNormalizedItem));
    
    for (int i = 0; i < hInventory.Length; i++)
    {
        hInventory.GetString(i, szCheckItem, sizeof(szCheckItem));
        NormalizeItemName(szCheckItem, szCheckItem, sizeof(szCheckItem));
        
        if (StrEqual(szNormalizedItem, szCheckItem, false))
            return true;
    }
    
    return false;
}

void NormalizeItemName(const char[] szItem, char[] szOutput, int iMaxLen)
{
    strcopy(szOutput, iMaxLen, szItem);
    
    if (StrEqual(szItem, "m4a1_silencer", false))
        strcopy(szOutput, iMaxLen, "m4a1_silencer");
    else if (StrEqual(szItem, "usp_silencer", false))
        strcopy(szOutput, iMaxLen, "usp_silencer");
    else if (StrEqual(szItem, "cz75a", false))
        strcopy(szOutput, iMaxLen, "cz75a");
    else if (StrEqual(szItem, "incgrenade", false) || StrEqual(szItem, "molotov", false))
        strcopy(szOutput, iMaxLen, "molotov");
}

bool ShouldSkipPurchase(int client, const char[] szItem)
{
    int iSlot = GetWeaponSlotFromItem(szItem);
    
    if (iSlot < 0 || iSlot > CS_SLOT_C4)
        return false;
    
    int iExistingWeapon = GetPlayerWeaponSlot(client, iSlot);
    if (!IsValidEntity(iExistingWeapon))
        return false;
    
    char szExistingClass[64];
    GetEntityClassname(iExistingWeapon, szExistingClass, sizeof(szExistingClass));
    ReplaceString(szExistingClass, sizeof(szExistingClass), "weapon_", "");
    
    // 副手永远不跳过购买
    if (iSlot == CS_SLOT_SECONDARY)
        return false;
    
    // 主武器的狙击枪特殊处理
    if (iSlot == CS_SLOT_PRIMARY && IsSniperWeapon(szItem))
    {
        if (IsSniperWeapon(szExistingClass))
            return true;
        return false;
    }
    
    if (iSlot == CS_SLOT_PRIMARY && IsSniperWeapon(szExistingClass) && !IsSniperWeapon(szItem))
    {
        return true;
    }
    
    if (iSlot == CS_SLOT_PRIMARY)
        return true;
    
    return false;
}

// ============================================================================
// 命令处理
// ============================================================================

public Action Command_SetEconomyMode(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Bot REC] Usage: sm_botrec_economy <mode>");
        ReplyToCommand(client, "  0 = Single Team (default)");  
        ReplyToCommand(client, "  1 = Both Teams");  
        return Plugin_Handled;
    }
    
    char szArg[8];
    GetCmdArg(1, szArg, sizeof(szArg));
    int iMode = StringToInt(szArg);
    
    if (iMode < 0 || iMode > 1)
    {
        ReplyToCommand(client, "[Bot REC] Invalid mode! Use 0-1");
        return Plugin_Handled;
    }
    
    g_cvEconomyMode.IntValue = iMode;
    g_iEconomyMode = view_as<EconomySelectionMode>(iMode);
    
    char szModeName[64];
    switch (g_iEconomyMode)
    {
        case Economy_SingleTeam: strcopy(szModeName, sizeof(szModeName), "Single Team");
        case Economy_BothTeams: strcopy(szModeName, sizeof(szModeName), "Both Teams");
    }
    
    ReplyToCommand(client, "[Bot REC] Economy mode set to: %s", szModeName);
    return Plugin_Handled;
}

public Action Command_SetRoundMode(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Bot REC] Usage: sm_botrec_round <mode>");
        ReplyToCommand(client, "  0 = Full Match");
        ReplyToCommand(client, "  1 = Economy Based (default)");
        return Plugin_Handled;
    }
    
    char szArg[8];
    GetCmdArg(1, szArg, sizeof(szArg));
    int iMode = StringToInt(szArg);
    
    if (iMode < 0 || iMode > 1)
    {
        ReplyToCommand(client, "[Bot REC] Invalid mode! Use 0 or 1");
        return Plugin_Handled;
    }
    
    g_cvRoundMode.IntValue = iMode;
    g_iRoundMode = view_as<RoundSelectionMode>(iMode);
    
    char szModeName[64];
    switch (g_iRoundMode)
    {
        case Round_FullMatch: strcopy(szModeName, sizeof(szModeName), "Full Match");
        case Round_Economy: strcopy(szModeName, sizeof(szModeName), "Economy Based");
    }
    
    ReplyToCommand(client, "[Bot REC] Round mode set to: %s", szModeName);
    return Plugin_Handled;
}

public Action Command_ShowStatus(int client, int args)
{
    char szEconomyMode[64], szRoundMode[64], szPlaybackMode[64];
    
    switch (g_iPlaybackMode)
    {
        case Playback_Full: strcopy(szPlaybackMode, sizeof(szPlaybackMode), "Full Round");
        case Playback_PreGame: strcopy(szPlaybackMode, sizeof(szPlaybackMode), "PreGame");
    }
    
    switch (g_iEconomyMode)
    {
        case Economy_SingleTeam: strcopy(szEconomyMode, sizeof(szEconomyMode), "Single Team");
        case Economy_BothTeams: strcopy(szEconomyMode, sizeof(szEconomyMode), "Both Teams");
    }
    
    switch (g_iRoundMode)
    {
        case Round_FullMatch: strcopy(szRoundMode, sizeof(szRoundMode), "Full Match");
        case Round_Economy: strcopy(szRoundMode, sizeof(szRoundMode), "Economy Based");
    }
    
    ReplyToCommand(client, "[Bot REC] ===== Status =====");
    ReplyToCommand(client, "  Playback Mode: %s", szPlaybackMode);
    ReplyToCommand(client, "  Round Mode: %s", szRoundMode);
    ReplyToCommand(client, "  Economy Mode: %s", szEconomyMode);
    ReplyToCommand(client, "  Current Round: %d", g_iCurrentRound);
    ReplyToCommand(client, "  Rec Folder: %s", g_bRecFolderSelected ? g_szCurrentRecFolder : "None");

    int iPlayingCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && g_bPlayingRoundStartRec[i])
            iPlayingCount++;
    }
    ReplyToCommand(client, "  Bots Playing REC: %d", iPlayingCount);
    
    return Plugin_Handled;
}

// ============================================================================
// 判断是否应该因伤害停止REC
// ============================================================================

bool ShouldStopFromDamage(int iDamage, int iDamageType)
{
    // 忽略低伤害
    if (iDamage < 5)
    {
        return false;
    }
    
    // 不停止摔伤
    if (iDamageType & DMG_FALL)
    {
        return false;
    }
    
    // 不停止手雷
    if (iDamageType & DMG_BLAST)
    {
        return false;
    }
    
    // 燃烧伤害5点以上才停止
    if (iDamageType & DMG_BURN)
    {
        if (iDamage < 5)
        {
            return false;
        }
        return true;
    }
    
    // 停止子弹伤害
    if (iDamageType & DMG_BULLET)
    {
        return true;
    }
    
    // 停止其他伤害
    return true;
}

// ============================================================================
// 判断是否为手枪局
// ============================================================================

bool IsPistolRound(int iRound)
{
    return (iRound == 0 || iRound == 15);
}

bool IsCurrentRoundPistol()
{
    return IsPistolRound(g_iCurrentRound);
}

// ============================================================================
// 公共辅助函数
// ============================================================================

/**
 * 获取bot使用的demo文件夹
 */
void GetUseDemoFolder(int client, char[] szOutput, int iMaxLen)
{
    if (g_szBotRecFolder[client][0] != '\0')
    {
        strcopy(szOutput, iMaxLen, g_szBotRecFolder[client]);
    }
    else if (g_bRecFolderSelected && g_szCurrentRecFolder[0] != '\0')
    {
        strcopy(szOutput, iMaxLen, g_szCurrentRecFolder);
    }
    else
    {
        szOutput[0] = '\0';
    }
}

/**
 * 清理客户端所有timer和数据
 */
void CleanupClientTimers(int client)
{
    // 清理购买timer
    KillClientTimer(g_hPurchaseTimer[client]);
    
    if (g_hPurchaseActions[client] != null)
    {
        delete g_hPurchaseActions[client];
        g_hPurchaseActions[client] = null;
    }
    g_iPurchaseActionIndex[client] = 0;
    
    // 清理聊天timer
    KillClientTimer(g_hChatTimer[client]);
    
    if (g_hChatActions[client] != null)
    {
        delete g_hChatActions[client];
        g_hChatActions[client] = null;
    }
    g_iChatActionIndex[client] = 0;

    KillClientTimer(g_hVoiceTimer[client]);
    
    // 停止所有正在播放的语音
    if (BotVoice_IsSpeaking(client))
    {
        BotVoice_StopAllSpeaking(client);  
    }
    
    if (g_hVoiceActions[client] != null)
    {
        delete g_hVoiceActions[client];
        g_hVoiceActions[client] = null;
    }
    g_iVoiceActionIndex[client] = 0;
    
    if (g_hVoiceFiles[client] != null)
    {
        delete g_hVoiceFiles[client];
        g_hVoiceFiles[client] = null;
    }
    
    g_bAllowPurchase[client] = false;

    if (g_hInitialInventory[client] != null)
    {
        delete g_hInitialInventory[client];
        g_hInitialInventory[client] = null;
    }
    
    g_bInitialInventoryApplied[client] = false;
    g_bPurchaseSystemActive[client] = false;
}

/**
 * 停止指定队伍bot的REC播放
 * 
 * @param iTeam         队伍 (CS_TEAM_T 或 CS_TEAM_CT，0表示所有队伍)
 * @param bCheckBalance 是否检查人数平衡（仅对CT有效）
 */
void StopTeamBotsRec(int iTeam, bool bCheckBalance = false)
{
    if (iTeam != 0 && (iTeam < 0 || iTeam >= 4))
        return;
    
    // 如果需要检查人数平衡
    if (bCheckBalance && iTeam == CS_TEAM_CT)
    {
        int iTCount = GetAliveTeamCount(CS_TEAM_T);
        int iCTCount = GetAliveTeamCount(CS_TEAM_CT);
        int iDifference = iTCount - iCTCount;
        
        // 如果 T 方人数大于 CT 2人或以上，不停止
        if (iDifference >= 2)
        {
            return;
        }
    }
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (iTeam != 0 && GetClientTeam(i) != iTeam)
            continue;
        
        if (g_bPlayingRoundStartRec[i] && BotMimic_IsPlayerMimicing(i))
        {
            BotMimic_StopPlayerMimic(i);
            g_bPlayingRoundStartRec[i] = false;
        }
    }
}

/**
 * 统一Timer清理函数
 */
void KillClientTimer(Handle &hTimer)
{
    if (hTimer != null)
    {
        KillTimer(hTimer);
        hTimer = null;
    }
}

// ============================================================================
// 辅助函数
// ============================================================================

void ResetClientData(int client)
{
    g_bPlayingRoundStartRec[client] = false;
    g_szRoundStartRecPath[client][0] = '\0';
    g_szCurrentRecName[client][0] = '\0';
    g_szAssignedRecName[client][0] = '\0';
    g_iAssignedRecIndex[client] = -1;
    g_bRecMoneySet[client] = false;
    g_iRecStartMoney[client] = 0;
    g_fRecStartTime[client] = 0.0;
    g_bPurchaseSystemActive[client] = false;

    BotShared_ResetBotState(client);    
}


bool IsValidClient(int client)
{
    return BotShared_IsValidClient(client);
}

int GetAliveTeamCount(int iTeam)
{
    int iNumber = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i))
            continue;
        
        if (!IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != iTeam)
            continue;
        
        iNumber++;
    }
    return iNumber;
}

int GetWeaponSlotFromItem(const char[] szItem)
{
    int type;
    if (!g_hWeaponTypes.GetValue(szItem, type))
        return -1;
    
    if (type & (WEAPON_TYPE_RIFLE | WEAPON_TYPE_SNIPER | WEAPON_TYPE_SMG))
        return CS_SLOT_PRIMARY;
    if (type & WEAPON_TYPE_DEFAULT_PISTOL)
        return CS_SLOT_SECONDARY;
    
    return -1;
}

// 按金钱排序bot（从低到高）
public int Sort_BotsByMoney(int index1, int index2, Handle array, Handle hndl)
{
    ArrayList list = view_as<ArrayList>(array);   
    int client1 = list.Get(index1);
    int client2 = list.Get(index2);

    int iMoney1 = GetEntProp(client1, Prop_Send, "m_iAccount");
    int iMoney2 = GetEntProp(client2, Prop_Send, "m_iAccount");

    if (iMoney1 < iMoney2) return -1;
    if (iMoney1 > iMoney2) return 1;
    return 0;
}

// 为指定demo加载购买数据
JSONObject LoadPurchaseDataForDemo(const char[] szMap, const char[] szDemoFolder)
{
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/%s/%s/%s/purchases.json", szModeBase, szMap, szDemoFolder);
    
    if (!FileExists(szPath))
        return null;
    
    return JSONObject.FromFile(szPath);
}

public Action Command_SelectDemo(int client, int args)
{
    if (args < 1)
    {
        char szMap[64];
        GetCurrentMap(szMap, sizeof(szMap));
        GetMapDisplayName(szMap, szMap, sizeof(szMap));
        
        char szMapBasePath[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/%s/%s", szMap);
        
        ReplyToCommand(client, "[Bot REC] Usage: sm_botrec_select <folder_name>");
        ReplyToCommand(client, "[Bot REC] Available demos:");
        
        if (DirExists(szMapBasePath))
        {
            DirectoryListing hDir = OpenDirectory(szMapBasePath);
            if (hDir != null)
            {
                char szFolderName[PLATFORM_MAX_PATH];
                FileType iFileType;
                int iCount = 0;
                
                while (hDir.GetNext(szFolderName, sizeof(szFolderName), iFileType))
                {
                    if (iFileType == FileType_Directory && strcmp(szFolderName, ".") != 0 && strcmp(szFolderName, "..") != 0)
                    {
                        ReplyToCommand(client, "  - %s", szFolderName);
                        iCount++;
                    }
                }
                
                delete hDir;
                
                if (iCount == 0)
                    ReplyToCommand(client, "[Bot REC] No demo folders found!");
            }
        }
        else
        {
            ReplyToCommand(client, "[Bot REC] Demo path not found: %s", szMapBasePath);
        }
        
        return Plugin_Handled;
    }
    
    char szDemoFolder[PLATFORM_MAX_PATH];
    GetCmdArg(1, szDemoFolder, sizeof(szDemoFolder));
    
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szDemoPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szDemoPath, sizeof(szDemoPath), "data/botmimic/%s/%s/%s", szModeBase, szMap, szDemoFolder);
    
    if (!DirExists(szDemoPath))
    {
        ReplyToCommand(client, "[Bot REC] Demo folder '%s' not found!", szDemoFolder);
        return Plugin_Handled;
    }
    
    strcopy(g_szCurrentRecFolder, sizeof(g_szCurrentRecFolder), szDemoFolder);
    g_bRecFolderSelected = true;

    LoadAllDemoData(szMap, g_szCurrentRecFolder);
    
    ReplyToCommand(client, "[Bot REC] Demo folder set to: %s", szDemoFolder);
    ReplyToCommand(client, "[Bot REC] Use 'mp_restartgame 1' to apply changes");
    
    return Plugin_Handled;
}

// ============================================================================
// 辅助函数 为一个队伍分配REC
// ============================================================================

// 为一个队伍分配REC
bool TryAssignRecsToTeamWithCost(ArrayList hBots, ArrayList hRecInfoList, 
                                  int assignment[MAXPLAYERS+1], 
                                  int &totalValue, int &totalCost)
{
    int iBotCount = hBots.Length;
    ArrayList usedRecIndices = new ArrayList();
    totalValue = 0;
    totalCost = 0;
    
    // 从钱最少的Bot开始分配
    for (int b = 0; b < iBotCount; b++)
    {
        int client = hBots.Get(b);
        int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
        
        // 找到该Bot能买得起且价值最高的REC
        int iBestRecIndex = -1;
        int iBestRecValue = -1;
        
        for (int r = 0; r < hRecInfoList.Length; r++)
        {
            if (usedRecIndices.FindValue(r) != -1)
                continue;
            
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(r, recInfo, sizeof(RecEquipmentInfo));
            
            // 检查Bot是否买得起
            if (recInfo.totalCost > clientMoney)
                continue;
                    
            // 选择价值最高的
            if (recInfo.totalValue > iBestRecValue)
            {
                iBestRecIndex = r;
                iBestRecValue = recInfo.totalValue;
            }
        }
    
        if (iBestRecIndex == -1)
        {
            delete usedRecIndices;
            return false;
        }

        assignment[b] = iBestRecIndex;
        usedRecIndices.Push(iBestRecIndex);
        
        RecEquipmentInfo recInfo;
        hRecInfoList.GetArray(iBestRecIndex, recInfo, sizeof(RecEquipmentInfo));
        totalValue += recInfo.totalValue;
        totalCost += recInfo.totalCost;
    }

    delete usedRecIndices;
    return true;
}

// 获取某回合的REC文件列表
ArrayList GetRecFilesForRound(const char[] szMap, const char[] szDemoFolder, 
                              int iRound, const char[] szTeamName)
{
    ArrayList hRecFiles = new ArrayList(PLATFORM_MAX_PATH);
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szRoundPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szRoundPath, sizeof(szRoundPath), 
        "data/botmimic/%s/%s/%s/round%d/%s", 
        szModeBase, szMap, szDemoFolder, iRound + 1, szTeamName);
    
    if (!DirExists(szRoundPath))
        return hRecFiles;
    
    DirectoryListing hDir = OpenDirectory(szRoundPath);
    if (hDir != null)
    {
        char szFileName[PLATFORM_MAX_PATH];
        FileType iFileType;
        
        while (hDir.GetNext(szFileName, sizeof(szFileName), iFileType))
        {
            if (iFileType == FileType_File && StrContains(szFileName, ".rec") != -1)
            {
                ReplaceString(szFileName, sizeof(szFileName), ".rec", "");
                hRecFiles.PushString(szFileName);
            }
        }
        delete hDir;
    }
    
    hRecFiles.Sort(Sort_Ascending, Sort_String);
    
    return hRecFiles;
}

// 构建REC装备信息缓存
ArrayList BuildRecEquipmentInfo(ArrayList hRecFiles, JSONObject jTeam, int iTeam)
{
    ArrayList hRecInfoList = new ArrayList(sizeof(RecEquipmentInfo));
    
    for (int r = 0; r < hRecFiles.Length; r++)
    {
        char szRecName[PLATFORM_MAX_PATH];
        hRecFiles.GetString(r, szRecName, sizeof(szRecName));
        
        if (!jTeam.HasKey(szRecName))
        {
            continue;
        }
        
        JSONObject jBotData = view_as<JSONObject>(jTeam.Get(szRecName));
        
        RecEquipmentInfo recInfo;
        strcopy(recInfo.recName, PLATFORM_MAX_PATH, szRecName);
        
        recInfo.totalCost = 0;
        recInfo.totalValue = 0;
        
        if (jBotData.HasKey("initial_inventory"))
        {
            JSONArray jInitial = view_as<JSONArray>(jBotData.Get("initial_inventory"));
            
            for (int i = 0; i < jInitial.Length; i++)
            {
                char szItem[64];
                jInitial.GetString(i, szItem, sizeof(szItem));
                
                if (!IsDefaultPistol(szItem))
                {
                    char szConvertedItem[64];
                    GetTeamSpecificWeapon(szItem, iTeam, szConvertedItem, sizeof(szConvertedItem));
                    
                    int iPrice = GetItemPrice(szConvertedItem);
                    recInfo.totalCost += iPrice;
                }
            }
            
            delete jInitial;
        }
        
        // 计算购买行为的花费
        if (jBotData.HasKey("purchases"))
        {
            JSONArray jPurchases = view_as<JSONArray>(jBotData.Get("purchases"));
            
            for (int i = 0; i < jPurchases.Length; i++)
            {
                JSONObject jAction = view_as<JSONObject>(jPurchases.Get(i));
        
                char szAction[32];
                jAction.GetString("action", szAction, sizeof(szAction));
                
                char szItem[64];
                jAction.GetString("item", szItem, sizeof(szItem));

                char szConvertedItem[64];
                GetTeamSpecificWeapon(szItem, iTeam, szConvertedItem, sizeof(szConvertedItem));
                
                if (StrEqual(szAction, "purchased", false))
                {
                    if (IsDefaultPistol(szItem))
                    {
                        delete jAction;
                        continue;
                    }
                    
                    int iPrice = GetItemPrice(szConvertedItem);
                    recInfo.totalCost += iPrice;
                }
                
                delete jAction;
            }
            
        delete jPurchases;
    }
    
    recInfo.totalValue = recInfo.totalCost;
    
    delete jBotData;
    
    hRecInfoList.PushArray(recInfo, sizeof(RecEquipmentInfo));
    }
    
    return hRecInfoList;
}

/**
 * 为当前回合安排动态暂停
 * 
 */
void ScheduleDynamicPause(int iRound)
{
    if (g_iPlaybackMode == Playback_PreGame)
    {
        return;
    }
    
    if (IsInWarmup())
    {
        return;
    }
    
    if (!g_bPausePluginLoaded)
    {
        return;
    }
    
    if (iRound < 0 || iRound >= 31)
    {
        return;
    }
    
    if (!g_bAllRoundFreezeTimeValid[iRound])
    {
        return;
    }
    
    // 获取服务器冻结时间
    ConVar cvFreezeTime = FindConVar("mp_freezetime");
    float fServerFreeze = 20.0;
    
    if (cvFreezeTime != null)
    {
        fServerFreeze = cvFreezeTime.FloatValue;
    }
    
    float fDemoFreeze = g_fAllRoundFreezeTimes[iRound];
    
    // 如果demo冻结时间 <= 服务器冻结时间,不需要暂停
    if (fDemoFreeze <= fServerFreeze)
    {
        return;
    }
    
    // 计算时间差
    float fTimeDiff = fDemoFreeze - fServerFreeze;
    
    // 决定暂停策略
    float fPauseDelay = 0.0;
    int iPauseTime = 0;
    
    float fMaxDelayedPause = fServerFreeze + 30.0;
    
    if (fTimeDiff > fMaxDelayedPause)
    {
        fPauseDelay = 0.0;
        iPauseTime = RoundToNearest(fTimeDiff);
    }
    else if (fTimeDiff <= 30.0)
    {
        fPauseDelay = 0.0;
        iPauseTime = RoundToNearest(fTimeDiff);
    }
    else
    {
        fPauseDelay = fTimeDiff - 30.0;
        iPauseTime = 30;
    }
    
    int iBotToUse = -1;
    int iTeamToUse = -1;
    
    int iPausesLeftT = BotPause_GetTeamPausesLeft(CS_TEAM_T);
    int iPausesLeftCT = BotPause_GetTeamPausesLeft(CS_TEAM_CT);
    
    if (iPausesLeftT > 0 && iPausesLeftCT > 0)
    {
        iTeamToUse = GetRandomInt(0, 1) == 0 ? CS_TEAM_T : CS_TEAM_CT;
    }
    else if (iPausesLeftT > 0)
    {
        iTeamToUse = CS_TEAM_T;
    }
    else if (iPausesLeftCT > 0)
    {
        iTeamToUse = CS_TEAM_CT;
    }
    else
    {
        return;
    }
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != iTeamToUse)
            continue;
        
        iBotToUse = i;
        break;
    }
    
    if (iBotToUse == -1)
    {
        int iOtherTeam = (iTeamToUse == CS_TEAM_T) ? CS_TEAM_CT : CS_TEAM_T;
        int iOtherPauses = BotPause_GetTeamPausesLeft(iOtherTeam);
        
        if (iOtherPauses > 0)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
                    continue;
                
                if (GetClientTeam(i) != iOtherTeam)
                    continue;
                
                iBotToUse = i;
                iTeamToUse = iOtherTeam;
                break;
            }
        }
        
        if (iBotToUse == -1)
        {
            return;
        }
    }
    
    // 创建定时器让bot执行暂停
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(iBotToUse));
    pack.WriteCell(iPauseTime);
    
    CreateTimer(fPauseDelay, Timer_BotExecutePause, pack, TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Bot执行暂停的定时器
 */
public Action Timer_BotExecutePause(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    int iPauseTime = pack.ReadCell();
    delete pack;
    
    int client = GetClientOfUserId(iUserId);
    
    if (!IsValidClient(client))
    {
        return Plugin_Stop;
    }

    if (iPauseTime == 30)  
    {
        FakeClientCommand(client, "say .p");
    }
    else
    {
        FakeClientCommand(client, "say .p %d", iPauseTime);
    }
    
    return Plugin_Stop;
}

// ============================================================================
// 武器数据系统
// ============================================================================

void InitWeaponData()
{
    g_hWeaponPrices = new StringMap();
    g_hWeaponConversion_T = new StringMap();
    g_hWeaponConversion_CT = new StringMap();
    g_hWeaponTypes = new StringMap();
    
    // 价格数据
    g_hWeaponPrices.SetValue("ak47", 2700);
    g_hWeaponPrices.SetValue("m4a1", 3100);
    g_hWeaponPrices.SetValue("m4a1_silencer", 2900);
    g_hWeaponPrices.SetValue("awp", 4750);
    g_hWeaponPrices.SetValue("famas", 2250);
    g_hWeaponPrices.SetValue("galilar", 2000);
    g_hWeaponPrices.SetValue("ssg08", 1700);
    g_hWeaponPrices.SetValue("aug", 3300);
    g_hWeaponPrices.SetValue("sg556", 3000);
    g_hWeaponPrices.SetValue("scar20", 5000);
    g_hWeaponPrices.SetValue("g3sg1", 5000);
    g_hWeaponPrices.SetValue("mp9", 1250);
    g_hWeaponPrices.SetValue("mac10", 1050);
    g_hWeaponPrices.SetValue("ump45", 1200);
    g_hWeaponPrices.SetValue("p90", 2350);
    g_hWeaponPrices.SetValue("bizon", 1400);
    g_hWeaponPrices.SetValue("mp7", 1500);
    g_hWeaponPrices.SetValue("nova", 1050);
    g_hWeaponPrices.SetValue("xm1014", 2000);
    g_hWeaponPrices.SetValue("mag7", 1300);
    g_hWeaponPrices.SetValue("sawedoff", 1100);
    g_hWeaponPrices.SetValue("m249", 5200);
    g_hWeaponPrices.SetValue("negev", 1700);
    g_hWeaponPrices.SetValue("deagle", 700);
    g_hWeaponPrices.SetValue("p250", 300);
    g_hWeaponPrices.SetValue("tec9", 500);
    g_hWeaponPrices.SetValue("fn57", 500);
    g_hWeaponPrices.SetValue("cz75a", 500);
    g_hWeaponPrices.SetValue("elite", 300);
    g_hWeaponPrices.SetValue("revolver", 600);
    g_hWeaponPrices.SetValue("smokegrenade", 300);
    g_hWeaponPrices.SetValue("flashbang", 200);
    g_hWeaponPrices.SetValue("hegrenade", 300);
    g_hWeaponPrices.SetValue("molotov", 400);
    g_hWeaponPrices.SetValue("incgrenade", 600);
    g_hWeaponPrices.SetValue("decoy", 50);
    g_hWeaponPrices.SetValue("vest", 650);
    g_hWeaponPrices.SetValue("vesthelm", 1000);
    g_hWeaponPrices.SetValue("defuser", 400);
    g_hWeaponPrices.SetValue("taser", 200);
    
    // 使用辅助函数双向设置转换
    SetBidirectionalConversion("m4a1", "ak47");
    SetBidirectionalConversion("m4a1_silencer", "ak47");
    SetBidirectionalConversion("famas", "galilar");
    SetBidirectionalConversion("aug", "sg556");
    SetBidirectionalConversion("mp9", "mac10");
    SetBidirectionalConversion("fn57", "tec9");
    SetBidirectionalConversion("usp_silencer", "glock");
    SetBidirectionalConversion("hkp2000", "glock");
    SetBidirectionalConversion("scar20", "g3sg1");
    SetBidirectionalConversion("mag7", "sawedoff");
    SetBidirectionalConversion("incgrenade", "molotov");
    
    // 武器类型 
    g_hWeaponTypes.SetValue("ak47", WEAPON_TYPE_RIFLE);
    g_hWeaponTypes.SetValue("m4a1", WEAPON_TYPE_RIFLE);
    g_hWeaponTypes.SetValue("m4a1_silencer", WEAPON_TYPE_RIFLE);
    g_hWeaponTypes.SetValue("aug", WEAPON_TYPE_RIFLE);
    g_hWeaponTypes.SetValue("sg556", WEAPON_TYPE_RIFLE);
    g_hWeaponTypes.SetValue("famas", WEAPON_TYPE_RIFLE);
    g_hWeaponTypes.SetValue("galilar", WEAPON_TYPE_RIFLE);
    
    g_hWeaponTypes.SetValue("awp", WEAPON_TYPE_SNIPER);
    g_hWeaponTypes.SetValue("ssg08", WEAPON_TYPE_SNIPER);
    g_hWeaponTypes.SetValue("scar20", WEAPON_TYPE_SNIPER);
    g_hWeaponTypes.SetValue("g3sg1", WEAPON_TYPE_SNIPER);
    
    g_hWeaponTypes.SetValue("mp9", WEAPON_TYPE_SMG);
    g_hWeaponTypes.SetValue("mac10", WEAPON_TYPE_SMG);
    g_hWeaponTypes.SetValue("ump45", WEAPON_TYPE_SMG);
    g_hWeaponTypes.SetValue("p90", WEAPON_TYPE_SMG);
    g_hWeaponTypes.SetValue("bizon", WEAPON_TYPE_SMG);
    g_hWeaponTypes.SetValue("mp7", WEAPON_TYPE_SMG);
    
    g_hWeaponTypes.SetValue("smokegrenade", WEAPON_TYPE_UTILITY);
    g_hWeaponTypes.SetValue("flashbang", WEAPON_TYPE_UTILITY);
    g_hWeaponTypes.SetValue("hegrenade", WEAPON_TYPE_UTILITY);
    g_hWeaponTypes.SetValue("molotov", WEAPON_TYPE_UTILITY);
    g_hWeaponTypes.SetValue("incgrenade", WEAPON_TYPE_UTILITY);
    g_hWeaponTypes.SetValue("decoy", WEAPON_TYPE_UTILITY);
    
    g_hWeaponTypes.SetValue("glock", WEAPON_TYPE_DEFAULT_PISTOL);
    g_hWeaponTypes.SetValue("hkp2000", WEAPON_TYPE_DEFAULT_PISTOL);
    g_hWeaponTypes.SetValue("usp_silencer", WEAPON_TYPE_DEFAULT_PISTOL);
}

// 双向设置武器转换
void SetBidirectionalConversion(const char[] ctWeapon, const char[] tWeapon)
{
    g_hWeaponConversion_T.SetString(ctWeapon, tWeapon);
    g_hWeaponConversion_CT.SetString(tWeapon, ctWeapon);
}

// 武器类型检查函数
stock bool IsWeaponType(const char[] szItem, int typeFlag)
{
    int type;
    return g_hWeaponTypes.GetValue(szItem, type) && (type & typeFlag);
}

// 获取武器价格
int GetItemPrice(const char[] szItem)
{
    int price;
    return g_hWeaponPrices.GetValue(szItem, price) ? price : 0;
}

// 获取阵营对应武器
bool GetTeamSpecificWeapon(const char[] szWeapon, int iTeam, char[] szOutput, int iMaxLen)
{
    strcopy(szOutput, iMaxLen, szWeapon);
    
    StringMap map = (iTeam == CS_TEAM_T) ? g_hWeaponConversion_T : g_hWeaponConversion_CT;
    return map.GetString(szWeapon, szOutput, iMaxLen);
}

// 武器类型判断函数
bool IsSniperWeapon(const char[] szItem)
{
    return IsWeaponType(szItem, WEAPON_TYPE_SNIPER);
}

bool IsDefaultPistol(const char[] szItem)
{
    return IsWeaponType(szItem, WEAPON_TYPE_DEFAULT_PISTOL);
}

// ============================================================================
// 调试命令
// ============================================================================

public Action Command_DebugInfo(int client, int args)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szMapPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapPath, sizeof(szMapPath), "data/botmimic/%s/%s", szModeBase, szMap);
    
    ReplyToCommand(client, "[Bot REC] ===== DEBUG INFO =====");
    ReplyToCommand(client, "Map: %s", szMap);
    ReplyToCommand(client, "Map path exists: %s", DirExists(szMapPath) ? "YES" : "NO");
    ReplyToCommand(client, "Current round: %d", g_iCurrentRound);
    ReplyToCommand(client, "Round mode: %s", g_iRoundMode == Round_Economy ? "ECONOMY" : "FULL");
    ReplyToCommand(client, "Economy mode: %s", g_iEconomyMode == Economy_SingleTeam ? "SINGLE" : "BOTH");
    ReplyToCommand(client, "Rec folder: %s", g_bRecFolderSelected ? g_szCurrentRecFolder : "NONE");
    
    // 列出所有demo文件夹
    if (DirExists(szMapPath))
    {
        ReplyToCommand(client, "\nDemo folders:");
        DirectoryListing hDir = OpenDirectory(szMapPath);
        if (hDir != null)
        {
            char szFolder[PLATFORM_MAX_PATH];
            FileType iFileType;
            int iCount = 0;
            
            while (hDir.GetNext(szFolder, sizeof(szFolder), iFileType))
            {
                if (iFileType == FileType_Directory && strcmp(szFolder, ".") != 0 && strcmp(szFolder, "..") != 0)
                {
                    ReplyToCommand(client, "  %d. %s", ++iCount, szFolder);
                }
            }
            delete hDir;
            
            if (iCount == 0)
                ReplyToCommand(client, "  (No demo folders found)");
        }
    }
    
    // 显示所有bot的状态
    ReplyToCommand(client, "\nBot status:");
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i))
            continue;
        
        char szName[MAX_NAME_LENGTH];
        GetClientName(i, szName, sizeof(szName));
        int iMoney = GetEntProp(i, Prop_Send, "m_iAccount");
        int iTeam = GetClientTeam(i);
        
        ReplyToCommand(client, "  %d. %s (Team=%d, $%d, Rec=%s)", 
            i, szName, iTeam, iMoney, 
            g_szAssignedRecName[i][0] != '\0' ? g_szAssignedRecName[i] : "NONE");
    }
    
    return Plugin_Handled;
}

// ============================================================================
// 共享库函数
// ============================================================================

/**
 * 初始化共享Bot函数库
 */
stock bool BotShared_Init()
{
    GameData hConf = new GameData("botstuff.games");
    if (hConf == null)
    {
        LogError("[Bot Shared] Failed to load botstuff.games gamedata");
        return false;
    }
    
    g_BotShared_EnemyVisibleOffset = hConf.GetOffset("CCSBot::m_isEnemyVisible");
    g_BotShared_EnemyOffset = hConf.GetOffset("CCSBot::m_enemy");
    
    delete hConf;
    
    if (g_BotShared_EnemyVisibleOffset == -1 || g_BotShared_EnemyOffset == -1)
    {
        LogError("[Bot Shared] Failed to get offsets");
        return false;
    }
    
    for (int i = 1; i <= MaxClients; i++)
    {
        g_BotShared_State[i] = BotState_Normal;
    }
    
    return true;
}

/**
 * 检查客户端是否有效
 */
stock bool BotShared_IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && 
            IsClientConnected(client) && 
            IsClientInGame(client));
}

/**
 * 获取Bot当前的敌人
 */
stock int BotShared_GetEnemy(int client)
{
    if (g_BotShared_EnemyOffset == -1)
        return -1;
    
    return GetEntDataEnt2(client, g_BotShared_EnemyOffset);
}

/**
 * 检查Bot是否能看到敌人
 */
stock bool BotShared_CanSeeEnemy(int client)
{
    if (g_BotShared_EnemyVisibleOffset == -1)
        return false;
    
    int iEnemy = BotShared_GetEnemy(client);
    if (!BotShared_IsValidClient(iEnemy) || !IsPlayerAlive(iEnemy))
        return false;
    
    return !!GetEntData(client, g_BotShared_EnemyVisibleOffset);
}

/**
 * 获取缓存的敌人
 */
stock int BotShared_GetCachedEnemy(int client)
{
    float fNow = GetGameTime();
    
    if (fNow - g_BotShared_EnemyCacheTime[client] < 0.1)
    {
        return g_BotShared_CachedEnemy[client];
    }
    
    g_BotShared_CachedEnemy[client] = BotShared_GetEnemy(client);
    g_BotShared_EnemyCacheTime[client] = fNow;
    
    return g_BotShared_CachedEnemy[client];
}

/**
 * 设置Bot状态
 */
stock void BotShared_SetBotState(int client, BotState state)
{
    if (client < 1 || client > MaxClients)
        return;
    
    g_BotShared_State[client] = state;
}

/**
 * 获取Bot状态
 */
stock BotState BotShared_GetBotState(int client)
{
    if (client < 1 || client > MaxClients)
        return BotState_Normal;
    
    return g_BotShared_State[client];
}

/**
 * 重置Bot状态
 */
stock void BotShared_ResetBotState(int client)
{
    BotShared_SetBotState(client, BotState_Normal);
}

/**
 * 重置炸弹状态
 */
stock void BotShared_ResetBombState()
{
}

// ============================================================================
// C4持有者系统
// ============================================================================

/**
 * 加载C4持有者数据文件
 */
bool LoadC4HolderDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/%s/%s/%s/c4_holders.json", szModeBase, szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        return false;
    }
    
    if (g_jC4HolderData != null)
        delete g_jC4HolderData;
    
    g_jC4HolderData = view_as<JSONArray>(JSONArray.FromFile(szPath));
    if (g_jC4HolderData == null)
    {
        return false;
    }
    
    return true;
}

/**
 * 获取指定回合的C4持有者名称
 */
bool GetC4HolderForRound(int iRound, char[] szPlayerName, int iMaxLen)
{
    if (g_jC4HolderData == null)
        return false;
    
    int iTargetRound = iRound + 1;
    
    for (int i = 0; i < g_jC4HolderData.Length; i++)
    {
        JSONObject jEntry = view_as<JSONObject>(g_jC4HolderData.Get(i));
        
        int iRoundNum = jEntry.GetInt("round");
        
        if (iRoundNum == iTargetRound)
        {
            jEntry.GetString("player_name", szPlayerName, iMaxLen);
            delete jEntry;
            
            return true;
        }
        
        delete jEntry;
    }
    
    return false;
}

/**
 * 冻结时间开始时分配botC4
 */
public Action Timer_AssignC4AtFreezeStart(Handle hTimer)
{
    char szHolderName[MAX_NAME_LENGTH];
    
    if (!GetC4HolderForRound(g_iCurrentRound, szHolderName, sizeof(szHolderName)))
    {
        return Plugin_Stop;
    }
    
    bool bIsOnRealPlayer = false;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        int iC4 = GetPlayerWeaponSlot(i, CS_SLOT_C4);
        if (IsValidEntity(iC4))
        {
            char szClass[64];
            GetEntityClassname(iC4, szClass, sizeof(szClass));
            
            if (StrEqual(szClass, "weapon_c4", false))
            {
                bIsOnRealPlayer = !IsFakeClient(i);
                break;
            }
        }
    }
    
    if (bIsOnRealPlayer)
    {
        return Plugin_Stop;
    }
    
    int iTargetBot = -1;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        if (g_szCurrentRecName[i][0] == '\0')
            continue;
        
        if (StrEqual(g_szCurrentRecName[i], szHolderName, false))
        {
            iTargetBot = i;
            break;
        }
    }
    
    if (iTargetBot == -1)
    {
        return Plugin_Stop;
    }
    
    // 检查目标bot是否已有C4
    int iTargetC4 = GetPlayerWeaponSlot(iTargetBot, CS_SLOT_C4);
    if (IsValidEntity(iTargetC4))
    {
        return Plugin_Stop;
    }
    
    // 移除所有其他T方bot的C4
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsPlayerAlive(i) || i == iTargetBot)
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        if (!IsFakeClient(i))
            continue;
        
        int iC4 = GetPlayerWeaponSlot(i, CS_SLOT_C4);
        if (IsValidEntity(iC4))
        {
            char szClass[64];
            GetEntityClassname(iC4, szClass, sizeof(szClass));
            
            if (StrEqual(szClass, "weapon_c4", false))
            {
                RemovePlayerItem(i, iC4);
                AcceptEntityInput(iC4, "Kill");
            }
        }
    }
    
    // 给目标bot分配C4
    GivePlayerItem(iTargetBot, "weapon_c4");
    
    return Plugin_Stop;
}

// 检查热身
bool IsInWarmup()
{
    return !!GameRules_GetProp("m_bWarmupPeriod");
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "bot_pause"))
    {
        g_bPausePluginLoaded = true;
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "bot_pause"))
    {
        g_bPausePluginLoaded = false;
    }
}   

// ============================================================================
// 语音文件预缓存系统
// ============================================================================

/**
 * FakePrecacheSound - 用于预缓存音频文件
 */
stock void FakePrecacheSound(const char[] szPath)
{
    char szBuffer[PLATFORM_MAX_PATH];
    PrecacheSound(szPath, true);
    Format(szBuffer, sizeof(szBuffer), "sound/%s", szPath);
    AddFileToDownloadsTable(szBuffer);
}

// ============================================================================
// 缓存管理系统
// ============================================================================

/**
 * 加载demo的所有数据到缓存
 */
void LoadAllDemoData(const char[] szMap, const char[] szDemoFolder)
{
    PrintToServer("[Bot REC Cache] Loading all data for: %s", szDemoFolder);
    
    // 清理旧缓存
    ClearAllCachedData();
    
    // 加载freeze时间
    float fDummy[31];
    bool bDummy[31];
    LoadFreezeTimes(szMap, szDemoFolder, fDummy, bDummy);
    
    // 加载购买数据
    LoadPurchaseDataFile(szDemoFolder);
    
    // 加载聊天数据
    LoadChatDataFile(szDemoFolder);

    // 加载语音数据
    LoadVoiceDataFile(szDemoFolder);
    
    // 加载C4持有者数据
    LoadC4HolderDataFile(szDemoFolder);
    
    // 加载money数据
    LoadMoneyDataFile(szDemoFolder);

    // 加载出生点数据
    LoadSpawnDataFile(szDemoFolder);
    
    PrintToServer("[Bot REC Cache] All data loaded successfully");
}

/**
 * 清理所有缓存数据
 */
void ClearAllCachedData()
{
    if (g_jPurchaseData != null)
    {
        delete g_jPurchaseData;
        g_jPurchaseData = null;
    }
    
    if (g_jChatData != null)
    {
        delete g_jChatData;
        g_jChatData = null;
    }

    if (g_jVoiceData != null)
    {
        delete g_jVoiceData;
        g_jVoiceData = null;
    }
    
    if (g_jC4HolderData != null)
    {
        delete g_jC4HolderData;
        g_jC4HolderData = null;
    }
    
    if (g_jMoneyData != null)
    {
        delete g_jMoneyData;
        g_jMoneyData = null;
    }

    if (g_jSpawnData != null)
    {
        delete g_jSpawnData;
        g_jSpawnData = null;
    }
}

// ============================================================================
// 出生点系统
// ============================================================================

/**
 * 加载spawns.json到缓存
 */
bool LoadSpawnDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/%s/%s/%s/spawns.json", szModeBase, szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        return false;
    }
    
    if (g_jSpawnData != null)
        delete g_jSpawnData;
    
    g_jSpawnData = JSONObject.FromFile(szPath);
    
    if (g_jSpawnData == null)
        return false;
    
    // 加载所有可能的出生点
    if (g_jSpawnData.HasKey("summary"))
    {
        JSONObject jSummary = view_as<JSONObject>(g_jSpawnData.Get("summary"));
        
        // 加载T方出生点
        if (jSummary.HasKey("T"))
        {
            JSONObject jTeamT = view_as<JSONObject>(jSummary.Get("T"));
            if (jTeamT.HasKey("positions"))
            {
                JSONArray jPositions = view_as<JSONArray>(jTeamT.Get("positions"));
                
                for (int i = 0; i < jPositions.Length; i++)
                {
                    char szPos[64];
                    jPositions.GetString(i, szPos, sizeof(szPos));
                    
                    float pos[3];
                    ParsePositionString(szPos, pos);
                    g_hTeamSpawnPoints[CS_TEAM_T].PushArray(pos, 3);
                }
                
                delete jPositions;
            }
            delete jTeamT;
        }
        
        // 加载CT方出生点
        if (jSummary.HasKey("CT"))
        {
            JSONObject jTeamCT = view_as<JSONObject>(jSummary.Get("CT"));
            if (jTeamCT.HasKey("positions"))
            {
                JSONArray jPositions = view_as<JSONArray>(jTeamCT.Get("positions"));
                
                for (int i = 0; i < jPositions.Length; i++)
                {
                    char szPos[64];
                    jPositions.GetString(i, szPos, sizeof(szPos));
                    
                    float pos[3];
                    ParsePositionString(szPos, pos);
                    g_hTeamSpawnPoints[CS_TEAM_CT].PushArray(pos, 3);
                }
                
                delete jPositions;
            }
            delete jTeamCT;
        }
        
        delete jSummary;
    }
    
    return true;
}

/**
 * 解析位置字符串 "x y z" -> float[3]
 */
void ParsePositionString(const char[] szPos, float pos[3])
{
    char szParts[3][32];
    ExplodeString(szPos, " ", szParts, sizeof(szParts), sizeof(szParts[]));
    
    pos[0] = StringToFloat(szParts[0]);
    pos[1] = StringToFloat(szParts[1]);
    pos[2] = StringToFloat(szParts[2]);
}

/**
 * 预分配真实玩家的出生点
 */
void PreAssignPlayerSpawns()
{
    if (g_jSpawnData == null)
        return;
    
    // 获取当前回合已被bot使用的出生点
    ArrayList hUsedSpawns[4];  
    for (int i = 0; i < 4; i++)
        hUsedSpawns[i] = new ArrayList(3);
    
    // 查找当前回合数据，收集bot使用的出生点
    if (g_jSpawnData.HasKey("rounds"))
    {
        JSONArray jRounds = view_as<JSONArray>(g_jSpawnData.Get("rounds"));
        
        for (int i = 0; i < jRounds.Length; i++)
        {
            JSONObject jRound = view_as<JSONObject>(jRounds.Get(i));
            int iRound = jRound.GetInt("round");
            
            // 找到当前回合
            if (iRound == g_iCurrentRound + 1)
            {
                if (jRound.HasKey("spawns"))
                {
                    JSONArray jSpawns = view_as<JSONArray>(jRound.Get("spawns"));
                    
                    for (int j = 0; j < jSpawns.Length; j++)
                    {
                        JSONObject jSpawn = view_as<JSONObject>(jSpawns.Get(j));
                        
                        char szPlayerName[MAX_NAME_LENGTH];
                        jSpawn.GetString("player_name", szPlayerName, sizeof(szPlayerName));
                        
                        // 先获取队伍信息
                        char szTeam[4];
                        jSpawn.GetString("team", szTeam, sizeof(szTeam));
                        int iSpawnTeam = StrEqual(szTeam, "T", false) ? CS_TEAM_T : CS_TEAM_CT;
                        
                        // 检查这个rec名称是否在当前被分配使用
                        bool isActiveBot = false;
                        
                        // 经济模式：检查分配列表
                        if (g_bEconomyBasedSelection)
                        {
                            if (g_hAssignedRecsForTeam[iSpawnTeam] != null)
                            {
                                for (int r = 0; r < g_hAssignedRecsForTeam[iSpawnTeam].Length; r++)
                                {
                                    char szAssignedRec[PLATFORM_MAX_PATH];
                                    g_hAssignedRecsForTeam[iSpawnTeam].GetString(r, szAssignedRec, sizeof(szAssignedRec));
                                    
                                    if (StrEqual(szPlayerName, szAssignedRec, false))
                                    {
                                        isActiveBot = true;
                                        break;
                                    }
                                }
                            }
                        }
                        // 全局模式：所有在当前回合配置中的bot都算使用中
                        else
                        {
                            isActiveBot = true;
                        }
                        
                        // 记录使用中的出生点
                        if (isActiveBot)
                        {
                            char szPos[64];
                            jSpawn.GetString("position", szPos, sizeof(szPos));
                            
                            float pos[3];
                            ParsePositionString(szPos, pos);
                            hUsedSpawns[iSpawnTeam].PushArray(pos, 3);
                        }
                        
                        delete jSpawn;
                    }
                    
                    delete jSpawns;
                }
                
                delete jRound;
                break;
            }
            
            delete jRound;
        }
        
        delete jRounds;
    }
    
    // 用一个临时列表记录本次已分配的出生点
    ArrayList hThisRoundAssigned[4];
    for (int i = 0; i < 4; i++)
        hThisRoundAssigned[i] = new ArrayList(3);
    
    // 为每个真实玩家分配出生点
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client) || IsFakeClient(client))
            continue;
        
        int iTeam = GetClientTeam(client);
        if (iTeam != CS_TEAM_T && iTeam != CS_TEAM_CT)
            continue;
        
        // 从所有出生点中找一个未被使用的
        bool foundSpawn = false;
        
        for (int i = 0; i < g_hTeamSpawnPoints[iTeam].Length; i++)
        {
            float spawnPos[3];
            g_hTeamSpawnPoints[iTeam].GetArray(i, spawnPos, 3);
            
            // 检查这个出生点是否已被bot使用
            bool isUsed = false;
            for (int j = 0; j < hUsedSpawns[iTeam].Length; j++)
            {
                float usedPos[3];
                hUsedSpawns[iTeam].GetArray(j, usedPos, 3);
                
                // 如果距离小于10单位，认为是同一个出生点
                float dist = GetVectorDistance(spawnPos, usedPos);
                if (dist < 10.0)
                {
                    isUsed = true;
                    break;
                }
            }
            
            // 检查是否已被其他玩家分配
            if (!isUsed)
            {
                for (int j = 0; j < hThisRoundAssigned[iTeam].Length; j++)
                {
                    float assignedPos[3];
                    hThisRoundAssigned[iTeam].GetArray(j, assignedPos, 3);
                    
                    float dist = GetVectorDistance(spawnPos, assignedPos);
                    if (dist < 10.0)
                    {
                        isUsed = true;
                        break;
                    }
                }
            }
            
            // 找到未使用的出生点
            if (!isUsed)
            {
                g_fAssignedSpawnPos[client][0] = spawnPos[0];
                g_fAssignedSpawnPos[client][1] = spawnPos[1];
                g_fAssignedSpawnPos[client][2] = spawnPos[2];
                g_bHasAssignedSpawn[client] = true;
                foundSpawn = true;
                
                // 记录已分配
                hThisRoundAssigned[iTeam].PushArray(spawnPos, 3);
                break;
            }
        }
        
        // 如果没有找到未使用的出生点，标记为false
        if (!foundSpawn)
        {
            g_bHasAssignedSpawn[client] = false;
        }
    }
    
    // 清理
    for (int i = 0; i < 4; i++)
    {
        delete hUsedSpawns[i];
        delete hThisRoundAssigned[i]; 
    }
}

/**
 * 传送玩家到预分配的位置(自动匹配地面高度)
 */
public Action Timer_TeleportPlayer(Handle hTimer, any iUserId)
{
    int client = GetClientOfUserId(iUserId);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client))
        return Plugin_Stop;
    
    if (!g_bHasAssignedSpawn[client])
        return Plugin_Stop;
    
    // 使用配置的XY坐标,从高处向下追踪找到地面
    float traceStart[3];
    traceStart[0] = g_fAssignedSpawnPos[client][0];  
    traceStart[1] = g_fAssignedSpawnPos[client][1];  
    traceStart[2] = g_fAssignedSpawnPos[client][2] + 100.0; 
    
    float traceEnd[3];
    traceEnd[0] = traceStart[0];
    traceEnd[1] = traceStart[1];
    traceEnd[2] = traceStart[2] - 200.0;  // 向下追踪200单位
    
    Handle hTrace = TR_TraceRayFilterEx(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_World);
    
    if (TR_DidHit(hTrace))
    {
        float groundPos[3];
        TR_GetEndPosition(groundPos, hTrace);
        
        // 地面位置+1单位避免卡地
        groundPos[2] += 1.0;
        
        TeleportEntity(client, groundPos, NULL_VECTOR, NULL_VECTOR);
    }
    else
    {
        // 如果追踪失败,使用原坐标但保持当前高度
        float currentPos[3];
        GetClientAbsOrigin(client, currentPos);
        
        float newPos[3];
        newPos[0] = g_fAssignedSpawnPos[client][0];
        newPos[1] = g_fAssignedSpawnPos[client][1];
        newPos[2] = currentPos[2];
        
        TeleportEntity(client, newPos, NULL_VECTOR, NULL_VECTOR);
    }
    
    CloseHandle(hTrace);
    
    return Plugin_Stop;
}

/**
 * 射线追踪过滤器 - 检测世界几何体
 */
public bool TraceFilter_World(int entity, int contentsMask)
{
    // 追踪世界实体(entity 0)
    return (entity == 0);
}

/**
 * 加载money.json到缓存
 */
bool LoadMoneyDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/%s/%s/%s/money.json", szModeBase, szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        return false;
    }
    
    if (g_jMoneyData != null)
        delete g_jMoneyData;
    
    g_jMoneyData = JSONObject.FromFile(szPath);
    
    return (g_jMoneyData != null);
}

// ============================================================================
// 语音系统
// ============================================================================

/**
 * 加载语音数据文件
 */
bool LoadVoiceDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szModeBase[16];
    GetModeBasePath(szModeBase, sizeof(szModeBase));
    
    char szPath[PLATFORM_MAX_PATH];
    Format(szPath, sizeof(szPath), 
        "sound/botrec/%s/%s/%s/voice_info.json", szModeBase, szMap, szRecFolder);

    if (!FileExists(szPath))
    {
        return false;
    }
    
    // 清理旧数据
    if (g_jVoiceData != null)
        delete g_jVoiceData;

    // 加载JSON
    g_jVoiceData = view_as<JSONArray>(JSONArray.FromFile(szPath));
    if (g_jVoiceData == null)
    {
        return false;
    }
    
    PrintToServer("[Bot REC Cache] Loaded voice data from: %s", szPath);

    for (int i = 0; i < g_jVoiceData.Length; i++)
    {
        JSONObject jRecord = view_as<JSONObject>(g_jVoiceData.Get(i));
        if (!jRecord.HasKey("speeches")) { delete jRecord; continue; }

        int iRecordRound = jRecord.GetInt("round");
        
        JSONArray jSpeeches = view_as<JSONArray>(jRecord.Get("speeches"));
        for (int j = 0; j < jSpeeches.Length; j++)
        {
            JSONObject jSpeech = view_as<JSONObject>(jSpeeches.Get(j));
            char szVoiceFile[PLATFORM_MAX_PATH];
            jSpeech.GetString("file_name", szVoiceFile, sizeof(szVoiceFile));
            
            char szTeams[2][4] = { "t", "ct" };
            
            for(int t=0; t<2; t++) {
                char szVoicePath[PLATFORM_MAX_PATH];
                Format(szVoicePath, sizeof(szVoicePath), "botrec/%s/%s/%s/round%d/%s/%s", szModeBase, szMap, szRecFolder, iRecordRound, szTeams[t], szVoiceFile);
                
                char szFullPath[PLATFORM_MAX_PATH];
                Format(szFullPath, sizeof(szFullPath), "sound/%s", szVoicePath);
                
                if(FileExists(szFullPath)) {
                    AddFileToDownloadsTable(szFullPath); 
                    PrecacheSound(szVoicePath, true);    
                }
            }
            delete jSpeech;
        }
        delete jSpeeches;
        delete jRecord;
    }

    return true;
}

/**
 * 为bot加载语音动作
 */
bool LoadVoiceActionsForBot(int client, int iRound)
{
    if (IsInWarmup() || g_jVoiceData == null) return false;
    if (g_szCurrentRecName[client][0] == '\0') return false;
    
    char szBotRecName[PLATFORM_MAX_PATH];
    strcopy(szBotRecName, sizeof(szBotRecName), g_szCurrentRecName[client]);

    // 清理旧数据
    if (g_hVoiceActions[client] != null) delete g_hVoiceActions[client];
    if (g_hVoiceFiles[client] != null) delete g_hVoiceFiles[client];
    
    g_hVoiceActions[client] = new ArrayList(sizeof(VoiceActionEntry));
    g_hVoiceFiles[client] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_iVoiceActionIndex[client] = 0;
    
    int iVoiceCount = 0;
    int iTargetRound = iRound + 1;
    int iTeam = GetClientTeam(client);
    char szTeamFolder[8];
    
    if (iTeam == CS_TEAM_T) strcopy(szTeamFolder, sizeof(szTeamFolder), "t");
    else if (iTeam == CS_TEAM_CT) strcopy(szTeamFolder, sizeof(szTeamFolder), "ct");
    else return false;

    for (int i = 0; i < g_jVoiceData.Length; i++)
    {
        JSONObject jRecord = view_as<JSONObject>(g_jVoiceData.Get(i));
        int iRecordRound = jRecord.GetInt("round");
        
        if (iRecordRound != iTargetRound || !jRecord.HasKey("speeches"))
        {
            delete jRecord;
            continue;
        }
        
        JSONArray jSpeeches = view_as<JSONArray>(jRecord.Get("speeches"));
        for (int j = 0; j < jSpeeches.Length; j++)
        {
            JSONObject jSpeech = view_as<JSONObject>(jSpeeches.Get(j));
            char szPlayerName[MAX_NAME_LENGTH];
            jSpeech.GetString("player_name", szPlayerName, sizeof(szPlayerName));
            
            if (!StrEqual(szPlayerName, szBotRecName, false))
            {
                delete jSpeech;
                continue;
            }
            
            VoiceActionEntry entry;
            entry.startTime = jSpeech.GetFloat("start_time");
            entry.duration = jSpeech.GetFloat("duration");
            entry.isAlive = jSpeech.GetBool("is_alive");  
            
            char szVoiceFile[PLATFORM_MAX_PATH];
            jSpeech.GetString("file_name", szVoiceFile, sizeof(szVoiceFile));
            
            // 构建路径
            char szMap[64];
            GetCurrentMap(szMap, sizeof(szMap));
            GetMapDisplayName(szMap, szMap, sizeof(szMap));
            char szUseDemoFolder[PLATFORM_MAX_PATH];
            GetUseDemoFolder(client, szUseDemoFolder, sizeof(szUseDemoFolder));
            
            char szModeBase[16];
            GetModeBasePath(szModeBase, sizeof(szModeBase));
            
            char szVoicePath[PLATFORM_MAX_PATH];
            Format(szVoicePath, sizeof(szVoicePath), "botrec/%s/%s/%s/round%d/%s/%s", 
                szModeBase, szMap, szUseDemoFolder, iTargetRound, szTeamFolder, szVoiceFile);
            
            entry.fileIndex = g_hVoiceFiles[client].PushString(szVoicePath);
            g_hVoiceActions[client].PushArray(entry, sizeof(VoiceActionEntry));
            
            iVoiceCount++;
            delete jSpeech;
        }
        delete jSpeeches;
        delete jRecord;
    }
    
    return (iVoiceCount > 0);
}

/**
 * 语音执行timer
 */
public Action Timer_ExecuteVoiceAction(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    int client = GetClientOfUserId(iUserId);
    
    if (!IsValidClient(client))
    {
        g_hVoiceTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    // 热身期间停止语音timer
    if (IsInWarmup())
    {
        g_hVoiceTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    // 只要语音数据存在就继续
    if (g_hVoiceActions[client] == null)
    {
        g_hVoiceTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    float fCurrentTime = GetGameTime() - g_fRecStartTime[client];
    bool bClientAlive = IsPlayerAlive(client);
    
    while (g_iVoiceActionIndex[client] < g_hVoiceActions[client].Length)
    {
        VoiceActionEntry entry;
        g_hVoiceActions[client].GetArray(g_iVoiceActionIndex[client], entry, sizeof(VoiceActionEntry));
        
        if (fCurrentTime < entry.startTime) 
            break;
        
        // 检查存活状态是否匹配
        if (entry.isAlive != bClientAlive)
        {
            g_iVoiceActionIndex[client]++;
            continue;
        }
        
        // 获取语音文件路径
        char szVoiceFile[PLATFORM_MAX_PATH];
        g_hVoiceFiles[client].GetString(entry.fileIndex, szVoiceFile, sizeof(szVoiceFile));
        
        // 开始说话
        BotVoice_StartSpeaking(client, szVoiceFile, entry.duration);
        
        g_iVoiceActionIndex[client]++;
    }
    
    // 如果所有语音都播放完毕,停止定时器
    if (g_iVoiceActionIndex[client] >= g_hVoiceActions[client].Length)
    {
        g_hVoiceTimer[client] = null;
        delete pack;
        return Plugin_Stop;
    }
    
    return Plugin_Continue;
}

/**
 * 根据当前模式获取基础路径文件夹名
 */
void GetModeBasePath(char[] szOutput, int iMaxLen)
{
    if (g_iPlaybackMode == Playback_PreGame)
        strcopy(szOutput, iMaxLen, "pregame");
    else
        strcopy(szOutput, iMaxLen, "full");
}

void StartBotRecPlayback(int client)
{
    g_bPlayingRoundStartRec[client] = true;
    float fGameTime = GetGameTime();
    g_fRecStartTime[client] = fGameTime;
    
    BotMimic_PlayRecordFromFile(client, g_szRoundStartRecPath[client]);
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    BotShared_SetBotState(client, BotState_PlayingREC);
}

public Action Command_SetPlaybackMode(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Bot REC] Usage: sm_botrec_playback <mode>");
        ReplyToCommand(client, "  0 = Full Round (from round start)");
        ReplyToCommand(client, "  1 = PreGame (1s before freeze ends)");
        return Plugin_Handled;
    }
    
    char szArg[8];
    GetCmdArg(1, szArg, sizeof(szArg));
    int iMode = StringToInt(szArg);
    
    if (iMode < 0 || iMode > 1)
    {
        ReplyToCommand(client, "[Bot REC] Invalid mode! Use 0 or 1");
        return Plugin_Handled;
    }
    
    g_cvPlaybackMode.IntValue = iMode;
    g_iPlaybackMode = view_as<PlaybackMode>(iMode);
    
    char szModeName[64];
    switch (g_iPlaybackMode)
    {
        case Playback_Full: strcopy(szModeName, sizeof(szModeName), "Full Round");
        case Playback_PreGame: strcopy(szModeName, sizeof(szModeName), "PreGame");
    }
    
    ReplyToCommand(client, "[Bot REC] Playback mode set to: %s", szModeName);
    ReplyToCommand(client, "[Bot REC] Use 'mp_restartgame 1' to apply changes");
    return Plugin_Handled;
}

/**
 * 获取距离回合开始的时间
 */
float GetRoundStartTime()
{
    return g_fRoundStartGameTime;
}

/**
 * PreGame：在冻结时间前1秒播放
 */
public Action Timer_StartAllBotsPlayback(Handle hTimer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (g_szRoundStartRecPath[i][0] == '\0')
            continue;
        
        // 开始正式播放
        StartBotRecPlayback(i);
    }
    
    return Plugin_Stop;
}

/**
 * PreGame：瞬间播放rec然后停止（定位）
 */
public Action Timer_InstantPlayForPosition(Handle hTimer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (g_szRoundStartRecPath[i][0] == '\0')
            continue;
        
        // 开始播放rec
        BotMimic_PlayRecordFromFile(i, g_szRoundStartRecPath[i]);
        
        // 0.1秒后停止
        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(i));
        CreateTimer(1.0, Timer_StopInstantPlay, pack, TIMER_FLAG_NO_MAPCHANGE);
    }
    
    return Plugin_Stop;
}

/**
 * 停止瞬间播放（定位）
 */
public Action Timer_StopInstantPlay(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    delete pack;
    
    int client = GetClientOfUserId(iUserId);
    if (!IsValidClient(client) || !BotMimic_IsPlayerMimicing(client))
        return Plugin_Stop;

    BotMimic_StopPlayerMimic(client);
    
    return Plugin_Stop;
}