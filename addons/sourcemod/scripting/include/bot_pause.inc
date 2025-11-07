#if defined _bot_pause_included
    #endinput
#endif
#define _bot_pause_included

/**
 * 执行暂停
 * 
 * @param client        触发暂停的客户端
 * @param pauseTime     暂停时间（秒）
 * @return              1=成功, 0=失败
 */
native int BotPause_ExecutePause(int client, int pauseTime);

/**
 * 获取队伍剩余暂停次数
 * 
 * @param team          队伍ID (2=T, 3=CT)
 * @return              剩余暂停次数
 */
native int BotPause_GetTeamPausesLeft(int team);

/**
 * 当暂停被执行时触发的Forward
 * 
 * @param client        触发暂停的客户端
 * @param pauseTime     暂停时间
 */
forward void BotPause_OnPauseExecuted(int client, int pauseTime);

public SharedPlugin __pl_bot_pause = {
    name = "bot_pause",
    file = "bot_pause.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_bot_pause_SetNTVOptional() {
    MarkNativeAsOptional("BotPause_ExecutePause");
    MarkNativeAsOptional("BotPause_GetTeamPausesLeft");
}
#endif