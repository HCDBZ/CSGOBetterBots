#if defined _bot_voice_included
 #endinput
#endif
#define _bot_voice_included

/**
 * 让bot开始说话
 * 
 * @param client        Bot客户端索引
 * @param voiceFile     语音文件路径（相对于sound/目录，例如"botrec/de_dust2/demo1/round1/t/voice_001.wav"）
 * @param duration      语音持续时间（秒）
 * @noreturn
 */
native void BotVoice_StartSpeaking(int client, const char[] voiceFile, float duration);

/**
 * 让bot停止说话
 * 
 * @param client        Bot客户端索引
 * @noreturn
 */
native void BotVoice_StopSpeaking(int client);

/**
 * 检查bot是否正在说话
 * 
 * @param client        Bot客户端索引
 * @return              true=正在说话, false=未说话
 */
native bool BotVoice_IsSpeaking(int client);

/**
 * 当bot开始说话时触发
 * 
 * @param client        Bot客户端索引
 */
forward void BotVoice_OnBotStartSpeaking(int client);

/**
 * 当bot停止说话时触发
 * 
 * @param client        Bot客户端索引
 */
forward void BotVoice_OnBotStopSpeaking(int client);

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
    MarkNativeAsOptional("BotVoice_IsSpeaking");
}
#endif