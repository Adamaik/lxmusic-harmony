#ifndef LX_EQ_PIPELINE_H
#define LX_EQ_PIPELINE_H

#include <cstdint>
#include <string>

namespace lxeq {

struct EqResult {
    bool ok = false;
    int32_t code = 0;              // 0 成功；非 0 为阶段码，便于定位
    std::string message;
    int64_t outBytes = 0;          // 输出 WAV 字节数
    double delta = 0.0;            // 自检指标：输出/输入「低频÷高频能量比」之商
                                   // 全 0 增益时 ≈1.0；低频增强 >1，高频增强 <1
    /** 失败时的现场计数（解码块数 / 推入样本数 / 消费超时次数 / 解码器错误码），
     *  只为把「卡在哪一步」带回 ArkTS 日志，成功时无意义 */
    int64_t inChunks = 0;
    int64_t inSamples = 0;
    int32_t timeouts = 0;
    int32_t decoderError = -1;
    /** 诊断：容器报的时长与解码器实际输出（成功时也算），用来核对 WAV 头里的长度估计 */
    int64_t durationUs = 0;
    int32_t sampleRate = 0;
    int32_t channels = 0;
    int64_t outFrames = 0;
};

/**
 * 空间音效配置：平台现成的 3 个 AudioSuite 节点。
 *
 * 与 EQ 串在同一条管线里（INPUT -> EQUALIZER -> SOUND_FIELD -> ENVIRONMENT
 * -> SPACE_RENDER -> OUTPUT），四个节点的输出格式都是 48kHz / S16LE / 2ch。
 * 值为 0 表示不创建对应节点。
 *
 * 所有范围都来自 native_audio_suite_base.h：
 * - position xyz / rotation xyz: [-5.0, 5.0] 米
 * - surroundTime: [2, 40] 秒；surroundDirection: 0 逆时针 / 1 顺时针
 * - extRadius: [1.0, 5.0] 米；extAngle: (0, 360) 度
 * 越界时 setter 返回 INVALID_PARAM 且节点停在半初始化状态，StartPipeline 后会在
 * 系统库里空指针崩溃 —— 所以 ArkTS 侧夹一次，这里再夹一次。
 */
struct FxConfig {
    int32_t soundField = 0;    // 0..4：OH_SoundFieldType
    int32_t environment = 0;   // 0..4：OH_EnvironmentType
    int32_t spaceMode = 0;     // 0..3：0 关 / 1 定位 / 2 环绕 / 3 扩散
    float posX = 0.0f;
    float posY = 0.0f;
    float posZ = 2.0f;
    int32_t surroundTime = 10;
    int32_t surroundDir = 1;
    float extRadius = 3.0f;
    int32_t extAngle = 90;
};

/**
 * 把一段本地音频过 10 段 EQ（可叠加空间音效）后另存为 WAV。
 *
 * @param inPath   本地输入文件路径（沙箱绝对路径，mp3/flac/m4a/wav 等 AVPlayer 支持的格式）
 * @param outPath  输出 WAV 路径（沙箱绝对路径）
 * @param gains    长度必须为 10 的增益数组（dB，-10..+10）
 * @param cancel   取消标志指针：Native 线程循环中会读它，置 true 即尽快中止并回收
 * @param fx       空间音效配置；全 0 时管线与只做 EQ 完全一致
 */
EqResult processAudio(const std::string &inPath,
                      const std::string &outPath,
                      const int32_t *gains,
                      const volatile bool *cancel,
                      const FxConfig &fx);

/**
 * 与 processAudio 相同，但输入是网络地址（http/https）。
 * 由系统解封装器直接拉流，省掉「先整份下载到本地」的等待。
 * 仅支持渐进式格式（mp3/flac/m4a 等），HLS/DASH 不支持；也不支持自定义请求头
 * （需要鉴权的源请调用方自行下载后用 processAudio）。
 */
EqResult processAudioUrl(const std::string &url,
                         const std::string &outPath,
                         const int32_t *gains,
                         const volatile bool *cancel,
                         const FxConfig &fx);

/**
 * 与 processAudio 相同，但输入用**已打开的 fd**。
 *
 * 为什么需要：文件选择器导入的本地音乐存的是 `file://docs/...` URI，能不能读取决于
 * ArkTS 侧的持久化授权（见 LocalAccess）——原生 `fopen` 按这个串是打不开的。
 * 由 ArkTS 用 `fs.openSync(uri)` 打开、把 fd 传进来，走的就是和播放器完全一致的那条读取通道。
 *
 * @param fd   调用方打开的只读 fd；**所有权仍在调用方**，本函数不关闭它，
 *             但调用方必须保持它在本函数返回前有效（AVSource 一直在用它读数据）。
 */
EqResult processAudioFd(int32_t fd,
                        const std::string &outPath,
                        const int32_t *gains,
                        const volatile bool *cancel,
                        const FxConfig &fx);

}  // namespace lxeq

#endif  // LX_EQ_PIPELINE_H
