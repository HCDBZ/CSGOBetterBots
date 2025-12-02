#if defined _bot_voice_included
 #endinput
#endif
#define _bot_voice_included

/**
 * 让bot开始说话(支持多音频混音)
 * 
 * @param client        Bot客户端索引
 * @param voiceFile     语音文件路径(相对于sound/目录)
 * @param duration      语音持续时间(秒)
 * @return              轨道ID(用于追踪),失败返回-1
 */
native int BotVoice_StartSpeaking(int client, const char[] voiceFile, float duration);

/**
 * 停止bot的最早播放的语音
 * 注意: 如果有多个音频在播放,只停止第一个
 * 
 * @param client        Bot客户端索引
 * @noreturn
 */
native void BotVoice_StopSpeaking(int client);

/**
 * 停止bot的所有语音
 * 
 * @param client        Bot客户端索引
 * @noreturn
 */
native void BotVoice_StopAllSpeaking(int client);

/**
 * 检查bot是否正在说话
 * 
 * @param client        Bot客户端索引
 * @return              true=正在播放至少一个语音, false=未说话
 */
native bool BotVoice_IsSpeaking(int client);

/**
 * 获取bot当前正在播放的音频轨道数量
 * 
 * @param client        Bot客户端索引
 * @return              正在播放的轨道数量
 */
native int BotVoice_GetActiveTrackCount(int client);

/**
 * 当bot开始说话时触发
 * 
 * @param client        Bot客户端索引
 * @param voiceFile     开始播放的语音文件路径
 */
forward void BotVoice_OnBotStartSpeaking(int client, const char[] voiceFile);

/**
 * 当bot停止说话时触发(单个轨道结束)
 * 
 * @param client        Bot客户端索引
 * @param voiceFile     停止播放的语音文件路径
 */
forward void BotVoice_OnBotStopSpeaking(int client, const char[] voiceFile);

public SharedPlugin __pl_bot_voice = 
{
    name = "bot_voice",
    file = "bot_voice.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_bot_voice_SetNTVOptional()
{
    MarkNativeAsOptional("BotVoice_StartSpeaking");
    MarkNativeAsOptional("BotVoice_StopSpeaking");
    MarkNativeAsOptional("BotVoice_StopAllSpeaking");
    MarkNativeAsOptional("BotVoice_IsSpeaking");
    MarkNativeAsOptional("BotVoice_GetActiveTrackCount");
}
#endif