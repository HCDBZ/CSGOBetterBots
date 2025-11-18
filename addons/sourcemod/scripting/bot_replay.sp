#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <botmimic>
#include <ripext>
#include <bot_pause>

#pragma newdecls required
#pragma semicolon 1

// ============================================================================
// 插件信息
// ============================================================================
public Plugin myinfo = 
{
	name = "Bot Round Start REC Player", 
	author = "Tasty cup", 
	description = "Play recordings for bots at round start", 
	version = "1.0.0", 
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
    BotState_PlayingREC,     // 正在播放REC
    BotState_Busy            // 忙碌状态
}

// 回合选择模式 (默认)
enum RoundSelectionMode
{
    Round_FullMatch = 0,    // 全局回合模式（按当前回合播放）
    Round_Economy          // 经济回合模式（根据经济选择）
}

// 经济选择模式
enum EconomySelectionMode
{
    Economy_SingleTeam = 0,     // 单队经济模式（默认）
    Economy_BothTeams = 1      // 双队经济模式
}

// 混合算法核心数据结构
// Bot经济信息
enum struct BotEconomyInfo
{
    int client;              // Bot客户端索引
    int money;               // 当前金钱
    int teamIndex;           // 在队伍中的索引(0-4)
    int assignedRecIndex;    // 分配的REC索引
    int assignedCost;        // 分配的REC成本
    int assignedValue;       // 分配的REC价值
    char assignedRecName[PLATFORM_MAX_PATH];  // 分配的REC名称
}

// REC装备信息
enum struct RecEquipmentInfo
{
    char recName[PLATFORM_MAX_PATH];  // REC文件名
    int totalCost;           // 总成本
    int totalValue;          // 总价值
    int tacticalValue;       // 战术价值(加权)
    bool hasPrimary;         // 是否有主武器
    bool hasSniper;          // 是否有狙击枪
    bool hasRifle;           // 是否有步枪
    int utilityCount;        // 道具数量
    char primaryWeapon[64];  // 主武器名称
}

// 背包DP结果
enum struct KnapsackResult
{
    int totalValue;          // 总装备价值
    int totalCost;           // 总花费
    bool isValid;            // 是否有效
    int assignment[MAXPLAYERS+1];  // 每个Bot分配的REC索引(-1表示未分配)
}

// Bot状态
bool g_bPlayingRoundStartRec[MAXPLAYERS+1];           // 是否正在播放REC
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

// SDK偏移量
int g_BotShared_EnemyVisibleOffset = -1;    // 敌人可见偏移
int g_BotShared_EnemyOffset = -1;           // 敌人偏移

// 敌人缓存
int g_BotShared_CachedEnemy[MAXPLAYERS+1] = {-1, ...};        // 缓存的敌人
float g_BotShared_EnemyCacheTime[MAXPLAYERS+1] = {0.0, ...};  // 缓存时间

// ConVars
ConVar g_cvEconomyMode;
ConVar g_cvRoundMode;
ConVar g_cvEnableDrops;

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

// 购买数据（用于经济模式）
JSONObject g_jPurchaseData = null;
// C4持有者数据
JSONArray g_jC4HolderData = null;

// 购买系统
ArrayList g_hPurchaseActions[MAXPLAYERS+1];       // 每个bot的购买队列
int g_iPurchaseActionIndex[MAXPLAYERS+1];         // 当前购买动作索引
Handle g_hPurchaseTimer[MAXPLAYERS+1];            // 每个bot的购买timer
ArrayList g_hFinalInventory[MAXPLAYERS+1];        // 每个bot应该拥有的最终装备
bool g_bInventoryVerified[MAXPLAYERS+1];          // 是否已经验证装备
Handle g_hVerifyTimer[MAXPLAYERS+1];              // 装备验证定时器
bool g_bAllowPurchase[MAXPLAYERS+1];              // 标记是否允许购买（用于区分系统购买和手动购买）
ArrayList g_hDropActions[MAXPLAYERS+1];           // 每个bot的丢弃队列
int g_iDropActionIndex[MAXPLAYERS+1];             // 当前丢弃动作索引
Handle g_hDropTimer[MAXPLAYERS+1];                // 每个bot的丢弃timer

// 带包检测
Handle g_hBombCarrierCheckTimer = null;              // 带包检测timer

// 伤害检测
int g_iLastAttacker[MAXPLAYERS+1];                // 上次攻击者
int g_iLastDamageType[MAXPLAYERS+1];              // 上次伤害类型

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
        FCVAR_NOTIFY, true, 0.0, true, 1.0);  // 范围 0-1
    
    g_cvRoundMode = CreateConVar("sm_botrec_round_mode", "0", 
        "Round selection mode: 0=Full Match (default), 1=Economy Based", 
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvEnableDrops = CreateConVar("sm_botrec_enable_drops", "1",
        "Enable/disable weapon drop system: 0=Disabled, 1=Enabled",
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
        g_bInventoryVerified[i] = false;
        g_hVerifyTimer[i] = null;
        g_bAllowPurchase[i] = false;
        g_hDropTimer[i] = null;
        g_hDropActions[i] = null;
        g_iDropActionIndex[i] = 0;  

        // 初始化聊天数据 
        g_hChatTimer[i] = null;
        g_hChatActions[i] = null;
        g_iChatActionIndex[i] = 0;             
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
    // 清理购买数据
    if (g_jPurchaseData != null)
    {
        delete g_jPurchaseData;
        g_jPurchaseData = null;
    }
    
    // 清理带包检测timer
    if (g_hBombCarrierCheckTimer != null)
    {
        KillTimer(g_hBombCarrierCheckTimer);
        g_hBombCarrierCheckTimer = null;
    }
    
    // 清理聊天数据
    if (g_jChatData != null)
    {
        delete g_jChatData;
        g_jChatData = null;
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
    
    // 清理购买相关数据
    if (g_hPurchaseTimer[client] != null)
    {
        KillTimer(g_hPurchaseTimer[client]);
        g_hPurchaseTimer[client] = null;
    }
    
    if (g_hPurchaseActions[client] != null)
    {
        delete g_hPurchaseActions[client];
        g_hPurchaseActions[client] = null;
    }
    
    if (g_hVerifyTimer[client] != null)
    {
        KillTimer(g_hVerifyTimer[client]);
        g_hVerifyTimer[client] = null;
    }
    
    if (g_hFinalInventory[client] != null)
    {
        delete g_hFinalInventory[client];
        g_hFinalInventory[client] = null;
    }
    
    g_bAllowPurchase[client] = false;
    
    // 清理丢弃数据
    if (g_hDropTimer[client] != null)
    {
        KillTimer(g_hDropTimer[client]);
        g_hDropTimer[client] = null;
    }
    
    if (g_hDropActions[client] != null)
    {
        delete g_hDropActions[client];
        g_hDropActions[client] = null;
    }
    
    // 清理聊天数据
    if (g_hChatTimer[client] != null)
    {
        KillTimer(g_hChatTimer[client]);
        g_hChatTimer[client] = null;
    }
    
    if (g_hChatActions[client] != null)
    {
        delete g_hChatActions[client];
        g_hChatActions[client] = null;
    }
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
    BotShared_ResetBombState();
    
    // 从 ConVar 读取当前模式
    g_iEconomyMode = view_as<EconomySelectionMode>(g_cvEconomyMode.IntValue);
    g_iRoundMode = view_as<RoundSelectionMode>(g_cvRoundMode.IntValue);
    
    PrintToServer("[Bot REC] Round %d | Mode: %s | Economy: %s", 
        g_iCurrentRound,
        g_iRoundMode == Round_Economy ? "ECONOMY" : "FULL",
        g_iEconomyMode == Economy_SingleTeam ? "SINGLE" : "BOTH");
    
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    // 第一回合或中场后选择新的rec文件夹
    if (g_iCurrentRound == 0 || g_iCurrentRound == 15)
    {
        if (SelectRandomRecFolder(szMap))
        {
            PrintToServer("[Bot REC] Selected folder: %s", g_szCurrentRecFolder);
            LoadFreezeTimes(szMap, g_szCurrentRecFolder);
            LoadPurchaseDataFile(g_szCurrentRecFolder);
            LoadChatDataFile(g_szCurrentRecFolder);
        }
        else
        {
            g_szCurrentRecFolder[0] = '\0';
            g_bRecFolderSelected = false;
        }
    }
    else if (g_bRecFolderSelected && !g_bRoundFreezeTimeValid[g_iCurrentRound])
    {
        PrintToServer("[Bot REC] Freeze time not loaded for round %d, reloading...", g_iCurrentRound);
        LoadFreezeTimes(szMap, g_szCurrentRecFolder);
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
    }
    
    // 全局模式下的动态暂停系统
    PrintToServer("[Pause Debug] Checking pause conditions:");
    PrintToServer("[Pause Debug]   - Round mode: %s", g_iRoundMode == Round_FullMatch ? "FULL" : "ECONOMY");
    PrintToServer("[Pause Debug]   - Folder selected: %s", g_bRecFolderSelected ? "YES" : "NO");
    PrintToServer("[Pause Debug]   - Current round: %d", g_iCurrentRound);
    
    if (g_iRoundMode == Round_FullMatch && g_bRecFolderSelected)
    {
        PrintToServer("[Pause Debug] Calling ScheduleDynamicPause for round %d", g_iCurrentRound);
        ScheduleDynamicPause(g_iCurrentRound);
    }
    else
    {
        PrintToServer("[Pause Debug] Skipping pause (conditions not met)");
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
        // 0.1秒后执行，确保所有bot的REC都已分配完成
        CreateTimer(0.1, Timer_AssignC4AtFreezeStart, _, TIMER_FLAG_NO_MAPCHANGE);
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
    
    if (!IsValidClient(client) || !IsFakeClient(client))
        return;
    
    g_iAssignedRecIndex[client] = -1;
    g_bRecMoneySet[client] = false;
    g_bInventoryVerified[client] = false;  
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
            StopCTBotsRec_EconomyMode();
        }
        else if (g_iRoundMode == Round_FullMatch || 
                (g_iRoundMode == Round_Economy && g_iEconomyMode == Economy_BothTeams))
        {
            StopBotsRec_FullMatchMode();
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
                        // 增加额外验证
                        // 敌人必须"正在播放且仍在播放中"
                        if (g_bPlayingRoundStartRec[iEnemy] && BotMimic_IsPlayerMimicing(iEnemy))
                        {
                            bSeeEnemy = false;  // 敌人确实在播放，不停止
                            
                            // 添加调试日志
                            #if defined DEBUG_MODE
                            PrintToServer("[Debug] %d sees %d (both playing REC) - NOT stopping", 
                                client, iEnemy);
                            #endif
                        }
                        else
                        {
                            bSeeEnemy = BotShared_CanSeeEnemy(client);
                            
                            #if defined DEBUG_MODE
                            if (bSeeEnemy)
                                PrintToServer("[Debug] %d sees %d (enemy NOT playing) - stopping", 
                                    client, iEnemy);
                            #endif
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
                        
                        #if defined DEBUG_MODE
                        PrintToServer("[Debug] %d damaged by %d (attacker playing REC) - NOT stopping", 
                            client, iAttacker);
                        #endif
                    }
                    else
                    {
                        bShouldStopFromDamage = ShouldStopFromDamage(iDamage, g_iLastDamageType[client]);
                        
                        #if defined DEBUG_MODE
                        if (bShouldStopFromDamage)
                            PrintToServer("[Debug] %d damaged (attacker NOT playing) - stopping", 
                                client);
                        #endif
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
            
                char szName[MAX_NAME_LENGTH];
                GetClientName(client, szName, sizeof(szName));
            
                char szReason[64];
                if (bSeeEnemy) 
                    strcopy(szReason, sizeof(szReason), "saw enemy");
                else if (bShouldStopFromDamage) 
                    Format(szReason, sizeof(szReason), "took %d damage (type: %d)", 
                        iDamage, g_iLastDamageType[client]);
            
                PrintToServer("[Bot REC] Client %d (%s) stopped rec: %s", 
                    client, szName, szReason);
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
        PrintToServer("[Bot REC] Client %d finished round start rec", client);
        
        // 安全地停止购买timer
        if (g_hPurchaseTimer[client] != null)
        {
            KillTimer(g_hPurchaseTimer[client]);
            g_hPurchaseTimer[client] = null;  
        }
        
        // 清理购买动作数据
        if (g_hPurchaseActions[client] != null)
        {
            delete g_hPurchaseActions[client];
            g_hPurchaseActions[client] = null;
        }
        g_iPurchaseActionIndex[client] = 0;
        
        // 安全地停止验证timer
        if (g_hVerifyTimer[client] != null)
        {
            KillTimer(g_hVerifyTimer[client]);
            g_hVerifyTimer[client] = null; 
        }

        // 安全地停止丢弃timer
        if (g_hDropTimer[client] != null)
        {
            KillTimer(g_hDropTimer[client]);
            g_hDropTimer[client] = null;  
        }
        
        // 清理丢弃动作
        if (g_hDropActions[client] != null)
        {
            delete g_hDropActions[client];
            g_hDropActions[client] = null;
        }
        g_iDropActionIndex[client] = 0;
        
        // 安全地停止聊天timer
        if (g_hChatTimer[client] != null)
        {
            KillTimer(g_hChatTimer[client]);
            g_hChatTimer[client] = null;
        }
        
        // 清理聊天动作
        if (g_hChatActions[client] != null)
        {
            delete g_hChatActions[client];
            g_hChatActions[client] = null;
        }
        g_iChatActionIndex[client] = 0;
        
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
    
    PrintToServer("[Bot REC] Processing bot %d (%s)", client, szBotName);
    
    char szRecPath[PLATFORM_MAX_PATH];
    bool bFoundRec = false;
    int iRoundToUse = g_iCurrentRound;
    
    // 根据模式选择rec
    if (g_bEconomyBasedSelection)
    {
        int iTeam = GetClientTeam(client);
        int iSelectedRound = g_iSelectedRoundForTeam[iTeam];
        
        if (iSelectedRound != -1)
        {
            iRoundToUse = iSelectedRound;
            bFoundRec = GetRoundStartRecForRound(client, iSelectedRound, szRecPath, sizeof(szRecPath));
            PrintToServer("[Bot REC] [Economy Mode] Bot %d using selected round %d", client, iSelectedRound);
        }
        else
        {
            PrintToServer("[Bot REC] [Economy Mode] Bot %d: No round selected for team %d", client, iTeam);
        }
    }
    else
    {
        bFoundRec = GetRoundStartRec(client, g_iCurrentRound, szRecPath, sizeof(szRecPath));
        PrintToServer("[Bot REC] [Full Match Mode] Bot %d using current round %d", client, g_iCurrentRound);
    }
    
    if (bFoundRec)
    {
        strcopy(g_szRoundStartRecPath[client], sizeof(g_szRoundStartRecPath[]), szRecPath);
        
        PrintToServer("[Bot REC] Bot %d assigned rec: %s, rec_index: %d, round: %d", 
            client, szRecPath, g_iAssignedRecIndex[client], iRoundToUse);
        
        // 设置金钱 只在全局模式下设置
        if (g_iRoundMode == Round_FullMatch && !g_bRecMoneySet[client] && g_iRecStartMoney[client] > 0)
        {
            SetEntProp(client, Prop_Send, "m_iAccount", g_iRecStartMoney[client]);
            g_bRecMoneySet[client] = true;
            PrintToServer("[Bot REC] [Full Match] Bot %d money set to: %d", client, g_iRecStartMoney[client]);
        }
        else if (g_iRoundMode == Round_Economy)
        {
            int iCurrentMoney = GetEntProp(client, Prop_Send, "m_iAccount");
            PrintToServer("[Bot REC] [Economy] Bot %d keeping current money: $%d", client, iCurrentMoney);
        }
        
        // 加载购买数据
        bool bPurchaseLoaded = LoadPurchaseActionsForBot(client, iRoundToUse);
        PrintToServer("[Bot REC] Bot %d purchase data loaded: %s", 
            client, bPurchaseLoaded ? "YES" : "NO");
        
        if (bPurchaseLoaded)
        {
            // 清理旧的购买timer
            if (g_hPurchaseTimer[client] != null)
            {
                KillTimer(g_hPurchaseTimer[client]);
                g_hPurchaseTimer[client] = null;
            }
            
            // 创建购买执行timer
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            g_hPurchaseTimer[client] = CreateTimer(0.1, Timer_ExecutePurchaseAction, pack, 
                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
            
            PrintToServer("[Bot REC] Bot %d purchase timer started", client);
        }

        // 加载聊天数据
        bool bChatLoaded = LoadChatActionsForBot(client, iRoundToUse);
        PrintToServer("[Bot REC] Bot %d chat data loaded: %s", 
            client, bChatLoaded ? "YES" : "NO");
        
        if (bChatLoaded)
        {
            // 清理旧的聊天timer
            if (g_hChatTimer[client] != null)
            {
                KillTimer(g_hChatTimer[client]);
                g_hChatTimer[client] = null;
            }
            
            // 创建聊天执行timer
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            g_hChatTimer[client] = CreateTimer(0.1, Timer_ExecuteChatAction, pack, 
                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
            
            PrintToServer("[Bot REC] Bot %d chat timer started", client);
        }
        
        // 开始播放REC
        g_bPlayingRoundStartRec[client] = true;
        float fGameTime = GetGameTime();
        g_fRecStartTime[client] = fGameTime;
        
        PrintToServer("[Bot REC] Bot %d REC start time set to: %.2f", client, fGameTime);
        
        BotMimic_PlayRecordFromFile(client, szRecPath);
        
        // Hook伤害
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);

        // 设置Bot状态为播放REC
        BotShared_SetBotState(client, BotState_PlayingREC);
        
        PrintToServer("[Bot REC] Bot %d playing rec, start_time: %.1f", 
            client, g_fRecStartTime[client]);
    }
    else
    {
        PrintToServer("[Bot REC] Bot %d: No rec found for round %d", client, iRoundToUse);
    }
}

// ============================================================================
// REC文件选择
// ============================================================================

bool SelectRandomRecFolder(const char[] szMap)
{
    char szMapBasePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/all/%s", szMap);
    
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
    
    int iTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    // 使用bot专属的demo文件夹
    char szUseDemoFolder[PLATFORM_MAX_PATH];
    
    if (g_szBotRecFolder[client][0] != '\0')
    {
        strcopy(szUseDemoFolder, sizeof(szUseDemoFolder), g_szBotRecFolder[client]);
    }
    else if (g_bRecFolderSelected && g_szCurrentRecFolder[0] != '\0')
    {
        strcopy(szUseDemoFolder, sizeof(szUseDemoFolder), g_szCurrentRecFolder);
    }
    else
    {
        return false;
    }
    
    char szRoundPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szRoundPath, sizeof(szRoundPath), "data/botmimic/all/%s/%s/round%d/%s", 
        szMap, szUseDemoFolder, iRound + 1, szTeamName);
    
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
        
        // 如果找不到匹配的REC文件，打印警告并返回false
        PrintToServer("[Bot REC] WARNING: Assigned REC '%s' not found for client %d", 
            szAssignedRecName, client);
        delete hRecFiles;
        return false;
    }
    else if (g_bEconomyBasedSelection)
    {
        // 经济模式下，如果找不到分配列表，返回false
        PrintToServer("[Bot REC] WARNING: No assigned REC name for client %d in economy mode", client);
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
            if (GetClientTeam(i) == iTeam && g_iAssignedRecIndex[i] != -1)
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
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    int iTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    // 使用demo专属的money配置
    char szUseDemoFolder[PLATFORM_MAX_PATH];
    
    if (g_szBotRecFolder[client][0] != '\0')
    {
        strcopy(szUseDemoFolder, sizeof(szUseDemoFolder), g_szBotRecFolder[client]);
    }
    else if (g_bRecFolderSelected && g_szCurrentRecFolder[0] != '\0')
    {
        strcopy(szUseDemoFolder, sizeof(szUseDemoFolder), g_szCurrentRecFolder);
    }
    else
    {
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    char szJsonPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szJsonPath, sizeof(szJsonPath), 
        "data/botmimic/all/%s/%s/money.json", szMap, szUseDemoFolder);
    
    if (!FileExists(szJsonPath))
    {
        PrintToServer("[Bot Money] File not found: %s", szJsonPath);
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    JSONObject jRoot = JSONObject.FromFile(szJsonPath);
    if (jRoot == null)
    {
        PrintToServer("[Bot Money] Failed to parse JSON");
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return false;
    }
    
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
    
    if (!jRoot.HasKey(szRoundKey))
    {
        PrintToServer("[Bot Money] No data for %s", szRoundKey);
        delete jRoot;
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    JSONObject jRound = view_as<JSONObject>(jRoot.Get(szRoundKey));
    if (!jRound.HasKey(szTeamName))
    {
        PrintToServer("[Bot Money] Round %s has no data for team %s", szRoundKey, szTeamName);
        delete jRound;
        delete jRoot;
        g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
        return true;
    }
    
    JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
    
    // 使用REC名称获取金钱(新格式)
    if (g_szCurrentRecName[client][0] != '\0' && jTeam.HasKey(g_szCurrentRecName[client]))
    {
        g_iRecStartMoney[client] = jTeam.GetInt(g_szCurrentRecName[client]);
        
        char szBotName[MAX_NAME_LENGTH];
        GetClientName(client, szBotName, sizeof(szBotName));
        PrintToServer("[Bot Money] Client %d (%s) using REC name '%s': $%d", 
            client, szBotName, g_szCurrentRecName[client], g_iRecStartMoney[client]);
        
        delete jTeam;
        delete jRound;
        delete jRoot;
        return true;
    }
    
    // 失败则使用默认值
    PrintToServer("[Bot Money] WARNING: No money data found for client %d (rec: '%s'), using default", 
        client, g_szCurrentRecName[client]);
    
    delete jTeam;
    delete jRound;
    delete jRoot;
    
    g_iRecStartMoney[client] = g_bEconomyBasedSelection ? GetEntProp(client, Prop_Send, "m_iAccount") : 16000;
    return true;
}

// ============================================================================
// 经济模式 - 回合选择
// ============================================================================

void SelectRoundByEconomy(int iTeam)
{
    char szTeamName[4];
    if (iTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return;
    
    // 收集该队伍所有bot并按经济排序
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
        PrintToServer("[Economy Hybrid] No bots in team %s", szTeamName);
        return;
    }
    
    // 按经济从低到高排序
    SortADTArrayCustom(hTeamBots, Sort_BotsByMoney);
    
    // 计算团队总经济
    int iTotalMoney = 0;
    for (int i = 0; i < iBotCount; i++)
    {
        int client = hTeamBots.Get(i);
        iTotalMoney += GetEntProp(client, Prop_Send, "m_iAccount");
    }
    
    PrintToServer("[Economy Hybrid] Team %s - Bot count: %d, Total money: $%d", 
        szTeamName, iBotCount, iTotalMoney);
    
    // 判断是否所有bot经济都小于3000
    bool bAllUnder3000 = true;
    for (int i = 0; i < iBotCount; i++)
    {
        int client = hTeamBots.Get(i);
        if (GetEntProp(client, Prop_Send, "m_iAccount") >= 3000)
        {
            bAllUnder3000 = false;
            break;
        }
    }
    
    // 判断当前是否手枪局
    bool bCurrentIsPistol = IsCurrentRoundPistol();
    
    PrintToServer("[Economy Hybrid] Team %s - All under $3000: %s, Current is pistol: %s",
        szTeamName, bAllUnder3000 ? "YES" : "NO", bCurrentIsPistol ? "YES" : "NO");
    
    // 获取地图和所有demo文件夹
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szMapBasePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/all/%s", szMap);
    
    if (!DirExists(szMapBasePath))
    {
        PrintToServer("[Economy Hybrid] ERROR: Map path does not exist: %s", szMapBasePath);
        delete hTeamBots;
        return;
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
    
    PrintToServer("[Economy Hybrid] Found %d demo folders", hDemoFolders.Length);
    
    int iBestRound = -1;
    char szBestDemo[PLATFORM_MAX_PATH];
    int iBestValue = bAllUnder3000 ? 999999 : 0;
    KnapsackResult bestResult;
    bestResult.isValid = false;
    
    int iValidRoundsChecked = 0;
    int iRoundsWithData = 0;
    
    for (int d = 0; d < hDemoFolders.Length; d++)
    {
        char szDemoFolder[PLATFORM_MAX_PATH];
        hDemoFolders.GetString(d, szDemoFolder, sizeof(szDemoFolder));
        
        PrintToServer("[Economy Hybrid] Checking demo folder: %s", szDemoFolder);
        
        // 加载该demo的freeze时间
        float fDemoFreezeTimes[31];
        bool bDemoFreezeValid[31];
        if (!LoadFreezeTimesForDemo(szMap, szDemoFolder, fDemoFreezeTimes, bDemoFreezeValid))
        {
            PrintToServer("[Economy Hybrid]   - No valid freeze times, skipping");
            continue;
        }
        
        // 加载该demo的购买数据
        JSONObject jDemoPurchaseData = LoadPurchaseDataForDemo(szMap, szDemoFolder);
        if (jDemoPurchaseData == null)
        {
            PrintToServer("[Economy Hybrid]   - No purchase data, skipping");
            continue;
        }
        
        // 扫描该demo的所有回合
        for (int iRound = 0; iRound <= 30; iRound++)
        {
            if (!bDemoFreezeValid[iRound])
                continue;
            
            iValidRoundsChecked++;
            
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
            
            iRoundsWithData++;
            
            JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
            
            // 获取该回合的REC文件列表
            ArrayList hRecFiles = GetRecFilesForRound(szMap, szDemoFolder, iRound, szTeamName);
            if (hRecFiles.Length == 0)
            {
                PrintToServer("[Economy Hybrid]   - Round %d: No REC files found", iRound + 1);
                delete hRecFiles;
                delete jTeam;
                delete jRound;
                continue;
            }
            
            PrintToServer("[Economy Hybrid]   - Round %d: Found %d REC files", 
                iRound + 1, hRecFiles.Length);
            
            // 构建REC装备信息缓存
            ArrayList hRecInfoList = BuildRecEquipmentCache(hRecFiles, jTeam, iTeam);
            
            if (hRecInfoList.Length == 0)
            {
                PrintToServer("[Economy Hybrid]   - Round %d: No valid REC info", iRound + 1);
                delete hRecInfoList;
                delete hRecFiles;
                delete jTeam;
                delete jRound;
                continue;
            }
            
            //  运行背包DP算法 
            KnapsackResult dpResult;
            dpResult = SolveKnapsackDP(hTeamBots, hRecInfoList, iTotalMoney);
            
            if (dpResult.isValid)
            {
                bool bIsBetter = false;
                
                if (bAllUnder3000)
                {
                    // 低经济:选择总价值最小的
                    if (dpResult.totalValue < iBestValue)
                        bIsBetter = true;
                }
                else
                {
                    // 高经济:选择总价值最大的
                    if (dpResult.totalValue > iBestValue)
                        bIsBetter = true;
                }
                
                if (bIsBetter)
                {
                    PrintToServer("[Economy Hybrid]   - Round %d: NEW BEST (value=%d, cost=$%d)",
                        iRound + 1, dpResult.totalValue, dpResult.totalCost);
                    
                    iBestRound = iRound;
                    strcopy(szBestDemo, sizeof(szBestDemo), szDemoFolder);
                    iBestValue = dpResult.totalValue;
                    bestResult = dpResult;
                }
            }
            else
            {
                PrintToServer("[Economy Hybrid]   - Round %d: DP result invalid", iRound + 1);
            }
            
            delete hRecInfoList;
            delete hRecFiles;
            delete jTeam;
            delete jRound;
        }
        
        delete jDemoPurchaseData;
    }
    
    PrintToServer("[Economy Hybrid] Team %s - Checked %d valid rounds, %d with data",
        szTeamName, iValidRoundsChecked, iRoundsWithData);
    
    if (iBestRound == -1)
    {
        PrintToServer("[Economy Hybrid] Team %s: NO affordable round found! (Checked %d demos)",
            szTeamName, hDemoFolders.Length);
        delete hDemoFolders;
        delete hTeamBots;
        return;
    }
    
    PrintToServer("[Economy Hybrid] Team %s: BEST ROUND = %d from demo '%s' (value=%d)",
        szTeamName, iBestRound + 1, szBestDemo, iBestValue);
    
    // 重新加载最佳回合的数据并打印详情
    ArrayList hBestRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, szTeamName);
    
    // 第二阶段:局部搜索优化
    JSONObject jBestPurchaseData = LoadPurchaseDataForDemo(szMap, szBestDemo);
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iBestRound + 1);
    JSONObject jBestRound = view_as<JSONObject>(jBestPurchaseData.Get(szRoundKey));
    JSONObject jBestTeam = view_as<JSONObject>(jBestRound.Get(szTeamName));
    
    hBestRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, szTeamName);
    ArrayList hBestRecInfoList = BuildRecEquipmentCache(hBestRecFiles, jBestTeam, iTeam);
    
    // 运行局部搜索优化
    KnapsackResult optimizedResult;
    optimizedResult = LocalSearchOptimize(bestResult, hTeamBots, hBestRecInfoList, iTotalMoney);
    
    // 虚拟发枪模拟与最终分配
    // 保存选择的回合和demo
    g_iSelectedRoundForTeam[iTeam] = iBestRound;
    strcopy(g_szSelectedDemoForTeam[iTeam], PLATFORM_MAX_PATH, szBestDemo);
    
    // 清理旧的分配列表
    if (g_hAssignedRecsForTeam[iTeam] != null)
        delete g_hAssignedRecsForTeam[iTeam];
    g_hAssignedRecsForTeam[iTeam] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    
    // 应用最终分配并模拟发枪
    int iTotalCost = 0;
    for (int b = 0; b < iBotCount; b++)
    {
        int client = hTeamBots.Get(b);
        int recIndex = optimizedResult.assignment[b];
        
        if (recIndex >= 0 && recIndex < hBestRecInfoList.Length)
        {
            RecEquipmentInfo recInfo;
            hBestRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            g_hAssignedRecsForTeam[iTeam].PushString(recInfo.recName);
            
            // 直接保存到bot专属变量
            strcopy(g_szAssignedRecName[client], PLATFORM_MAX_PATH, recInfo.recName);
            strcopy(g_szBotRecFolder[client], PLATFORM_MAX_PATH, szBestDemo);
            
            iTotalCost += recInfo.totalCost;
            
            char szBotName[MAX_NAME_LENGTH];
            GetClientName(client, szBotName, sizeof(szBotName));
            
            PrintToServer("[Economy Hybrid]   - Bot %d (%s): assigned '%s' (cost=$%d)",
                client, szBotName, recInfo.recName, recInfo.totalCost);
        }
    }
    
    PrintToServer("[Economy Hybrid] Team %s: Final total cost = $%d / $%d",
        szTeamName, iTotalCost, iTotalMoney);
    
    // 虚拟发枪模拟
    SimulateDropSystem(hTeamBots, optimizedResult, hBestRecInfoList);
    
    // 清理资源
    delete hBestRecInfoList;
    delete hBestRecFiles;
    delete jBestTeam;
    delete jBestRound;
    delete jBestPurchaseData;
    delete hDemoFolders;
    delete hTeamBots;
}

int SelectRoundByBothTeamsEconomy()
{
    PrintToServer("[Economy Both] ===== Starting Both Teams Economy Selection =====");
    
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    PrintToServer("[Economy Both] Current map: %s", szMap);
    
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
        PrintToServer("[Economy Both] ERROR: No bots found in either team!");
        delete hTBots;
        delete hCTBots;
        return g_iCurrentRound;
    }
    
    PrintToServer("[Economy Both] T bots: %d, CT bots: %d", iTBotCount, iCTBotCount);

    // 计算团队总经济
    int iTTotalMoney = 0;
    int iCTTotalMoney = 0;
    
    for (int i = 0; i < iTBotCount; i++)
    {
        int client = hTBots.Get(i);
        iTTotalMoney += GetEntProp(client, Prop_Send, "m_iAccount");
    }
    
    for (int i = 0; i < iCTBotCount; i++)
    {
        int client = hCTBots.Get(i);
        iCTTotalMoney += GetEntProp(client, Prop_Send, "m_iAccount");
    }
    
    // 判断是否所有bot经济都小于3000
    bool bAllUnder3000 = true;
    
    for (int i = 0; i < iTBotCount; i++)
    {
        int client = hTBots.Get(i);
        if (GetEntProp(client, Prop_Send, "m_iAccount") >= 3000)
        {
            bAllUnder3000 = false;
            break;
        }
    }
    
    if (bAllUnder3000)
    {
        for (int i = 0; i < iCTBotCount; i++)
        {
            int client = hCTBots.Get(i);
            if (GetEntProp(client, Prop_Send, "m_iAccount") >= 3000)
            {
                bAllUnder3000 = false;
                break;
            }
        }
    }
    
    // 判断当前是否手枪局
    bool bCurrentIsPistol = IsCurrentRoundPistol();
    
    // 获取所有demo文件夹
    char szMapBasePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/all/%s", szMap);
    
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
    
    // 扫描所有回合，使用背包DP找最优回合
    int iBestRound = -1;
    char szBestDemo[PLATFORM_MAX_PATH];
    int iBestTotalValue = bAllUnder3000 ? 999999 : 0;
    KnapsackResult bestTResult;
    KnapsackResult bestCTResult;
    bestTResult.isValid = false;
    bestCTResult.isValid = false;
    
    for (int d = 0; d < hDemoFolders.Length; d++)
    {
        char szDemoFolder[PLATFORM_MAX_PATH];
        hDemoFolders.GetString(d, szDemoFolder, sizeof(szDemoFolder));
        
        // 加载该demo的freeze时间
        float fDemoFreezeTimes[31];
        bool bDemoFreezeValid[31];
        LoadFreezeTimesForDemo(szMap, szDemoFolder, fDemoFreezeTimes, bDemoFreezeValid);
        
        // 加载该demo的购买数据
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
            
            // 为T队运行背包DP
            KnapsackResult tResult;
            tResult.isValid = false;
            
            if (iTBotCount > 0 && jRound.HasKey("T"))
            {
                JSONObject jTeamT = view_as<JSONObject>(jRound.Get("T"));
                
                ArrayList hTRecFiles = GetRecFilesForRound(szMap, szDemoFolder, iRound, "T");
                
                if (hTRecFiles.Length > 0)
                {
                    ArrayList hTRecInfoList = BuildRecEquipmentCache(hTRecFiles, jTeamT, CS_TEAM_T);
                    tResult = SolveKnapsackDP(hTBots, hTRecInfoList, iTTotalMoney);
                    delete hTRecInfoList;
                }
                
                delete hTRecFiles;
                delete jTeamT;
            }
            else if (iTBotCount > 0)
            {
                // T队没有数据，视为无效
                tResult.isValid = false;
            }
            else
            {
                // 没有T bot，自动通过
                tResult.isValid = true;
                tResult.totalValue = 0;
            }
            
            // 为CT队运行背包DP 
            KnapsackResult ctResult;
            ctResult.isValid = false;
            
            if (iCTBotCount > 0 && jRound.HasKey("CT"))
            {
                JSONObject jTeamCT = view_as<JSONObject>(jRound.Get("CT"));
                
                ArrayList hCTRecFiles = GetRecFilesForRound(szMap, szDemoFolder, iRound, "CT");
                
                if (hCTRecFiles.Length > 0)
                {
                    ArrayList hCTRecInfoList = BuildRecEquipmentCache(hCTRecFiles, jTeamCT, CS_TEAM_CT);
                    ctResult = SolveKnapsackDP(hCTBots, hCTRecInfoList, iCTTotalMoney);
                    delete hCTRecInfoList;
                }
                
                delete hCTRecFiles;
                delete jTeamCT;
            }
            else if (iCTBotCount > 0)
            {
                // CT队没有数据，视为无效
                ctResult.isValid = false;
            }
            else
            {
                // 没有CT bot，自动通过
                ctResult.isValid = true;
                ctResult.totalValue = 0;
            }
            
            delete jRound;
            
            // 如果双方都有有效解
            if (tResult.isValid && ctResult.isValid)
            {
                int iTotalValue = tResult.totalValue + ctResult.totalValue;
                bool bIsBetter = false;
                
                if (bAllUnder3000)
                {
                    // 低经济：选择总价值最小的
                    if (iTotalValue < iBestTotalValue)
                        bIsBetter = true;
                }
                else
                {
                    // 高经济：选择总价值最大的
                    if (iTotalValue > iBestTotalValue)
                        bIsBetter = true;
                }
                
                if (bIsBetter)
                {
                    iBestRound = iRound;
                    strcopy(szBestDemo, sizeof(szBestDemo), szDemoFolder);
                    iBestTotalValue = iTotalValue;
                    bestTResult = tResult;
                    bestCTResult = ctResult;
                }
            }
        }
        
        delete jDemoPurchaseData;
    }
    
    delete hDemoFolders;
    
    if (iBestRound == -1)
    {
        PrintToServer("[Economy Both] No affordable round found!");
        delete hTBots;
        delete hCTBots;
        return g_iCurrentRound;
    }
    
    // 第二阶段：局部搜索优化 
    // 重新加载最佳回合的数据
    JSONObject jBestPurchaseData = LoadPurchaseDataForDemo(szMap, szBestDemo);
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iBestRound + 1);
    JSONObject jBestRound = view_as<JSONObject>(jBestPurchaseData.Get(szRoundKey));
    
    // 复制T队结果
    KnapsackResult optimizedTResult;
    optimizedTResult.isValid = bestTResult.isValid;
    optimizedTResult.totalValue = bestTResult.totalValue;
    optimizedTResult.totalCost = bestTResult.totalCost;
    for (int i = 0; i <= MAXPLAYERS; i++)
        optimizedTResult.assignment[i] = bestTResult.assignment[i];

    // 复制CT队结果
    KnapsackResult optimizedCTResult;
    optimizedCTResult.isValid = bestCTResult.isValid;
    optimizedCTResult.totalValue = bestCTResult.totalValue;
    optimizedCTResult.totalCost = bestCTResult.totalCost;
    for (int i = 0; i <= MAXPLAYERS; i++)
        optimizedCTResult.assignment[i] = bestCTResult.assignment[i];
    
    // 为T队优化
    if (iTBotCount > 0 && jBestRound.HasKey("T"))
    {
        JSONObject jTeamT = view_as<JSONObject>(jBestRound.Get("T"));
        ArrayList hTRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, "T");
        ArrayList hTRecInfoList = BuildRecEquipmentCache(hTRecFiles, jTeamT, CS_TEAM_T);
        
        optimizedTResult = LocalSearchOptimize(bestTResult, hTBots, hTRecInfoList, iTTotalMoney);
        
        delete hTRecInfoList;
        delete hTRecFiles;
        delete jTeamT;
    }
    
    // 为CT队优化
    if (iCTBotCount > 0 && jBestRound.HasKey("CT"))
    {
        JSONObject jTeamCT = view_as<JSONObject>(jBestRound.Get("CT"));
        ArrayList hCTRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, "CT");
        ArrayList hCTRecInfoList = BuildRecEquipmentCache(hCTRecFiles, jTeamCT, CS_TEAM_CT);
        
        optimizedCTResult = LocalSearchOptimize(bestCTResult, hCTBots, hCTRecInfoList, iCTTotalMoney);
        
        delete hCTRecInfoList;
        delete hCTRecFiles;
        delete jTeamCT;
    }
    
    // 第三阶段：应用最终分配 
    // 保存选择的demo和回合
    strcopy(g_szCurrentRecFolder, sizeof(g_szCurrentRecFolder), szBestDemo);
    g_iSelectedRoundForTeam[CS_TEAM_T] = iBestRound;
    g_iSelectedRoundForTeam[CS_TEAM_CT] = iBestRound;
    strcopy(g_szSelectedDemoForTeam[CS_TEAM_T], PLATFORM_MAX_PATH, szBestDemo);
    strcopy(g_szSelectedDemoForTeam[CS_TEAM_CT], PLATFORM_MAX_PATH, szBestDemo);
    
    // 清理旧分配列表
    if (g_hAssignedRecsForTeam[CS_TEAM_T] != null)
        delete g_hAssignedRecsForTeam[CS_TEAM_T];
    if (g_hAssignedRecsForTeam[CS_TEAM_CT] != null)
        delete g_hAssignedRecsForTeam[CS_TEAM_CT];
    
    g_hAssignedRecsForTeam[CS_TEAM_T] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_hAssignedRecsForTeam[CS_TEAM_CT] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    
    // 为T队应用分配
    if (iTBotCount > 0 && jBestRound.HasKey("T"))
    {
        JSONObject jTeamT = view_as<JSONObject>(jBestRound.Get("T"));
        ArrayList hTRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, "T");
        ArrayList hTRecInfoList = BuildRecEquipmentCache(hTRecFiles, jTeamT, CS_TEAM_T);
        
        for (int b = 0; b < iTBotCount; b++)
        {
            int client = hTBots.Get(b);
            int recIndex = optimizedTResult.assignment[b];
            
            if (recIndex >= 0 && recIndex < hTRecInfoList.Length)
            {
                RecEquipmentInfo recInfo;
                hTRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
                
                g_hAssignedRecsForTeam[CS_TEAM_T].PushString(recInfo.recName);
                
                // 直接保存到bot专属变量
                strcopy(g_szAssignedRecName[client], PLATFORM_MAX_PATH, recInfo.recName);
                strcopy(g_szBotRecFolder[client], PLATFORM_MAX_PATH, szBestDemo);
                
                char szBotName[MAX_NAME_LENGTH];
                GetClientName(client, szBotName, sizeof(szBotName));
            }
        }
        
        // 虚拟发枪模拟
        SimulateDropSystem(hTBots, optimizedTResult, hTRecInfoList);
        
        delete hTRecInfoList;
        delete hTRecFiles;
        delete jTeamT;
    }
    
    // 为CT队应用分配
    if (iCTBotCount > 0 && jBestRound.HasKey("CT"))
    {
        JSONObject jTeamCT = view_as<JSONObject>(jBestRound.Get("CT"));
        ArrayList hCTRecFiles = GetRecFilesForRound(szMap, szBestDemo, iBestRound, "CT");
        ArrayList hCTRecInfoList = BuildRecEquipmentCache(hCTRecFiles, jTeamCT, CS_TEAM_CT);
        
        for (int b = 0; b < iCTBotCount; b++)
        {
            int client = hCTBots.Get(b);
            int recIndex = optimizedCTResult.assignment[b];
            
            if (recIndex >= 0 && recIndex < hCTRecInfoList.Length)
            {
                RecEquipmentInfo recInfo;
                hCTRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
                
                g_hAssignedRecsForTeam[CS_TEAM_CT].PushString(recInfo.recName);
                
                // 直接保存到bot专属变量
                strcopy(g_szAssignedRecName[client], PLATFORM_MAX_PATH, recInfo.recName);
                strcopy(g_szBotRecFolder[client], PLATFORM_MAX_PATH, szBestDemo);
                
                char szBotName[MAX_NAME_LENGTH];
                GetClientName(client, szBotName, sizeof(szBotName));
            }
        }
        
        // 虚拟发枪模拟
        SimulateDropSystem(hCTBots, optimizedCTResult, hCTRecInfoList);
        
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
// 停止REC播放
// ============================================================================

void StopCTBotsRec_EconomyMode()
{
    int iStoppedCount = 0;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_CT)
            continue;
        
        if (g_bPlayingRoundStartRec[i] && BotMimic_IsPlayerMimicing(i))
        {
            BotMimic_StopPlayerMimic(i);
            g_bPlayingRoundStartRec[i] = false;
            iStoppedCount++;
            
            PrintToServer("[Bot REC] CT bot %d stopped REC after bomb plant", i);
        }
    }
    
    if (iStoppedCount > 0)
    {
        PrintToServer("[Bot REC] Stopped %d CT bots after bomb plant", iStoppedCount);
    }
}

void StopBotsRec_FullMatchMode()
{
    int iTCount = GetAliveTeamCount(CS_TEAM_T);
    int iCTCount = GetAliveTeamCount(CS_TEAM_CT);
    int iDifference = iTCount - iCTCount;
    
    PrintToServer("[Bot REC] Full Match Mode: T=%d, CT=%d, Diff=%d", 
        iTCount, iCTCount, iDifference);
    
    // 如果 T 方人数大于 CT 2人或以上，不停止
    if (iDifference >= 2)
    {
        PrintToServer("[Bot REC] T has 2+ more players, keeping REC");
        return;
    }
    
    // 否则停止所有 CT bot 的 REC
    int iStoppedCount = 0;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_CT)
            continue;
        
        if (g_bPlayingRoundStartRec[i] && BotMimic_IsPlayerMimicing(i))
        {
            BotMimic_StopPlayerMimic(i);
            g_bPlayingRoundStartRec[i] = false;
            iStoppedCount++;
        }
    }
    
    if (iStoppedCount > 0)
    {
        PrintToServer("[Bot REC] Stopped %d CT bots", iStoppedCount);
    }
}

// ============================================================================
// 数据加载
// ============================================================================

bool LoadPurchaseDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/all/%s/%s/purchases.json", szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        PrintToServer("[Bot REC] Purchase data file not found: %s", szPath);
        return false;
    }
    
    // 清理旧数据
    if (g_jPurchaseData != null)
        delete g_jPurchaseData;
    
    // 加载JSON
    g_jPurchaseData = JSONObject.FromFile(szPath);
    if (g_jPurchaseData == null)
    {
        PrintToServer("[Bot REC] Failed to parse purchase data JSON");
        return false;
    }
    
    PrintToServer("[Bot REC] Loaded purchase data from: %s", szPath);
    return true;
}

bool LoadFreezeTimes(const char[] szMap, const char[] szRecFolder)
{
    char szFreezePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szFreezePath, sizeof(szFreezePath), 
        "data/botmimic/all/%s/%s/freeze.txt", szMap, szRecFolder);
    
    PrintToServer("[Freeze Loader] ===== LoadFreezeTimes CALLED =====");
    PrintToServer("[Freeze Loader] Map: %s", szMap);
    PrintToServer("[Freeze Loader] Folder: %s", szRecFolder);
    PrintToServer("[Freeze Loader] Path: %s", szFreezePath);
    
    // 初始化所有回合为无效
    for (int i = 0; i < sizeof(g_bRoundFreezeTimeValid); i++)
    {
        // 经济系统用（有tolerance检查）
        g_bRoundFreezeTimeValid[i] = false;
        g_fValidRoundFreezeTimes[i] = 0.0;
        
        // 暂停系统用（无检查）
        g_bAllRoundFreezeTimeValid[i] = false;
        g_fAllRoundFreezeTimes[i] = 0.0;
    }
    
    g_fStandardFreezeTime = 20.0;
    
    if (!FileExists(szFreezePath))
    {
        PrintToServer("[Freeze Loader] ✗ File not found: %s", szFreezePath);
        return false;
    }
    
    File hFile = OpenFile(szFreezePath, "r");
    if (hFile == null)
    {
        PrintToServer("[Freeze Loader] ✗ Failed to open file");
        return false;
    }
    
    char szLine[128];
    int iValidRoundsForEconomy = 0;
    int iValidRoundsForPause = 0;
    const float TOLERANCE = 2.0;
    int iLineNumber = 0;
    
    PrintToServer("[Freeze Loader] Parsing file...");
    
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
                
                PrintToServer("[Freeze Loader] Found standard freeze time = %.2f", g_fStandardFreezeTime);
            }
            break;
        }
    }
    
    // 重置文件指针到开头
    delete hFile;
    hFile = OpenFile(szFreezePath, "r");
    if (hFile == null)
    {
        PrintToServer("[Freeze Loader] ✗ Failed to reopen file");
        return false;
    }
    
    // 第二遍扫描：解析回合数据
    iLineNumber = 0;
    while (hFile.ReadLine(szLine, sizeof(szLine)))
    {
        iLineNumber++;
        TrimString(szLine);
        
        // 跳过空行和注释
        if (strlen(szLine) == 0 || szLine[0] == '/' || szLine[0] == '#')
        {
            PrintToServer("[Freeze Loader] Line %d: Skipped (empty/comment)", iLineNumber);
            continue;
        }
        
        // 跳过标准时间定义行
        if (StrContains(szLine, "冻结时间", false) != -1 || 
            StrContains(szLine, "standard", false) != -1 ||
            StrContains(szLine, "freeze", false) != -1)
        {
            PrintToServer("[Freeze Loader] Line %d: Skipped (standard time definition)", iLineNumber);
            continue;
        }
        
        // 解析回合时间: "round1: 20.5" 或 "1: 20.5"
        char szParts[2][64];
        int iParts = ExplodeString(szLine, ":", szParts, sizeof(szParts), sizeof(szParts[]));
        
        if (iParts < 2)
        {
            PrintToServer("[Freeze Loader] Line %d: Invalid format (no colon): %s", 
                iLineNumber, szLine);
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
            PrintToServer("[Freeze Loader] Line %d: Invalid round number: %d (must be 1-30)", 
                iLineNumber, iRoundNum);
            continue;
        }
        
        // 解析冻结时间
        TrimString(szParts[1]);
        ReplaceString(szParts[1], sizeof(szParts[]), "秒", "");
        ReplaceString(szParts[1], sizeof(szParts[]), "s", "", false);
        float fFreezeTime = StringToFloat(szParts[1]);
        
        if (fFreezeTime <= 0.0)
        {
            PrintToServer("[Freeze Loader] Line %d: Invalid freeze time: %.2f", 
                iLineNumber, fFreezeTime);
            continue;
        }
        
        // 数组索引 = 回合号 - 1
        int iArrayIndex = iRoundNum - 1;
        
        // 分别处理两个系统 
        
        // 1. 暂停系统：无条件加载所有时间
        g_bAllRoundFreezeTimeValid[iArrayIndex] = true;
        g_fAllRoundFreezeTimes[iArrayIndex] = fFreezeTime;
        iValidRoundsForPause++;
        
        PrintToServer("[Freeze Loader] Line %d: [PAUSE] Round %d (index %d) = %.2f seconds", 
            iLineNumber, iRoundNum, iArrayIndex, fFreezeTime);
        
        // 2. 经济系统：只加载tolerance范围内的时间
        float fDifference = FloatAbs(fFreezeTime - g_fStandardFreezeTime);
        
        if (fDifference <= TOLERANCE)
        {
            g_bRoundFreezeTimeValid[iArrayIndex] = true;
            g_fValidRoundFreezeTimes[iArrayIndex] = fFreezeTime;
            iValidRoundsForEconomy++;
            
            PrintToServer("[Freeze Loader] Line %d: [ECONOMY] ✓ Round %d (index %d) = %.2f seconds (diff: %.2f)", 
                iLineNumber, iRoundNum, iArrayIndex, fFreezeTime, fDifference);
        }
        else
        {
            PrintToServer("[Freeze Loader] Line %d: [ECONOMY] ✗ Round %d rejected (freeze: %.2f, standard: %.2f, diff: %.2f > tolerance: %.2f)", 
                iLineNumber, iRoundNum, fFreezeTime, g_fStandardFreezeTime, fDifference, TOLERANCE);
        }
    }
    
    delete hFile;
    
    PrintToServer("[Freeze Loader] ===== PARSING COMPLETE =====");
    PrintToServer("[Freeze Loader] Total lines: %d", iLineNumber);
    PrintToServer("[Freeze Loader] Valid rounds for PAUSE system: %d", iValidRoundsForPause);
    PrintToServer("[Freeze Loader] Valid rounds for ECONOMY system: %d", iValidRoundsForEconomy);
    PrintToServer("[Freeze Loader] Standard freeze time: %.2f seconds", g_fStandardFreezeTime);
    
    // 打印暂停系统的摘要
    if (iValidRoundsForPause > 0)
    {
        PrintToServer("[Freeze Loader] Pause system rounds:");
        for (int i = 0; i < 31; i++)
        {
            if (g_bAllRoundFreezeTimeValid[i])
            {
                PrintToServer("[Freeze Loader]   - Index %d (round%d): %.2f seconds", 
                    i, i + 1, g_fAllRoundFreezeTimes[i]);
            }
        }
    }
    
    // 打印经济系统的摘要
    if (iValidRoundsForEconomy > 0)
    {
        PrintToServer("[Freeze Loader] Economy system rounds:");
        for (int i = 0; i < 31; i++)
        {
            if (g_bRoundFreezeTimeValid[i])
            {
                PrintToServer("[Freeze Loader]   - Index %d (round%d): %.2f seconds", 
                    i, i + 1, g_fValidRoundFreezeTimes[i]);
            }
        }
    }
    
    return (iValidRoundsForPause > 0 || iValidRoundsForEconomy > 0);
}

// 聊天
bool LoadChatDataFile(const char[] szRecFolder)
{
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/all/%s/%s/chat.json", szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        PrintToServer("[Bot Chat] Chat data file not found: %s", szPath);
        return false;
    }
    
    // 清理旧数据
    if (g_jChatData != null)
        delete g_jChatData;
    
    // 加载JSON
    g_jChatData = view_as<JSONArray>(JSONArray.FromFile(szPath));
    if (g_jChatData == null)
    {
        PrintToServer("[Bot Chat] Failed to parse chat data JSON");
        return false;
    }
    
    PrintToServer("[Bot Chat] Loaded chat data from: %s (messages: %d)", 
        szPath, g_jChatData.Length);
    return true;
}

bool LoadChatActionsForBot(int client, int iRound)
{
    if (g_jChatData == null)
    {
        PrintToServer("[Bot Chat] No chat data loaded");
        return false;
    }
    
    // 获取bot的REC名称
    if (g_szCurrentRecName[client][0] == '\0')
    {
        PrintToServer("[Bot Chat] Client %d has no rec name assigned", client);
        return false;
    }
    
    char szBotRecName[PLATFORM_MAX_PATH];
    strcopy(szBotRecName, sizeof(szBotRecName), g_szCurrentRecName[client]);
    
    // 清理旧数据
    if (g_hChatActions[client] != null)
        delete g_hChatActions[client];
    
    g_hChatActions[client] = new ArrayList(ByteCountToCells(256));
    g_iChatActionIndex[client] = 0;
    
    int iChatCount = 0;
    int iTargetRound = iRound + 1;  // round1 = iRound 0
    
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
        
        // 构建聊天动作字符串: "时间|消息|是否队伍聊天"
        char szChatAction[256];
        Format(szChatAction, sizeof(szChatAction), "%.3f|%s|%d", 
            fTime, szMessage, bIsTeamChat ? 1 : 0);
        
        g_hChatActions[client].PushString(szChatAction);
        iChatCount++;
        
        PrintToServer("[Bot Chat]   Chat %d: %.2fs - %s (team=%d)", 
            iChatCount, fTime, szMessage, bIsTeamChat ? 1 : 0);
        
        delete jMessage;
    }
    
    PrintToServer("[Bot Chat] Loaded %d chat messages for client %d (rec: %s)", 
        iChatCount, client, szBotRecName);
    
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
    
    // 1. 如果是插件发起的购买(通过DelayedBuy),允许通过
    if (g_bAllowPurchase[client])
    {
        g_bAllowPurchase[client] = false;
        return Plugin_Continue;
    }
    
    // 2. 如果正在播放rec,拦截所有购买
    if (g_bPlayingRoundStartRec[client])
    {
        return Plugin_Handled;
    }
    
    // 3. 其他情况允许通过（让bot_stuff处理）
    return Plugin_Continue;
}

// 加载购买动作
bool LoadPurchaseActionsForBot(int client, int iRound)
{
    // 加载bot专属demo的购买数据
    char szMap[64];
    GetCurrentMap(szMap, sizeof(szMap));
    GetMapDisplayName(szMap, szMap, sizeof(szMap));
    
    JSONObject jUsePurchaseData = null;
    
    // 如果bot有专属demo，加载专属demo的购买数据
    if (g_szBotRecFolder[client][0] != '\0')
    {
        jUsePurchaseData = LoadPurchaseDataForDemo(szMap, g_szBotRecFolder[client]);
        if (jUsePurchaseData == null)
        {
            PrintToServer("[Bot Purchase] Failed to load purchase data for bot %d demo: %s", 
                client, g_szBotRecFolder[client]);
        }
    }
    
    // 如果没有专属数据，使用全局数据
    if (jUsePurchaseData == null)
    {
        jUsePurchaseData = g_jPurchaseData;
    }
    
    if (jUsePurchaseData == null)
    {
        PrintToServer("[Bot Purchase] ERROR: No purchase data for client %d", client);
        return false;
    }
    
    // 获取队伍信息
    int iTeam = GetClientTeam(client);
    char szTeamName[4];
    
    if (iTeam == CS_TEAM_T)
        strcopy(szTeamName, sizeof(szTeamName), "T");
    else if (iTeam == CS_TEAM_CT)
        strcopy(szTeamName, sizeof(szTeamName), "CT");
    else
        return false;
    
    // 获取bot名称
    char szBotName[MAX_NAME_LENGTH];
    GetClientName(client, szBotName, sizeof(szBotName));
    
    // 构建回合键
    char szRoundKey[32];
    Format(szRoundKey, sizeof(szRoundKey), "round%d", iRound + 1);
    
    // 使用正确的数据源
    if (!jUsePurchaseData.HasKey(szRoundKey))
    {
        PrintToServer("[Bot Purchase] ERROR: No purchase data for %s", szRoundKey);
        
        // 清理临时数据
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    JSONObject jRound = view_as<JSONObject>(jUsePurchaseData.Get(szRoundKey));
    if (!jRound.HasKey(szTeamName))
    {
        PrintToServer("[Bot Purchase] ERROR: Round %s has no data for team %s", 
            szRoundKey, szTeamName);
        delete jRound;
        
        // 清理临时数据
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    JSONObject jTeam = view_as<JSONObject>(jRound.Get(szTeamName));
    
    // 使用rec文件名而不是索引
    if (g_szCurrentRecName[client][0] == '\0')
    {
        PrintToServer("[Bot Purchase] ERROR: Client %d has no rec name assigned", client);
        delete jTeam;
        delete jRound;
        
        // 清理临时数据
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    if (!jTeam.HasKey(g_szCurrentRecName[client]))
    {
        PrintToServer("[Bot Purchase] ERROR: Team %s has no data for rec name '%s'", 
            szTeamName, g_szCurrentRecName[client]);
        delete jTeam;
        delete jRound;
        
        // 清理临时数据
        if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
            delete jUsePurchaseData;
        
        return false;
    }
    
    JSONObject jBotData = view_as<JSONObject>(jTeam.Get(g_szCurrentRecName[client]));
    
    // 清理旧数据
    if (g_hPurchaseActions[client] != null)
        delete g_hPurchaseActions[client];
    if (g_hFinalInventory[client] != null)
        delete g_hFinalInventory[client];
    
    g_hPurchaseActions[client] = new ArrayList(ByteCountToCells(128));
    g_hFinalInventory[client] = new ArrayList(ByteCountToCells(64));
    g_iPurchaseActionIndex[client] = 0;

    // 初始化丢弃数据
    if (g_hDropActions[client] != null)
        delete g_hDropActions[client];
    g_hDropActions[client] = new ArrayList(ByteCountToCells(128));
    g_iDropActionIndex[client] = 0;
    
    int iPurchaseCount = 0;
    int iDropCount = 0;
    
    // 加载购买动作和丢弃动作
    if (jBotData.HasKey("purchases"))
    {
        JSONArray jPurchases = view_as<JSONArray>(jBotData.Get("purchases"));
        
        PrintToServer("[Bot Purchase] Found %d purchase actions for client %d", 
            jPurchases.Length, client);
        
        for (int i = 0; i < jPurchases.Length; i++)
        {
            JSONObject jAction = view_as<JSONObject>(jPurchases.Get(i));
    
            // 获取动作类型
            char szAction[32];
            jAction.GetString("action", szAction, sizeof(szAction));
            
            // 处理购买动作
            if (StrEqual(szAction, "purchased", false))
            {
                float fTime = jAction.GetFloat("time");
                char szItem[64], szSlot[32];
                jAction.GetString("item", szItem, sizeof(szItem));
                jAction.GetString("slot", szSlot, sizeof(szSlot));
                
                char szActionStr[128];
                Format(szActionStr, sizeof(szActionStr), "%.1f|%s|%s", fTime, szItem, szSlot);
                g_hPurchaseActions[client].PushString(szActionStr);
                
                PrintToServer("[Bot Purchase]   Action %d: BUY %s at %.2fs", i, szItem, fTime);
                iPurchaseCount++;
            }
            // 处理丢弃动作
            else if (StrEqual(szAction, "dropped", false))
            {
                float fTime = jAction.GetFloat("time");
                char szItem[64], szSlot[32];
                jAction.GetString("item", szItem, sizeof(szItem));
                jAction.GetString("slot", szSlot, sizeof(szSlot));
                
                char szDropStr[128];
                Format(szDropStr, sizeof(szDropStr), "%.1f|%s|%s", fTime, szItem, szSlot);
                g_hDropActions[client].PushString(szDropStr);
                
                iDropCount++;
            }
    
            delete jAction;
        }
        
        delete jPurchases;
    }
    
    // 加载最终装备清单
    int iInventoryCount = 0;
    if (jBotData.HasKey("final_inventory"))
    {
        JSONArray jInventory = view_as<JSONArray>(jBotData.Get("final_inventory"));
        
        PrintToServer("[Bot Purchase] Loading final inventory for client %d:", client);
        
        for (int i = 0; i < jInventory.Length; i++)
        {
            char szItem[64];
            jInventory.GetString(i, szItem, sizeof(szItem));
            g_hFinalInventory[client].PushString(szItem);
            
            PrintToServer("[Bot Purchase]   Inventory %d: %s", i, szItem);
            iInventoryCount++;
        }
        
        delete jInventory;
    }
    
    delete jBotData;
    delete jTeam;
    delete jRound;
    
    // 设置装备验证定时器 - 在冻结时间50%时触发
    ConVar cvFreezeTime = FindConVar("mp_freezetime");
    if (cvFreezeTime != null)
    {
        float fFreezeTime = cvFreezeTime.FloatValue;
        
        if (fFreezeTime > 3.0 && g_hFinalInventory[client].Length > 0)
        {
            // 在冻结时间的50%时开始验证
            float fVerifyDelay = fFreezeTime * 0.5;
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            g_hVerifyTimer[client] = CreateTimer(fVerifyDelay, Timer_VerifyInventory, pack);
            
            PrintToServer("[Bot Purchase] Verify timer set for client %d: delay=%.2fs", 
                client, fVerifyDelay);
        }
        else
        {
            PrintToServer("[Bot Purchase] NOT setting verify timer: freezetime=%.1f, inventory_count=%d", 
                fFreezeTime, g_hFinalInventory[client] != null ? g_hFinalInventory[client].Length : 0);
        }
    }
    else
    {
        PrintToServer("[Bot Purchase] ERROR: mp_freezetime cvar not found!");
    }
    
    // 如果有丢弃动作且功能已启用，启动丢弃timer
    if (iDropCount > 0 && g_cvEnableDrops.BoolValue) 
    {
        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(client));
        g_hDropTimer[client] = CreateTimer(0.1, Timer_ExecuteDropAction, pack, 
            TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    
        PrintToServer("[Bot Drop] Bot %d drop timer started with %d actions", client, iDropCount);
    }
    
    // 如果使用的是临时加载的数据，需要删除
    if (jUsePurchaseData != g_jPurchaseData && jUsePurchaseData != null)
    {
        delete jUsePurchaseData;
    }
    
    PrintToServer("[Bot Purchase] Summary for client %d: purchases=%d, drops=%d, final_inventory=%d", 
        client, iPurchaseCount, iDropCount, iInventoryCount);
    
    return (iPurchaseCount > 0 || iDropCount > 0 || iInventoryCount > 0);
}

// 执行购买动作的定时器
public Action Timer_ExecutePurchaseAction(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    int client = GetClientOfUserId(iUserId);
    if (!IsValidClient(client))
    {
        g_hPurchaseTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    if (!g_bPlayingRoundStartRec[client])
    {
        g_hPurchaseTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    if (g_hPurchaseActions[client] == null)
    {
        g_hPurchaseTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    bool bInBuyZone = !!GetEntProp(client, Prop_Send, "m_bInBuyZone");
    float fCurrentTime = GetGameTime() - g_fRecStartTime[client];
    int iTeam = GetClientTeam(client);
    
    // 调试日志
    static int iDebugCount[MAXPLAYERS+1];
    iDebugCount[client]++;
    if (iDebugCount[client] <= 3)  // 只打印前3次
    {
        PrintToServer("[Bot Purchase DEBUG] Client %d: InBuyZone=%d, CurrentTime=%.2f, RecStartTime=%.2f, ActionsCount=%d, CurrentIndex=%d", 
            client, bInBuyZone, fCurrentTime, g_fRecStartTime[client], 
            g_hPurchaseActions[client].Length, g_iPurchaseActionIndex[client]);
    }
    
    if (!bInBuyZone)
        return Plugin_Continue;
    
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
        
        // 检查是否应该跳过此购买
        if (ShouldSkipPurchase(client, szOriginalItem))
        {
            PrintToServer("[Bot Purchase] Client %d skipping purchase: %s", client, szOriginalItem);
            g_iPurchaseActionIndex[client]++;
            continue;
        }
        
        // 转换对面阵营武器
        char szBuyItem[64];
        bool bNeedConvert = GetTeamSpecificWeapon(szOriginalItem, iTeam, szBuyItem, sizeof(szBuyItem));
        
        if (bNeedConvert)
        {
            PrintToServer("[Bot Purchase] Client %d converting '%s' to '%s'", 
                client, szOriginalItem, szBuyItem);
        }
        else
        {
            strcopy(szBuyItem, sizeof(szBuyItem), szOriginalItem);
        }
        
        // 执行购买
        g_bAllowPurchase[client] = true;
        
        PrintToServer("[Bot Purchase] Client %d buying: %s (converted from: %s) at time %.2f", 
            client, szBuyItem, szOriginalItem, fCurrentTime);
        
        FakeClientCommand(client, "buy %s", szBuyItem);
        
        CreateTimer(0.05, Timer_ResetPurchaseFlag, GetClientUserId(client));
        
        g_iPurchaseActionIndex[client]++;
        
        // 每次timer触发只执行一个购买动作,然后等待下次触发
        break;
    }
    
    if (g_iPurchaseActionIndex[client] >= g_hPurchaseActions[client].Length)
    {
        g_hPurchaseTimer[client] = null; 
        delete pack;
        return Plugin_Stop;
    }
    
    return Plugin_Continue;
}

public Action Timer_ResetPurchaseFlag(Handle hTimer, any iUserId)
{
    int client = GetClientOfUserId(iUserId);
    if (IsValidClient(client))
        g_bAllowPurchase[client] = false;
    
    return Plugin_Stop;
}

// 执行丢弃动作的定时器
public Action Timer_ExecuteDropAction(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    int client = GetClientOfUserId(iUserId);
    if (!IsValidClient(client))
    {
        g_hDropTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    if (!g_bPlayingRoundStartRec[client])
    {
        g_hDropTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    if (g_hDropActions[client] == null)
    {
        g_hDropTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    if (!IsPlayerAlive(client))
        return Plugin_Continue;
    
    float fCurrentTime = GetGameTime() - g_fRecStartTime[client];
    
    while (g_iDropActionIndex[client] < g_hDropActions[client].Length)
    {
        char szAction[128];
        g_hDropActions[client].GetString(g_iDropActionIndex[client], szAction, sizeof(szAction));
        
        char szParts[3][64];
        int iParts = ExplodeString(szAction, "|", szParts, sizeof(szParts), sizeof(szParts[]));
        
        if (iParts < 3)
        {
            g_iDropActionIndex[client]++;
            continue;
        }
        
        float fActionTime = StringToFloat(szParts[0]);
        
        if (fCurrentTime < fActionTime)
            break;
        
        char szItem[64];
        strcopy(szItem, sizeof(szItem), szParts[1]);
        
        // 查找并丢弃物品
        ExecuteDropAction(client, szItem);
        
        g_iDropActionIndex[client]++;
    }
    
    if (g_iDropActionIndex[client] >= g_hDropActions[client].Length)
    {
        g_hDropTimer[client] = null;  
        delete pack;
        return Plugin_Stop;
    }
    
    return Plugin_Continue;
}

//聊天计时器
public Action Timer_ExecuteChatAction(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    int client = GetClientOfUserId(iUserId);
    if (!IsValidClient(client))
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
        
        // 执行聊天
        if (bIsTeamChat)
        {
            FakeClientCommand(client, "say_team %s", szMessage);
        }
        else
        {
            FakeClientCommand(client, "say %s", szMessage);
        }
        
        char szBotName[MAX_NAME_LENGTH];
        GetClientName(client, szBotName, sizeof(szBotName));
        PrintToServer("[Bot Chat] %s said: %s (team=%d)", 
            szBotName, szMessage, bIsTeamChat ? 1 : 0);
        
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
// 带包检测和捡枪系统
// ============================================================================

// 检查带包T是否在播放REC
public Action Timer_CheckBombCarrier(Handle hTimer)
{
    g_hBombCarrierCheckTimer = null;
    
    // 查找带包的T
    int iBombCarrier = -1;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        // 检查是否带C4
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
        PrintToServer("[Bot REC] No bomb carrier found at 90s check");
        return Plugin_Stop;
    }
    
    // 如果带包T正在播放REC，停止它
    if (g_bPlayingRoundStartRec[iBombCarrier] && BotMimic_IsPlayerMimicing(iBombCarrier))
    {
        char szName[MAX_NAME_LENGTH];
        GetClientName(iBombCarrier, szName, sizeof(szName));
        
        BotMimic_StopPlayerMimic(iBombCarrier);
        g_bPlayingRoundStartRec[iBombCarrier] = false;
        
        PrintToServer("[Bot REC] Stopped bomb carrier (client %d: %s) REC at 90 seconds", 
            iBombCarrier, szName);
    }
    else
    {
        PrintToServer("[Bot REC] Bomb carrier (client %d) is not playing REC", iBombCarrier);
    }
    
    return Plugin_Stop;
}

// 执行丢弃操作
void ExecuteDropAction(int client, const char[] szItem)
{
    // 查找物品所在槽位
    int iWeaponEntity = -1;
    char szWeaponClass[64];
    Format(szWeaponClass, sizeof(szWeaponClass), "weapon_%s", szItem);
    
    // 检查所有槽位
    for (int slot = 0; slot <= 4; slot++)
    {
        int iWeapon = GetPlayerWeaponSlot(client, slot);
        if (IsValidEntity(iWeapon))
        {
            char szClass[64];
            GetEntityClassname(iWeapon, szClass, sizeof(szClass));
            
            if (StrEqual(szClass, szWeaponClass, false))
            {
                iWeaponEntity = iWeapon;
                break;
            }
        }
    }
    
    if (iWeaponEntity == -1)
    {
        return;
    }
    
    // 执行丢弃
    SDKHooks_DropWeapon(client, iWeaponEntity);
}

// 验证装备完整性
public Action Timer_VerifyInventory(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    delete pack;
    
    int client = GetClientOfUserId(iUserId);
    
    // 先清空 timer 句柄,避免重复 Kill
    g_hVerifyTimer[client] = null;
    
    if (!IsValidClient(client))
    {
        return Plugin_Stop;
    }
    
    if (g_bInventoryVerified[client])
    {
        return Plugin_Stop;
    }
    
    if (g_hFinalInventory[client] == null)
    {
        return Plugin_Stop;
    }
    
    int iTeam = GetClientTeam(client);
    
    // 收集当前装备
    ArrayList hCurrentInventory = new ArrayList(ByteCountToCells(64));
    CollectCurrentInventory(client, hCurrentInventory);
    
    // 验证其他装备
    int iMissingCount = 0;
    for (int i = 0; i < g_hFinalInventory[client].Length; i++)
    {
        char szRequiredItem[64];
        g_hFinalInventory[client].GetString(i, szRequiredItem, sizeof(szRequiredItem));
        
        // 忽略默认手枪
        if (IsDefaultPistol(szRequiredItem))
            continue;
        
        // 检查是否应该跳过
        if (ShouldSkipPurchase(client, szRequiredItem))
            continue;
        
        bool bHasItem = IsItemInInventory(hCurrentInventory, szRequiredItem);
        
        if (!bHasItem)
        {
            // 转换对面阵营武器
            char szBuyItem[64];
            GetTeamSpecificWeapon(szRequiredItem, iTeam, szBuyItem, sizeof(szBuyItem));
            
            // 尝试购买,如果失败则降级
            BuyItemWithFallback(client, szBuyItem, 0.1 + (iMissingCount * 0.2));
            iMissingCount++;
        }
    }
    
    delete hCurrentInventory;
    
    g_bInventoryVerified[client] = true;
    
    return Plugin_Stop;
}

// 带降级机制的购买函数
void BuyItemWithFallback(int client, const char[] szItem, float fDelay)
{
    if (IsDefaultPistol(szItem))
        return;
    
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(szItem);
    
    CreateTimer(fDelay, Timer_BuyItemWithFallback, pack);
}

public Action Timer_BuyItemWithFallback(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    char szItem[64];
    pack.ReadString(szItem, sizeof(szItem));
    delete pack;
    
    int client = GetClientOfUserId(iUserId);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client))
        return Plugin_Stop;
    
    bool bInBuyZone = !!GetEntProp(client, Prop_Send, "m_bInBuyZone");
    
    if (!bInBuyZone)
        return Plugin_Stop;
    
    int iMoney = GetEntProp(client, Prop_Send, "m_iAccount");
    int iPrice = GetItemPrice(szItem);
    
    // 如果买得起,直接购买
    if (iMoney >= iPrice)
    {
        g_bAllowPurchase[client] = true;
        FakeClientCommand(client, "buy %s", szItem);
        CreateTimer(0.05, Timer_ResetPurchaseFlag, GetClientUserId(client));
        
        return Plugin_Stop;
    }
    
    // 买不起,尝试降级
    char szFallback[64];
    if (GetFallbackWeapon(szItem, iMoney, szFallback, sizeof(szFallback)))
    {
        g_bAllowPurchase[client] = true;
        FakeClientCommand(client, "buy %s", szFallback);
        CreateTimer(0.05, Timer_ResetPurchaseFlag, GetClientUserId(client));
        
        PrintToServer("[Bot Purchase] Client %d downgraded: %s -> %s ($%d)", 
            client, szItem, szFallback, GetItemPrice(szFallback));
    }
    else
    {
        PrintToServer("[Bot Purchase] Client %d cannot afford %s ($%d) and no fallback available", 
            client, szItem, iPrice);
    }
    
    return Plugin_Stop;
}

// 获取降级武器
bool GetFallbackWeapon(const char[] szItem, int iMoney, char[] szFallback, int iMaxLen)
{
    // 狙击枪降级链: AWP -> SSG08
    if (StrEqual(szItem, "awp", false))
    {
        if (iMoney >= 1700) { strcopy(szFallback, iMaxLen, "ssg08"); return true; }
    }
    else if (StrEqual(szItem, "scar20", false))
    {
        if (iMoney >= 4750) { strcopy(szFallback, iMaxLen, "awp"); return true; }
        if (iMoney >= 1700) { strcopy(szFallback, iMaxLen, "ssg08"); return true; }
    }
    else if (StrEqual(szItem, "g3sg1", false))
    {
        if (iMoney >= 4750) { strcopy(szFallback, iMaxLen, "awp"); return true; }
        if (iMoney >= 1700) { strcopy(szFallback, iMaxLen, "ssg08"); return true; }
    }
    
    // 步枪降级链: AK47/M4 -> FAMAS/Galil -> SMG
    if (StrEqual(szItem, "ak47", false))
    {
        if (iMoney >= 2000) { strcopy(szFallback, iMaxLen, "galilar"); return true; }
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
        if (iMoney >= 1050) { strcopy(szFallback, iMaxLen, "mac10"); return true; }
    }
    else if (StrEqual(szItem, "m4a1", false) || StrEqual(szItem, "m4a1_silencer", false))
    {
        if (iMoney >= 2250) { strcopy(szFallback, iMaxLen, "famas"); return true; }
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
        if (iMoney >= 1250) { strcopy(szFallback, iMaxLen, "mp9"); return true; }
    }
    else if (StrEqual(szItem, "aug", false))
    {
        if (iMoney >= 3100) { strcopy(szFallback, iMaxLen, "m4a1"); return true; }
        if (iMoney >= 2250) { strcopy(szFallback, iMaxLen, "famas"); return true; }
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
    }
    else if (StrEqual(szItem, "sg556", false))
    {
        if (iMoney >= 2700) { strcopy(szFallback, iMaxLen, "ak47"); return true; }
        if (iMoney >= 2000) { strcopy(szFallback, iMaxLen, "galilar"); return true; }
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
    }
    else if (StrEqual(szItem, "famas", false))
    {
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
        if (iMoney >= 1250) { strcopy(szFallback, iMaxLen, "mp9"); return true; }
    }
    else if (StrEqual(szItem, "galilar", false))
    {
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
        if (iMoney >= 1050) { strcopy(szFallback, iMaxLen, "mac10"); return true; }
    }
    
    // SMG降级链
    if (StrEqual(szItem, "p90", false))
    {
        if (iMoney >= 1500) { strcopy(szFallback, iMaxLen, "mp7"); return true; }
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
    }
    else if (StrEqual(szItem, "mp7", false))
    {
        if (iMoney >= 1200) { strcopy(szFallback, iMaxLen, "ump45"); return true; }
    }
    
    // 护甲降级: vesthelm -> vest
    if (StrEqual(szItem, "vesthelm", false))
    {
        if (iMoney >= 650) { strcopy(szFallback, iMaxLen, "vest"); return true; }
    }
    
    return false;
}

public Action Timer_BuyMissingItem(Handle hTimer, DataPack pack)
{
    pack.Reset();
    int iUserId = pack.ReadCell();
    
    char szItem[64];
    pack.ReadString(szItem, sizeof(szItem));
    delete pack;
    
    int client = GetClientOfUserId(iUserId);
    
    bool bInBuyZone = !!GetEntProp(client, Prop_Send, "m_bInBuyZone");
    
    if (!bInBuyZone)
        return Plugin_Stop;
    
    g_bAllowPurchase[client] = true;
    FakeClientCommand(client, "buy %s", szItem);
    CreateTimer(0.05, Timer_ResetPurchaseFlag, GetClientUserId(client));
    
    return Plugin_Stop;
}

// 收集当前装备
void CollectCurrentInventory(int client, ArrayList hInventory)
{
    // 主武器
    int iPrimary = GetPlayerWeaponSlot(client, CS_SLOT_PRIMARY);
    if (IsValidEntity(iPrimary))
    {
        char szClass[64];
        GetEntityClassname(iPrimary, szClass, sizeof(szClass));
        ReplaceString(szClass, sizeof(szClass), "weapon_", "");
        hInventory.PushString(szClass);
    }
    
    // 副武器
    int iSecondary = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
    if (IsValidEntity(iSecondary))
    {
        char szClass[64];
        GetEntityClassname(iSecondary, szClass, sizeof(szClass));
        ReplaceString(szClass, sizeof(szClass), "weapon_", "");
        hInventory.PushString(szClass);
    }
    
    // 检查所有手雷
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
    
    // 护甲
    int iArmor = GetEntProp(client, Prop_Send, "m_ArmorValue");
    bool bHasHelmet = !!GetEntProp(client, Prop_Send, "m_bHasHelmet");
    
    if (iArmor > 0)
    {
        if (bHasHelmet)
            hInventory.PushString("vesthelm");
        else
            hInventory.PushString("vest");
    }
    
    // 拆弹器
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
    
    if (iSlot == -1)
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
    
    // 主手:如果要购买狙击枪
    if (iSlot == CS_SLOT_PRIMARY && IsSniperWeapon(szItem))
    {
        if (IsSniperWeapon(szExistingClass))
            return true;
        return false;
    }
    
    // 主手:如果当前持有狙击枪,要购买的不是狙击枪
    if (iSlot == CS_SLOT_PRIMARY && IsSniperWeapon(szExistingClass) && !IsSniperWeapon(szItem))
    {
        return true;
    }
    
    // 主手:如果已有非默认武器,跳过
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
    char szEconomyMode[64], szRoundMode[64];
    
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
    // 伤害太小，忽略（5点以下）
    if (iDamage < 5)
    {
        return false;
    }
    
    // 摔落伤害 - 不停止（已经在OnTakeDamage中阻止了）
    if (iDamageType & DMG_FALL)
    {
        return false;
    }
    
    // 手雷伤害 - 不停止
    if (iDamageType & DMG_BLAST)
    {
        return false;
    }
    
    // 燃烧伤害（火瓶/燃烧弹）- 5点以上才停止
    if (iDamageType & DMG_BURN)
    {
        if (iDamage < 5)
        {
            return false;
        }
        return true;
    }
    
    // 子弹伤害（直接攻击）- 必须停止
    if (iDamageType & DMG_BULLET)
    {
        return true;
    }
    
    // 其他直接伤害 - 必须停止
    return true;
}

// ============================================================================
// 判断是否为手枪局
// ============================================================================

bool IsPistolRound(int iRound)
{
    // round1(iRound=0) 和 round16(iRound=15) 是手枪局
    return (iRound == 0 || iRound == 15);
}

bool IsCurrentRoundPistol()
{
    return IsPistolRound(g_iCurrentRound);
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

/**
 * 获取武器所属槽位
 * 
 * @param szItem    物品名称（不含weapon_前缀）
 * @return          槽位索引（CS_SLOT_PRIMARY/SECONDARY），-1表示不是武器
 */
int GetWeaponSlotFromItem(const char[] szItem)
{
    // 主武器
    if (StrEqual(szItem, "ak47", false) || StrEqual(szItem, "m4a1", false) ||
        StrEqual(szItem, "m4a1_silencer", false) || StrEqual(szItem, "awp", false) ||
        StrEqual(szItem, "famas", false) || StrEqual(szItem, "galilar", false) ||
        StrEqual(szItem, "ssg08", false) || StrEqual(szItem, "aug", false) ||
        StrEqual(szItem, "sg556", false) || StrEqual(szItem, "mp9", false) ||
        StrEqual(szItem, "mac10", false) || StrEqual(szItem, "ump45", false) ||
        StrEqual(szItem, "p90", false) || StrEqual(szItem, "bizon", false) ||
        StrEqual(szItem, "mp7", false) || StrEqual(szItem, "scar20", false) ||
        StrEqual(szItem, "g3sg1", false) || StrEqual(szItem, "nova", false) ||
        StrEqual(szItem, "xm1014", false) || StrEqual(szItem, "mag7", false) ||
        StrEqual(szItem, "sawedoff", false) || StrEqual(szItem, "m249", false) ||
        StrEqual(szItem, "negev", false))
        return CS_SLOT_PRIMARY;
    
    // 副武器
    if (StrEqual(szItem, "deagle", false) || StrEqual(szItem, "usp_silencer", false) ||
        StrEqual(szItem, "glock", false) || StrEqual(szItem, "hkp2000", false) ||
        StrEqual(szItem, "p250", false) || StrEqual(szItem, "tec9", false) ||
        StrEqual(szItem, "fiveseven", false) || StrEqual(szItem, "cz75a", false) ||
        StrEqual(szItem, "elite", false) || StrEqual(szItem, "revolver", false))
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

// 为指定demo加载freeze时间
bool LoadFreezeTimesForDemo(const char[] szMap, const char[] szDemoFolder, float fFreezeTimes[31], bool bValid[31])
{
    char szFreezePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szFreezePath, sizeof(szFreezePath), 
        "data/botmimic/all/%s/%s/freeze.txt", szMap, szDemoFolder);
    
    // 初始化为无效
    for (int i = 0; i < 31; i++)
    {
        bValid[i] = false;
        fFreezeTimes[i] = 0.0;
    }
    
    if (!FileExists(szFreezePath))
        return false;
    
    File hFile = OpenFile(szFreezePath, "r");
    if (hFile == null)
        return false;
    
    char szLine[128];
    float fStandard = 20.0;
    const float TOLERANCE = 2.0;
    int iValidCount = 0;
    
    while (hFile.ReadLine(szLine, sizeof(szLine)))
    {
        TrimString(szLine);
        
        if (strlen(szLine) == 0 || szLine[0] == '/' || szLine[0] == '#')
            continue;
        
        // 检查标准时间
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
                fStandard = StringToFloat(szParts[1]);
            }
            continue;
        }
        
        // 解析回合时间
        char szParts[2][64];
        int iParts = ExplodeString(szLine, ":", szParts, sizeof(szParts), sizeof(szParts[]));
        if (iParts < 2)
            continue;
        
        TrimString(szParts[0]);
        int iRoundNum = -1;
        
        if (StrContains(szParts[0], "round", false) != -1)
        {
            ReplaceString(szParts[0], sizeof(szParts[]), "round", "", false);
            ReplaceString(szParts[0], sizeof(szParts[]), "Round", "", false);
            TrimString(szParts[0]);
            iRoundNum = StringToInt(szParts[0]);
        }
        else
        {
            iRoundNum = StringToInt(szParts[0]);
        }
        
        if (iRoundNum < 1 || iRoundNum > 30)
            continue;
        
        TrimString(szParts[1]);
        ReplaceString(szParts[1], sizeof(szParts[]), "秒", "");
        ReplaceString(szParts[1], sizeof(szParts[]), "s", "", false);
        float fFreezeTime = StringToFloat(szParts[1]);
        
        // 数组索引 = 回合号 - 1
        int iArrayIndex = iRoundNum - 1;
        
        // 经济系统用，需要tolerance检查
        float fDifference = FloatAbs(fFreezeTime - fStandard);
        if (fDifference <= TOLERANCE)
        {
            bValid[iArrayIndex] = true;
            fFreezeTimes[iArrayIndex] = fFreezeTime;
            iValidCount++;
        }
    }
    
    delete hFile;
    return (iValidCount > 0);
}

// 为指定demo加载购买数据
JSONObject LoadPurchaseDataForDemo(const char[] szMap, const char[] szDemoFolder)
{
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/all/%s/%s/purchases.json", szMap, szDemoFolder);
    
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
        BuildPath(Path_SM, szMapBasePath, sizeof(szMapBasePath), "data/botmimic/all/%s", szMap);
        
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
    
    char szDemoPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szDemoPath, sizeof(szDemoPath), "data/botmimic/all/%s/%s", szMap, szDemoFolder);
    
    if (!DirExists(szDemoPath))
    {
        ReplyToCommand(client, "[Bot REC] Demo folder '%s' not found!", szDemoFolder);
        return Plugin_Handled;
    }
    
    // 设置demo
    strcopy(g_szCurrentRecFolder, sizeof(g_szCurrentRecFolder), szDemoFolder);
    g_bRecFolderSelected = true;
    
    // 加载freeze时间
    if (LoadFreezeTimes(szMap, g_szCurrentRecFolder))
    {
        ReplyToCommand(client, "[Bot REC] ✓ Loaded freeze times for '%s'", szDemoFolder);
    }
    
    // 加载购买数据
    if (LoadPurchaseDataFile(g_szCurrentRecFolder))
    {
        ReplyToCommand(client, "[Bot REC] ✓ Loaded purchase data for '%s'", szDemoFolder);
    }
    
    ReplyToCommand(client, "[Bot REC] ✓ Demo folder set to: %s", szDemoFolder);
    ReplyToCommand(client, "[Bot REC] Use 'mp_restartgame 1' to apply changes");
    
    return Plugin_Handled;
}

// ============================================================================
// REC分配模拟/执行函数
// ============================================================================
KnapsackResult SolveKnapsackDP(ArrayList hBots, ArrayList hRecInfoList, int iTotalBudget)
{
    KnapsackResult result;
    result.isValid = false;
    result.totalValue = 0;
    result.totalCost = 0;
    
    for (int i = 0; i <= MAXPLAYERS; i++)
        result.assignment[i] = -1;
    
    int iBotCount = hBots.Length;
    int iRecCount = hRecInfoList.Length;
    
    if (iBotCount == 0 || iRecCount == 0)
        return result;
    
    int iMaxBudget = iTotalBudget;
    if (iMaxBudget > 80000)
        iMaxBudget = 80000;
    
    int iBudgetStep = 100;
    int iBudgetSize = (iMaxBudget / iBudgetStep) + 1;
    
    // 使用 ArrayList 代替多维数组
    ArrayList dpTable = new ArrayList(iBudgetSize);
    ArrayList choiceTable = new ArrayList(iBudgetSize);
    ArrayList usedRecsTable = new ArrayList(iBudgetSize);
    
    // 初始化表格 所有状态设为0 
    for (int i = 0; i <= iBotCount; i++)
    {
        ArrayList dpRow = new ArrayList();
        ArrayList choiceRow = new ArrayList();
        ArrayList usedRecsRow = new ArrayList(iBudgetSize);
        
        for (int b = 0; b < iBudgetSize; b++)
        {
            dpRow.Push(0);  // 全部初始化为0
            choiceRow.Push(-1);
            
            ArrayList usedRecs = new ArrayList();
            usedRecsRow.Push(usedRecs);
        }
        
        dpTable.Push(dpRow);
        choiceTable.Push(choiceRow);
        usedRecsTable.Push(usedRecsRow);
    }
    
    // DP填表逻辑 
    for (int i = 1; i <= iBotCount; i++)
    {       
        ArrayList currentDp = view_as<ArrayList>(dpTable.Get(i));
        ArrayList currentChoice = view_as<ArrayList>(choiceTable.Get(i));
        ArrayList currentUsedRecs = view_as<ArrayList>(usedRecsTable.Get(i));
        ArrayList prevDp = view_as<ArrayList>(dpTable.Get(i - 1));
        ArrayList prevUsedRecs = view_as<ArrayList>(usedRecsTable.Get(i - 1));
        
        for (int b = 0; b < iBudgetSize; b++)
        {
            int budget = b * iBudgetStep;
            
            // 先继承上一行的值 
            int inheritValue = prevDp.Get(b);
            currentDp.Set(b, inheritValue);
            
            // 复制上一行的已使用REC列表
            ArrayList inheritUsedList = view_as<ArrayList>(prevUsedRecs.Get(b));
            ArrayList currentUsedList = view_as<ArrayList>(currentUsedRecs.Get(b));
            delete currentUsedList;
            
            currentUsedList = new ArrayList();
            for (int u = 0; u < inheritUsedList.Length; u++)
            {
                currentUsedList.Push(inheritUsedList.Get(u));
            }
            currentUsedRecs.Set(b, currentUsedList);
            
            // 尝试为当前bot分配每个REC
            for (int r = 0; r < iRecCount; r++)
            {
                RecEquipmentInfo recInfo;
                hRecInfoList.GetArray(r, recInfo, sizeof(RecEquipmentInfo));
                
                int cost = recInfo.totalCost;
                int value = recInfo.tacticalValue;
                
                int prevBudgetIndex = (budget - cost) / iBudgetStep;
                
                if (budget >= cost && prevBudgetIndex >= 0 && prevBudgetIndex < iBudgetSize)
                {
                    int prevValue = prevDp.Get(prevBudgetIndex);
                    
                    // 检查该REC是否已被使用
                    ArrayList prevUsedList = view_as<ArrayList>(prevUsedRecs.Get(prevBudgetIndex));
                    bool bRecAlreadyUsed = (prevUsedList.FindValue(r) != -1);
                    
                    // 移除 prevValue >= 0 检查 
                    if (!bRecAlreadyUsed)
                    {
                        int newValue = prevValue + value;
                        int currentValue = currentDp.Get(b);
                        
                        if (newValue > currentValue)
                        {
                            currentDp.Set(b, newValue);
                            currentChoice.Set(b, r);
                            
                            // 更新已使用REC列表
                            ArrayList newUsedList = view_as<ArrayList>(currentUsedRecs.Get(b));
                            delete newUsedList;
                            
                            newUsedList = new ArrayList();
                            // 复制前一个状态的已使用列表
                            for (int u = 0; u < prevUsedList.Length; u++)
                            {
                                newUsedList.Push(prevUsedList.Get(u));
                            }
                            // 添加当前REC
                            newUsedList.Push(r);
                            
                            currentUsedRecs.Set(b, newUsedList);
                        }
                    }
                }
            }
        }
    }
    
    // 找最优解
    int bestBudgetIndex = -1;
    int bestValue = 0;  
    ArrayList lastDp = view_as<ArrayList>(dpTable.Get(iBotCount));
    
    for (int b = 0; b < iBudgetSize; b++)
    {
        int budget = b * iBudgetStep;
        int value = lastDp.Get(b);
        
        if (budget <= iTotalBudget && value > bestValue)
        {
            bestValue = value;
            bestBudgetIndex = b;
        }
    }
    
    // 只要有价值就算有效 
    if (bestBudgetIndex == -1 || bestValue <= 0)
    {    
        // 清理
        for (int i = 0; i <= iBotCount; i++)
        {
            delete view_as<ArrayList>(dpTable.Get(i));
            delete view_as<ArrayList>(choiceTable.Get(i));
            
            ArrayList usedRecsRow = view_as<ArrayList>(usedRecsTable.Get(i));
            for (int b = 0; b < iBudgetSize; b++)
            {
                delete view_as<ArrayList>(usedRecsRow.Get(b));
            }
            delete usedRecsRow;
        }
        delete dpTable;
        delete choiceTable;
        delete usedRecsTable;
        
        return result;
    }
    
    // 回溯解
    int currentBudgetIndex = bestBudgetIndex;
    int totalCost = 0;
    ArrayList usedRecIndices = new ArrayList();
    
    for (int i = iBotCount; i >= 1; i--)
    {
        ArrayList currentChoice = view_as<ArrayList>(choiceTable.Get(i));
        int recIndex = currentChoice.Get(currentBudgetIndex);
        result.assignment[i - 1] = recIndex;
        
        if (recIndex >= 0)
        {
            if (usedRecIndices.FindValue(recIndex) != -1)
            {
                // 检测到重复,但继续(后续会处理)
            }
            usedRecIndices.Push(recIndex);
            
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            int cost = recInfo.totalCost;
            totalCost += cost;
            
            int prevBudget = (currentBudgetIndex * iBudgetStep) - cost;
            currentBudgetIndex = prevBudget / iBudgetStep;
        }
    }
    
    delete usedRecIndices;
    
    // 标记为有效并设置结果
    result.isValid = true;
    result.totalValue = bestValue;
    result.totalCost = totalCost;
    
    // 清理
    for (int i = 0; i <= iBotCount; i++)
    {
        delete view_as<ArrayList>(dpTable.Get(i));
        delete view_as<ArrayList>(choiceTable.Get(i));
        
        ArrayList usedRecsRow = view_as<ArrayList>(usedRecsTable.Get(i));
        for (int b = 0; b < iBudgetSize; b++)
        {
            delete view_as<ArrayList>(usedRecsRow.Get(b));
        }
        delete usedRecsRow;
    }
    delete dpTable;
    delete choiceTable;
    delete usedRecsTable;
    
    return result;
}

// ============================================================================
// 局部搜索优化
// ============================================================================

KnapsackResult LocalSearchOptimize(KnapsackResult initial, ArrayList hBots, 
                                   ArrayList hRecInfoList, int iTotalBudget)
{
    KnapsackResult current;
    // 复制initial到current
    current.isValid = initial.isValid;
    current.totalValue = initial.totalValue;
    current.totalCost = initial.totalCost;
    for (int i = 0; i <= MAXPLAYERS; i++)
        current.assignment[i] = initial.assignment[i];
    
    int currentQuality = EvaluateAssignmentQuality(current, hBots, hRecInfoList);
    
    bool improved = true;
    int iteration = 0;
    const int MAX_ITERATIONS = 50;
    
    while (improved && iteration < MAX_ITERATIONS)
    {
        improved = false;
        iteration++;
        
        int iBotCount = hBots.Length;
        int iRecCount = hRecInfoList.Length;
        
        // 策略1:尝试两两交换Bot的REC分配
        for (int i = 0; i < iBotCount - 1; i++)
        {
            for (int j = i + 1; j < iBotCount; j++)
            {
                KnapsackResult candidate;
                // 复制current到candidate
                candidate.isValid = current.isValid;
                candidate.totalValue = current.totalValue;
                candidate.totalCost = current.totalCost;
                for (int k = 0; k <= MAXPLAYERS; k++)
                    candidate.assignment[k] = current.assignment[k];
                
                // 交换Bot i和Bot j的分配
                int temp = candidate.assignment[i];
                candidate.assignment[i] = candidate.assignment[j];
                candidate.assignment[j] = temp;
                
                RecalculateResult(candidate, hBots, hRecInfoList);
                
                if (candidate.totalCost > iTotalBudget)
                    continue;
                
                if (!CanTeamAfford(candidate, hBots, hRecInfoList))
                    continue;
                
                int candidateQuality = EvaluateAssignmentQuality(candidate, hBots, hRecInfoList);
                
                if (candidateQuality > currentQuality)
                {
                    // 验证唯一性
                    if (!ValidateAssignmentUniqueness(candidate, iBotCount))
                    {
                        continue;
                    }
                    // 复制candidate到current
                    current.isValid = candidate.isValid;
                    current.totalValue = candidate.totalValue;
                    current.totalCost = candidate.totalCost;
                    for (int k = 0; k <= MAXPLAYERS; k++)
                        current.assignment[k] = candidate.assignment[k];
                    
                    currentQuality = candidateQuality;
                    improved = true;
                }
            }
        }
        
        // 策略2:尝试单个Bot替换REC
        for (int i = 0; i < iBotCount; i++)
        {
            int originalRec = current.assignment[i];
            
            for (int r = 0; r < iRecCount; r++)
            {
                if (r == originalRec)
                    continue;
                
                // 检查这个REC是否已经被其他bot使用
                bool bRecInUse = false;
                for (int b = 0; b < iBotCount; b++)
                {
                    if (b != i && current.assignment[b] == r)
                    {
                        bRecInUse = true;
                        break;
                    }
                }
                
                if (bRecInUse)
                    continue;  // 跳过已使用的REC
                
                KnapsackResult candidate;
                candidate.isValid = current.isValid;
                candidate.totalValue = current.totalValue;
                candidate.totalCost = current.totalCost;
                for (int k = 0; k <= MAXPLAYERS; k++)
                    candidate.assignment[k] = current.assignment[k];
                
                candidate.assignment[i] = r;
                
                RecalculateResult(candidate, hBots, hRecInfoList);
                
                if (candidate.totalCost > iTotalBudget)
                    continue;
                
                if (!CanTeamAfford(candidate, hBots, hRecInfoList))
                    continue;
                
                int candidateQuality = EvaluateAssignmentQuality(candidate, hBots, hRecInfoList);
                
                if (candidateQuality > currentQuality)
                {
                    // 双重验证唯一性
                    if (!ValidateAssignmentUniqueness(candidate, iBotCount))
                    {
                        continue;
                    }
                    
                    current.isValid = candidate.isValid;
                    current.totalValue = candidate.totalValue;
                    current.totalCost = candidate.totalCost;
                    for (int k = 0; k <= MAXPLAYERS; k++)
                        current.assignment[k] = candidate.assignment[k];
                    
                    currentQuality = candidateQuality;
                    improved = true;
                }
            }
        }
    }
    
    return current;
}

// ============================================================================
// 质量评估函数（核心软约束）
// ============================================================================

int EvaluateAssignmentQuality(KnapsackResult result, ArrayList hBots, 
                              ArrayList hRecInfoList)
{
    int quality = result.totalValue;  // 基础分：装备总价值
    
    int iBotCount = hBots.Length;
    
    // 软约束1：惩罚装备价值分布不均 
    ArrayList values = new ArrayList();
    int totalValue = 0;
    
    for (int i = 0; i < iBotCount; i++)
    {
        int recIndex = result.assignment[i];
        if (recIndex >= 0)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            values.Push(recInfo.totalValue);
            totalValue += recInfo.totalValue;
        }
        else
        {
            values.Push(0);
        }
    }
    
    // 计算方差
    float avgValue = float(totalValue) / float(iBotCount);
    float variance = 0.0;
    
    for (int i = 0; i < iBotCount; i++)
    {
        float diff = float(values.Get(i)) - avgValue;
        variance += diff * diff;
    }
    variance /= float(iBotCount);
    
    // 方差越大扣分越多
    int variancePenalty = RoundFloat(variance / 100.0);
    quality -= variancePenalty;
    
    // 软约束2：奖励武器多样性 
    int primaryCount[10];  // 统计各类主武器数量
    for (int i = 0; i < 10; i++)
        primaryCount[i] = 0;
    
    for (int i = 0; i < iBotCount; i++)
    {
        int recIndex = result.assignment[i];
        if (recIndex >= 0)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            if (recInfo.hasSniper)
                primaryCount[0]++;
            else if (recInfo.hasRifle)
                primaryCount[1]++;
            else if (recInfo.hasPrimary)
                primaryCount[2]++;
        }
    }
    
    // 理想配置：1狙击+4步枪，或5步枪
    int diversityBonus = 0;
    if (primaryCount[0] == 1 && primaryCount[1] >= 3)
        diversityBonus = 200;  // 1 AWP + 步枪
    else if (primaryCount[1] == 5)
        diversityBonus = 150;  // 全步枪
    else if (primaryCount[0] == 0 && primaryCount[1] >= 4)
        diversityBonus = 100;  // 4+步枪
    
    quality += diversityBonus;
    
    // 软约束3：奖励道具配置
    int totalUtility = 0;
    for (int i = 0; i < iBotCount; i++)
    {
        int recIndex = result.assignment[i];
        if (recIndex >= 0)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            totalUtility += recInfo.utilityCount;
        }
    }
    
    // 理想道具数量：8-12个（平均每人2个左右）
    int utilityBonus = 0;
    if (totalUtility >= 8 && totalUtility <= 12)
        utilityBonus = 100;
    else if (totalUtility >= 6)
        utilityBonus = 50;
    
    quality += utilityBonus;
    
    // 软约束4：惩罚过度"发枪"需求
    int totalDeficit = 0;
    for (int i = 0; i < iBotCount; i++)
    {
        int client = hBots.Get(i);
        int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
        
        int recIndex = result.assignment[i];
        if (recIndex >= 0)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            int deficit = recInfo.totalCost - clientMoney;
            if (deficit > 0)
                totalDeficit += deficit;
        }
    }
    
    // 发枪需求越大扣分越多
    int dropPenalty = totalDeficit / 10;
    quality -= dropPenalty;
    
    delete values;
    
    return quality;
}

// ============================================================================
// 辅助函数
// ============================================================================

// 获取某回合的REC文件列表
ArrayList GetRecFilesForRound(const char[] szMap, const char[] szDemoFolder, 
                              int iRound, const char[] szTeamName)
{
    ArrayList hRecFiles = new ArrayList(PLATFORM_MAX_PATH);
    
    char szRoundPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szRoundPath, sizeof(szRoundPath), 
        "data/botmimic/all/%s/%s/round%d/%s", 
        szMap, szDemoFolder, iRound + 1, szTeamName);
    
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
    
    return hRecFiles;
}

// 构建REC装备信息缓存
ArrayList BuildRecEquipmentCache(ArrayList hRecFiles, JSONObject jTeam, int iTeam)
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
        recInfo.tacticalValue = 0;
        recInfo.hasPrimary = false;
        recInfo.hasSniper = false;
        recInfo.hasRifle = false;
        recInfo.utilityCount = 0;
        recInfo.primaryWeapon[0] = '\0';
        
        // 第1步：从购买记录计算成本
        ArrayList purchasedItems = new ArrayList(ByteCountToCells(64));
        bool hasSlotItem[5] = {false, ...};  // 追踪各槽位是否有装备
        
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
                
                // 转换对面阵营武器
                char szConvertedItem[64];
                GetTeamSpecificWeapon(szItem, iTeam, szConvertedItem, sizeof(szConvertedItem));
                
                int iSlot = GetWeaponSlotFromItem(szConvertedItem);
                
                if (StrEqual(szAction, "purchased", false))
                {
                    // 购买动作：加价格，标记槽位有装备
                    int iPrice = GetItemPrice(szConvertedItem);
                    recInfo.totalCost += iPrice;
                    purchasedItems.PushString(szConvertedItem);
                    
                    if (iSlot >= 0 && iSlot < 5)
                        hasSlotItem[iSlot] = true;
                }
                else if (StrEqual(szAction, "dropped", false))
                {
                    // 丢弃动作：检查丢弃前槽位是否有装备
                    if (iSlot >= 0 && iSlot < 5)
                    {
                        if (!hasSlotItem[iSlot])
                        {
                            // 保险措施：丢弃前槽位是空的，需要加上被丢弃武器的价格
                            int iPrice = GetItemPrice(szConvertedItem);
                            recInfo.totalCost += iPrice;
                        }
                        
                        // 丢弃后槽位变空
                        hasSlotItem[iSlot] = false;
                    }
                }
                else if (StrEqual(szAction, "picked_up", false))
                {
                    // 拾取动作：标记槽位有装备，但不加价格
                    if (iSlot >= 0 && iSlot < 5)
                        hasSlotItem[iSlot] = true;
                }
                
                delete jAction;
            }
            
            delete jPurchases;
        }
        
        // 第2步：检查final_inventory里有但purchases没有的物品
        if (jBotData.HasKey("final_inventory"))
        {
            JSONArray jInventory = view_as<JSONArray>(jBotData.Get("final_inventory"));
            
            for (int i = 0; i < jInventory.Length; i++)
            {
                char szItem[64];
                jInventory.GetString(i, szItem, sizeof(szItem));
                
                // 转换对面阵营武器
                char szConvertedItem[64];
                GetTeamSpecificWeapon(szItem, iTeam, szConvertedItem, sizeof(szConvertedItem));
                
                // 检查是否在purchased列表里
                bool bWasPurchased = false;
                for (int p = 0; p < purchasedItems.Length; p++)
                {
                    char szPurchased[64];
                    purchasedItems.GetString(p, szPurchased, sizeof(szPurchased));
                    
                    if (StrEqual(szConvertedItem, szPurchased, false))
                    {
                        bWasPurchased = true;
                        break;
                    }
                }
                
                // 获取价格（无论是否purchased都需要用于totalValue）
                int iPrice = GetItemPrice(szConvertedItem);
                
                // 如果不在purchased列表里，需要加到totalCost
                if (!bWasPurchased)
                {
                    recInfo.totalCost += iPrice;
                }
                
                // 计算战术价值和总价值
                int iTacticalValue = GetTacticalValue(szConvertedItem);
                recInfo.tacticalValue += iTacticalValue;
                recInfo.totalValue += iPrice;
                
                // 分析装备类型
                int iSlot = GetWeaponSlotFromItem(szConvertedItem);
                
                if (iSlot == CS_SLOT_PRIMARY)
                {
                    recInfo.hasPrimary = true;
                    strcopy(recInfo.primaryWeapon, sizeof(recInfo.primaryWeapon), szConvertedItem);
                    
                    if (IsSniperWeapon(szConvertedItem))
                        recInfo.hasSniper = true;
                    else if (IsRifleWeapon(szConvertedItem))
                        recInfo.hasRifle = true;
                }
                else if (IsUtilityItem(szConvertedItem))
                {
                    recInfo.utilityCount++;
                }
            }
            
            delete jInventory;
        }
        
        delete purchasedItems;
        delete jBotData;
        
        hRecInfoList.PushArray(recInfo, sizeof(RecEquipmentInfo));
    }
    
    return hRecInfoList;
}

// 计算战术价值（带权重）
int GetTacticalValue(const char[] szItem)
{
    int basePrice = GetItemPrice(szItem);
    float multiplier = 1.0;
    
    // 主武器加权
    if (IsRifleWeapon(szItem))
    {
        multiplier = 1.5;  // 步枪最重要
    }
    else if (IsSniperWeapon(szItem))
    {
        multiplier = 1.8;  // 狙击枪更重要
    }
    else if (IsSMGWeapon(szItem))
    {
        multiplier = 0.7;  // SMG战术价值较低
    }
    
    // 道具加权
    if (StrEqual(szItem, "smokegrenade", false))
    {
        multiplier = 2.0;  // 烟雾弹极重要
    }
    else if (StrEqual(szItem, "flashbang", false))
    {
        multiplier = 1.5;  // 闪光弹重要
    }
    else if (StrEqual(szItem, "hegrenade", false))
    {
        multiplier = 1.3;
    }
    else if (StrEqual(szItem, "molotov", false) || StrEqual(szItem, "incgrenade", false))
    {
        multiplier = 1.4;
    }
    
    // 护甲加权
    if (StrEqual(szItem, "vesthelm", false))
    {
        multiplier = 1.6;  // 头盔很重要
    }
    else if (StrEqual(szItem, "vest", false))
    {
        multiplier = 1.3;
    }
    
    // 拆弹器
    if (StrEqual(szItem, "defuser", false))
    {
        multiplier = 1.5;
    }
    
    return RoundFloat(float(basePrice) * multiplier);
}

// 重新计算结果的总成本和总价值
void RecalculateResult(KnapsackResult result, ArrayList hBots, ArrayList hRecInfoList)
{
    result.totalCost = 0;
    result.totalValue = 0;
    
    int iBotCount = hBots.Length;
    
    for (int i = 0; i < iBotCount; i++)
    {
        int recIndex = result.assignment[i];
        if (recIndex >= 0 && recIndex < hRecInfoList.Length)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            result.totalCost += recInfo.totalCost;
            result.totalValue += recInfo.tacticalValue;
        }
    }
}

// 检查团队是否能负担（考虑虚拟发枪）
bool CanTeamAfford(KnapsackResult result, ArrayList hBots, ArrayList hRecInfoList)
{
    int iBotCount = hBots.Length;
    
    // 计算总经济和总需求
    int totalMoney = 0;
    int totalRequired = 0;
    
    for (int i = 0; i < iBotCount; i++)
    {
        int client = hBots.Get(i);
        int clientMoney = GetEntProp(client, Prop_Send, "m_iAccount");
        totalMoney += clientMoney;
        
        int recIndex = result.assignment[i];
        if (recIndex >= 0)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            totalRequired += recInfo.totalCost;
        }
    }
    
    // 只要总经济够就行（允许虚拟发枪）
    return (totalMoney >= totalRequired);
}

// 虚拟发枪模拟
void SimulateDropSystem(ArrayList hBots, KnapsackResult result, ArrayList hRecInfoList)
{
    int iBotCount = hBots.Length;
    
    // 使用 ArrayList 存储 bot 信息
    ArrayList botInfos = new ArrayList(sizeof(BotEconomyInfo));
    
    for (int i = 0; i < iBotCount; i++)
    {
        int client = hBots.Get(i);
        
        BotEconomyInfo info;
        info.client = client;
        info.money = GetEntProp(client, Prop_Send, "m_iAccount");
        info.teamIndex = i;
        
        int recIndex = result.assignment[i];
        if (recIndex >= 0)
        {
            RecEquipmentInfo recInfo;
            hRecInfoList.GetArray(recIndex, recInfo, sizeof(RecEquipmentInfo));
            
            info.assignedRecIndex = recIndex;
            info.assignedCost = recInfo.totalCost;
            info.assignedValue = recInfo.totalValue;
            strcopy(info.assignedRecName, PLATFORM_MAX_PATH, recInfo.recName);
        }
        else
        {
            info.assignedRecIndex = -1;
            info.assignedCost = 0;
            info.assignedValue = 0;
            info.assignedRecName[0] = '\0';
        }
        
        botInfos.PushArray(info, sizeof(BotEconomyInfo));
    }
    
    // 按经济排序 (使用 SortADTArrayCustom)
    SortADTArrayCustom(botInfos, Sort_BotEconomyByMoney);
    
    // 分配"虚拟发枪"
    for (int i = 0; i < iBotCount; i++)
    {
        BotEconomyInfo info;
        botInfos.GetArray(i, info, sizeof(BotEconomyInfo));
        
        int deficit = info.assignedCost - info.money;
        
        if (deficit > 0)
        {
            for (int j = iBotCount - 1; j >= 0; j--)
            {
                if (j == i)
                    continue;
                
                BotEconomyInfo richInfo;
                botInfos.GetArray(j, richInfo, sizeof(BotEconomyInfo));
                
                int surplus = richInfo.money - richInfo.assignedCost;
                
                if (surplus > 0)
                {
                    int transfer = (surplus < deficit) ? surplus : deficit;
                    
                    richInfo.money -= transfer;
                    info.money += transfer;
                    deficit -= transfer;
                    
                    // 更新数组
                    botInfos.SetArray(j, richInfo, sizeof(BotEconomyInfo));
                    
                    char szFromName[MAX_NAME_LENGTH], szToName[MAX_NAME_LENGTH];
                    GetClientName(richInfo.client, szFromName, sizeof(szFromName));
                    GetClientName(info.client, szToName, sizeof(szToName));
                    
                    if (deficit <= 0)
                        break;
                }
            }
            
            if (deficit > 0)
            {
                char szName[MAX_NAME_LENGTH];
                GetClientName(info.client, szName, sizeof(szName));
            }
        }
    }
    
    delete botInfos;
}

// 排序函数:按金钱升序
public int Sort_BotEconomyByMoney(int index1, int index2, Handle array, Handle hndl)
{
    ArrayList list = view_as<ArrayList>(array);
    
    BotEconomyInfo info1, info2;
    list.GetArray(index1, info1, sizeof(BotEconomyInfo));
    list.GetArray(index2, info2, sizeof(BotEconomyInfo));
    
    if (info1.money < info2.money) return -1;
    if (info1.money > info2.money) return 1;
    return 0;
}

/**
 * 验证分配结果中没有重复的REC
 * 
 * @param result        分配结果
 * @param iBotCount     Bot数量
 * @return              true=所有REC唯一, false=存在重复
 */
bool ValidateAssignmentUniqueness(KnapsackResult result, int iBotCount)
{
    ArrayList usedRecs = new ArrayList();
    
    for (int i = 0; i < iBotCount; i++)
    {
        int recIndex = result.assignment[i];
        
        if (recIndex < 0)
            continue;
        
        // 检查是否已使用
        if (usedRecs.FindValue(recIndex) != -1)
        {
            delete usedRecs;
            return false;
        }
        
        usedRecs.Push(recIndex);
    }
    
    delete usedRecs;
    return true;
}

/**
 * 为当前回合安排动态暂停
 * 
 */
void ScheduleDynamicPause(int iRound)
{
    PrintToServer("[Pause System] ===== ScheduleDynamicPause CALLED =====");
    PrintToServer("[Pause System] Game round: %d (0-based)", iRound);
    PrintToServer("[Pause System] Demo round number: round%d", iRound + 1);
    PrintToServer("[Pause System] RecFolder: %s", g_bRecFolderSelected ? g_szCurrentRecFolder : "NONE");
    
    // 检查 bot_pause 插件是否加载
    if (!g_bPausePluginLoaded)
    {
        PrintToServer("[Pause System] ✗ bot_pause plugin not loaded, pause disabled");
        return;
    }
    
    // 检查回合是否有效
    if (iRound < 0 || iRound >= 31)
    {
        PrintToServer("[Pause System] ✗ Invalid round: %d (must be 0-30)", iRound);
        return;
    }
    
    // 检查该回合的冻结时间是否有效
    if (!g_bAllRoundFreezeTimeValid[iRound])
    {
        PrintToServer("[Pause System] ✗ Round %d has no valid freeze time", iRound);
        return;
    }
    
    // 获取服务器冻结时间
    ConVar cvFreezeTime = FindConVar("mp_freezetime");
    float fServerFreeze = 20.0;
    
    if (cvFreezeTime != null)
    {
        fServerFreeze = cvFreezeTime.FloatValue;
        PrintToServer("[Pause System] ✓ Server freeze time: %.2f seconds", fServerFreeze);
    }
    
    float fDemoFreeze = g_fAllRoundFreezeTimes[iRound];
    
    PrintToServer("[Pause System] ===== ANALYZING ROUND %d =====", iRound);
    PrintToServer("[Pause System] Server freeze: %.2f, Demo freeze: %.2f", fServerFreeze, fDemoFreeze);
    
    // 如果demo冻结时间 <= 服务器冻结时间,不需要暂停
    if (fDemoFreeze <= fServerFreeze)
    {
        PrintToServer("[Pause System] ✓ No pause needed (demo <= server)");
        return;
    }
    
    // 计算时间差
    float fTimeDiff = fDemoFreeze - fServerFreeze;
    PrintToServer("[Pause System] ⚠ Pause required! Time difference: %.2f seconds", fTimeDiff);
    
    // 决定暂停策略
    float fPauseDelay = 0.0;
    int iPauseTime = 0;
    
    float fMaxDelayedPause = fServerFreeze + 30.0;
    
    if (fTimeDiff > fMaxDelayedPause)
    {
        // 立即长暂停
        fPauseDelay = 0.0;
        iPauseTime = RoundToNearest(fTimeDiff);
        PrintToServer("[Pause System] Strategy: IMMEDIATE LONG PAUSE (%d seconds)", iPauseTime);
    }
    else if (fTimeDiff <= 30.0)
    {
        // 立即短暂停
        fPauseDelay = 0.0;
        iPauseTime = RoundToNearest(fTimeDiff);
        PrintToServer("[Pause System] Strategy: IMMEDIATE SHORT PAUSE (%d seconds)", iPauseTime);
    }
    else
    {
        // 延迟后暂停30秒
        fPauseDelay = fTimeDiff - 30.0;
        iPauseTime = 30;
        PrintToServer("[Pause System] Strategy: DELAYED 30s PAUSE (delay: %.2f)", fPauseDelay);
    }
    
// 随机选择一个队伍的bot来执行暂停
    int iBotToUse = -1;
    int iTeamToUse = -1;
    
    // 获取两队的可用暂停次数
    int iPausesLeftT = BotPause_GetTeamPausesLeft(CS_TEAM_T);
    int iPausesLeftCT = BotPause_GetTeamPausesLeft(CS_TEAM_CT);
    
    PrintToServer("[Pause System] Pause availability: T=%d, CT=%d", iPausesLeftT, iPausesLeftCT);
    
    // 随机选择队伍（优先有暂停次数的队伍）
    if (iPausesLeftT > 0 && iPausesLeftCT > 0)
    {
        // 两队都有暂停次数，随机选择
        iTeamToUse = GetRandomInt(0, 1) == 0 ? CS_TEAM_T : CS_TEAM_CT;
        PrintToServer("[Pause System] Both teams available, randomly selected: %s", 
            iTeamToUse == CS_TEAM_T ? "T" : "CT");
    }
    else if (iPausesLeftT > 0)
    {
        iTeamToUse = CS_TEAM_T;
        PrintToServer("[Pause System] Only T team has pauses left");
    }
    else if (iPausesLeftCT > 0)
    {
        iTeamToUse = CS_TEAM_CT;
        PrintToServer("[Pause System] Only CT team has pauses left");
    }
    else
    {
        PrintToServer("[Pause System] ✗ No team has pauses left");
        return;
    }
    
    // 在选定的队伍中找一个bot
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
        PrintToServer("[Pause System] ✗ No bot available in team %s, trying other team", 
            iTeamToUse == CS_TEAM_T ? "T" : "CT");
        
        // 尝试另一个队伍
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
                PrintToServer("[Pause System] Found bot in other team: %s", 
                    iTeamToUse == CS_TEAM_T ? "T" : "CT");
                break;
            }
        }
        
        if (iBotToUse == -1)
        {
            PrintToServer("[Pause System] ✗ No bot available in any team");
            return;
        }
    }
    
    char szBotName[MAX_NAME_LENGTH];
    GetClientName(iBotToUse, szBotName, sizeof(szBotName));
    PrintToServer("[Pause System] Using bot: %s (client %d)", szBotName, iBotToUse);
    
    // 创建定时器让bot执行暂停
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(iBotToUse));
    pack.WriteCell(iPauseTime);
    
    CreateTimer(fPauseDelay, Timer_BotExecutePause, pack, TIMER_FLAG_NO_MAPCHANGE);
    
    PrintToServer("[Pause System] ✓ Pause scheduled: delay=%.2f, duration=%d", fPauseDelay, iPauseTime);
    PrintToServer("[Pause System] ===== PAUSE SYSTEM ACTIVE =====");
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
    
    char szBotName[MAX_NAME_LENGTH];
    GetClientName(client, szBotName, sizeof(szBotName));
    
    PrintToServer("[Pause System] ===== BOT EXECUTING PAUSE =====");
    PrintToServer("[Pause System] Bot: %s (client %d)", szBotName, client);
    PrintToServer("[Pause System] Pause time: %d seconds", iPauseTime);
    
    // 让bot发送暂停命令（如果是默认时间则不带参数）
    if (iPauseTime == 30)  // DEFAULT_PAUSE_TIME
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
    g_hWeaponPrices.SetValue("fiveseven", 500);
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
    
    // T阵营武器转换
    g_hWeaponConversion_T.SetString("m4a1", "ak47");
    g_hWeaponConversion_T.SetString("m4a1_silencer", "ak47");
    g_hWeaponConversion_T.SetString("famas", "galilar");
    g_hWeaponConversion_T.SetString("aug", "sg556");
    g_hWeaponConversion_T.SetString("mp9", "mac10");
    g_hWeaponConversion_T.SetString("fiveseven", "tec9");
    g_hWeaponConversion_T.SetString("usp_silencer", "glock");
    g_hWeaponConversion_T.SetString("hkp2000", "glock");
    g_hWeaponConversion_T.SetString("scar20", "g3sg1");
    g_hWeaponConversion_T.SetString("mag7", "sawedoff");
    g_hWeaponConversion_T.SetString("incgrenade", "molotov");
    
    // CT阵营武器转换
    g_hWeaponConversion_CT.SetString("ak47", "m4a1");
    g_hWeaponConversion_CT.SetString("galilar", "famas");
    g_hWeaponConversion_CT.SetString("sg556", "aug");
    g_hWeaponConversion_CT.SetString("mac10", "mp9");
    g_hWeaponConversion_CT.SetString("tec9", "fiveseven");
    g_hWeaponConversion_CT.SetString("glock", "hkp2000");
    g_hWeaponConversion_CT.SetString("g3sg1", "scar20");
    g_hWeaponConversion_CT.SetString("sawedoff", "mag7");
    g_hWeaponConversion_CT.SetString("molotov", "incgrenade");
    
    // 武器类型 (位标记: 1=步枪, 2=狙击, 4=SMG, 8=道具, 16=默认手枪)
    g_hWeaponTypes.SetValue("ak47", 1);
    g_hWeaponTypes.SetValue("m4a1", 1);
    g_hWeaponTypes.SetValue("m4a1_silencer", 1);
    g_hWeaponTypes.SetValue("aug", 1);
    g_hWeaponTypes.SetValue("sg556", 1);
    g_hWeaponTypes.SetValue("famas", 1);
    g_hWeaponTypes.SetValue("galilar", 1);
    
    g_hWeaponTypes.SetValue("awp", 2);
    g_hWeaponTypes.SetValue("ssg08", 2);
    g_hWeaponTypes.SetValue("scar20", 2);
    g_hWeaponTypes.SetValue("g3sg1", 2);
    
    g_hWeaponTypes.SetValue("mp9", 4);
    g_hWeaponTypes.SetValue("mac10", 4);
    g_hWeaponTypes.SetValue("ump45", 4);
    g_hWeaponTypes.SetValue("p90", 4);
    g_hWeaponTypes.SetValue("bizon", 4);
    g_hWeaponTypes.SetValue("mp7", 4);
    
    g_hWeaponTypes.SetValue("smokegrenade", 8);
    g_hWeaponTypes.SetValue("flashbang", 8);
    g_hWeaponTypes.SetValue("hegrenade", 8);
    g_hWeaponTypes.SetValue("molotov", 8);
    g_hWeaponTypes.SetValue("incgrenade", 8);
    g_hWeaponTypes.SetValue("decoy", 8);
    
    g_hWeaponTypes.SetValue("glock", 16);
    g_hWeaponTypes.SetValue("hkp2000", 16);
    g_hWeaponTypes.SetValue("usp_silencer", 16);
}

// 武器类型常量定义
#define WEAPON_TYPE_RIFLE 1
#define WEAPON_TYPE_SNIPER 2
#define WEAPON_TYPE_SMG 4
#define WEAPON_TYPE_UTILITY 8
#define WEAPON_TYPE_DEFAULT_PISTOL 16

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

bool IsRifleWeapon(const char[] szItem)
{
    return IsWeaponType(szItem, WEAPON_TYPE_RIFLE);
}

bool IsSMGWeapon(const char[] szItem)
{
    return IsWeaponType(szItem, WEAPON_TYPE_SMG);
}

bool IsUtilityItem(const char[] szItem)
{
    return IsWeaponType(szItem, WEAPON_TYPE_UTILITY);
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
    
    char szMapPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szMapPath, sizeof(szMapPath), "data/botmimic/all/%s", szMap);
    
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
// 共享库函数实现
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
    
    PrintToServer("[Bot Shared] Initialized successfully");
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
 * 获取缓存的敌人（性能优化版本）
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
    // 预留函数
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
    
    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), 
        "data/botmimic/all/%s/%s/c4_holders.json", szMap, szRecFolder);
    
    if (!FileExists(szPath))
    {
        PrintToServer("[C4 Holder] File not found: %s", szPath);
        return false;
    }
    
    // 清理旧数据
    if (g_jC4HolderData != null)
        delete g_jC4HolderData;
    
    // 加载JSON
    g_jC4HolderData = view_as<JSONArray>(JSONArray.FromFile(szPath));
    if (g_jC4HolderData == null)
    {
        PrintToServer("[C4 Holder] Failed to parse JSON");
        return false;
    }
    
    PrintToServer("[C4 Holder] Loaded C4 holder data from: %s (entries: %d)", 
        szPath, g_jC4HolderData.Length);
    return true;
}

/**
 * 获取指定回合的C4持有者名称
 */
bool GetC4HolderForRound(int iRound, char[] szPlayerName, int iMaxLen)
{
    if (g_jC4HolderData == null)
        return false;
    
    // round1 对应 iRound=0, 所以查找时 +1
    int iTargetRound = iRound + 1;
    
    for (int i = 0; i < g_jC4HolderData.Length; i++)
    {
        JSONObject jEntry = view_as<JSONObject>(g_jC4HolderData.Get(i));
        
        int iRoundNum = jEntry.GetInt("round");
        
        if (iRoundNum == iTargetRound)
        {
            jEntry.GetString("player_name", szPlayerName, iMaxLen);
            delete jEntry;
            
            PrintToServer("[C4 Holder] Round %d holder: %s", iTargetRound, szPlayerName);
            return true;
        }
        
        delete jEntry;
    }
    
    return false;
}

/**
 * 冻结时间开始时分配C4
 */
public Action Timer_AssignC4AtFreezeStart(Handle hTimer)
{
    char szHolderName[MAX_NAME_LENGTH];
    
    if (!GetC4HolderForRound(g_iCurrentRound, szHolderName, sizeof(szHolderName)))
    {
        PrintToServer("[C4 Holder] No C4 holder defined for round %d", g_iCurrentRound + 1);
        return Plugin_Stop;
    }
    
    PrintToServer("[C4 Holder] ===== FREEZE START C4 ASSIGNMENT =====");
    PrintToServer("[C4 Holder] Target holder: %s (Round %d)", szHolderName, g_iCurrentRound + 1);
    
    // 首先检查C4是否在真人玩家手上
    int iCurrentHolder = -1;
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
                iCurrentHolder = i;
                bIsOnRealPlayer = !IsFakeClient(i);
                
                char szCurrentName[MAX_NAME_LENGTH];
                GetClientName(i, szCurrentName, sizeof(szCurrentName));
                PrintToServer("[C4 Holder] Current holder: %s (client %d, bot=%d)", 
                    szCurrentName, i, IsFakeClient(i) ? 1 : 0);
                break;
            }
        }
    }
    
    // 如果C4在玩家手上，不进行转移
    if (bIsOnRealPlayer)
    {
        char szPlayerName[MAX_NAME_LENGTH];
        GetClientName(iCurrentHolder, szPlayerName, sizeof(szPlayerName));
        return Plugin_Stop;
    }
    
    // 查找目标bot
    int iTargetBot = -1;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        // 检查REC名称是否匹配
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
        PrintToServer("[C4 Holder] ✗ Target bot '%s' not found", szHolderName);
        return Plugin_Stop;
    }
    
    char szTargetName[MAX_NAME_LENGTH];
    GetClientName(iTargetBot, szTargetName, sizeof(szTargetName));
    PrintToServer("[C4 Holder] Found target: %s (client %d)", szTargetName, iTargetBot);
    
    // 检查目标bot是否已有C4
    int iTargetC4 = GetPlayerWeaponSlot(iTargetBot, CS_SLOT_C4);
    if (IsValidEntity(iTargetC4))
    {
        return Plugin_Stop;
    }
    
    // 移除所有其他T方bot的C4（不包括真人玩家）
    int iRemovedCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsPlayerAlive(i) || i == iTargetBot)
            continue;
        
        if (GetClientTeam(i) != CS_TEAM_T)
            continue;
        
        // 跳过真人玩家
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
                
                char szBotName[MAX_NAME_LENGTH];
                GetClientName(i, szBotName, sizeof(szBotName));
                PrintToServer("[C4 Holder]   Removed C4 from %s", szBotName);
                iRemovedCount++;
            }
        }
    }
    
    // 给目标bot分配C4
    int iNewC4 = GivePlayerItem(iTargetBot, "weapon_c4");
    
    if (IsValidEntity(iNewC4))
    {
        PrintToServer("[C4 Holder] ✓ Successfully gave C4 to %s", szTargetName);
        PrintToServer("[C4 Holder]   Removed: %d, Assigned: 1", iRemovedCount);
    }
    else
    {
        PrintToServer("[C4 Holder] ✗ Failed to give C4 to %s", szTargetName);
    }
    
    PrintToServer("[C4 Holder] ===== ASSIGNMENT COMPLETE =====");
    return Plugin_Stop;
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "bot_pause"))
    {
        g_bPausePluginLoaded = true;
        PrintToServer("[Bot REC] bot_pause plugin detected");
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "bot_pause"))
    {
        g_bPausePluginLoaded = false;
        PrintToServer("[Bot REC] bot_pause plugin unloaded");
    }
}