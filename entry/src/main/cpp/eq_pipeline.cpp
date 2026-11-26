/**
 * 音效控制台的音频处理管线（流式版）：
 *   本地音频文件 -> OH_AVDemuxer + OH_AudioCodec(解码回调) -> float PCM
 *   -> 有界队列（背压，防内存暴涨） -> AudioSuite 管线（INPUT->EQUALIZER->OUTPUT）RenderFrame
 *   -> 边渲染边写 16bit WAV（流式，最后回填头）
 *
 * 设计约束：
 * - 在 NAPI 线程池里跑，绝不阻塞 UI 线程。
 * - **流式**：解码产出（生产者）与 EQ 消费（消费者）通过有界队列衔接，
 *   全程不缓存整首歌的 PCM——Hi-Res FLAC 若全缓存会占 300MB+ 内存，
 *   导致系统内存压力、网络栈分配失败（2300023）等连锁问题（真机已踩坑）。
 * - 支持 8/16/24/32bit 与 float 解码输出（Hi-Res 音源常见 24bit），
 *   interleaved 与 planar（SAMPLE_*P）两种布局都支持：planar 会先按声道反交织成
 *   interleaved float 再送进 AudioSuite（EQ 只吃交错数据）。
 * - cancel 标志随时可中止：生产者/消费者都会被唤醒退出，资源全部回收。
 * - 自检指标 delta：输出/输入的「低频/高频能量比」之商。
 *   对 EQ 滤波延迟不敏感；全 0 增益 ≈ 1.0，低频增强 > 1，高频增强 < 1。
 */
#include "eq_pipeline.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "multimedia/player_framework/native_avsource.h"
#include "multimedia/player_framework/native_avdemuxer.h"
#include "multimedia/player_framework/native_avcodec_audiodecoder.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/native_audio_channel_layout.h"
#include "ohaudiosuite/native_audio_suite_base.h"
#include "ohaudiosuite/native_audio_suite_engine.h"

namespace lxeq {

namespace {

constexpr int32_t kErrOpenSource = 1;
constexpr int32_t kErrDemuxer = 2;
constexpr int32_t kErrNoAudioTrack = 3;
constexpr int32_t kErrDecoder = 4;
constexpr int32_t kErrAudioSuite = 5;
constexpr int32_t kErrWriteWav = 6;
constexpr int32_t kErrCancelled = 7;
constexpr int32_t kErrBusy = 8;

/**
 * AudioSuite EQ 的增益**硬限制是 -10 ~ +10 dB**（真机上越界的原始日志：
 *   OHAudioSuiteEngine: SetEqualizerFrequencyBandGains failed, input value -15 not in -10, 10.
 *   SetEqualizerFrequencyBandGains failed, ret = -62980098.
 *
 * 更糟的是：设参数失败后节点并没有「带着旧参数」继续跑，而是留下一个半初始化状态，
 * StartPipeline 之后系统库在 SignalProcess/ObtainProcessedData 里空指针崩溃
 * （SIGSEGV@0x40，栈在 libaudio_suite.z.so），表现为「调增益直接闪退」。
 *
 * 所以这里必须自己夹住：越界值一律夹到边界，别交给系统去拒绝。
 */
constexpr int32_t kEqGainMin = -10;
constexpr int32_t kEqGainMax = 10;

int32_t clampGain(int32_t g) {
    if (g < kEqGainMin) return kEqGainMin;
    if (g > kEqGainMax) return kEqGainMax;
    return g;
}

/**
 * 软限幅：EQ 提升之后的防削波
 *
 * 内置预设里 31Hz 一段就有 +5~+6dB，母带本来就贴着满刻度，过完 EQ 很容易被推到 1.0 以外。
 * 原来直接 clamp(-1, 1) 再转 16bit —— 那不是「低音更足」，是硬切顶（破音），
 * 而且切出来的高次谐波会糊掉整个频谱。
 *
 * 这里只在 **|x| > 0.9** 之后介入，把过载段用 s/(1+s) 连续压进 1.0 以内：
 *   - 0.9 以下完全直通：正常电平（以及安静段落）一个样本都不会变，产物逐字节一致；
 *   - 转折点斜率仍为 1（一阶连续），没有折点带来的额外谐波；
 *   - 上界严格小于 1.0（s → ∞ 时趋近 1.0），怎么推都不会再削顶。
 *
 * 代价只有过载样本上的一次除法（普通样本只多一次比较），对 EQ 这种只在峰值触发的
 * 路径可以忽略。非有限值（±inf / NaN）直接归零：原先 ±inf 会让 s/(1+s) 变成 inf/inf=NaN、
 * -inf 还会在符号分支里反成 +满刻度，NaN 则靠调用方的 std::min/std::max 兜成 1.0。
 * 正常有限样本一个都不经过这个分支，所以产物逐字节不变。
 */
inline float softLimit(float x) {
    // 先挡非有限值：后面 s/(1+s) 对 ±inf 出 NaN，交给下游只会得到一个假的满刻度样本
    if (!std::isfinite(x)) {
        return 0.0f;
    }
    constexpr float kKnee = 0.9f;
    constexpr float kSpan = 1.0f - kKnee;
    const float a = std::fabs(x);
    if (!(a > kKnee)) {
        return x;
    }
    const float s = (a - kKnee) / kSpan;
    const float y = kKnee + kSpan * (s / (1.0f + s));
    return x < 0.0f ? -y : y;
}

/**
 * AudioSuite 的 EQ 算法是**进程级单例**（真机日志里每次建/毁管线都是
 * AudioSuiteEqAlgoInterfaceImpl 的 Deinit/Init）。两趟处理并行时，后一趟的 Init 会把
 * 前一趟正在用的算法状态重置掉，前一趟当场报「音频解码失败或超时」，两边的输出也都不对。
 *
 * ArkTS 侧已经串行化了（AudioEffectProcessor.settleActive），这里再加一道进程内互斥，
 * 兜住「两条链路同时进来」的情况：宁可让后来者明确失败并回退原始音源，也不要两败俱伤。
 */
std::mutex g_suiteMutex;

void writeWavHeader(std::ofstream &os, uint32_t dataBytes, uint32_t sampleRate, uint16_t channels) {
    const uint16_t bits = 16;
    const uint32_t byteRate = sampleRate * channels * bits / 8;
    const uint16_t blockAlign = channels * bits / 8;
    char h[44] = {0};
    std::memcpy(h + 0, "RIFF", 4);
    uint32_t riff = 36 + dataBytes;
    std::memcpy(h + 4, &riff, 4);
    std::memcpy(h + 8, "WAVE", 4);
    std::memcpy(h + 12, "fmt ", 4);
    uint32_t fmtLen = 16;
    std::memcpy(h + 16, &fmtLen, 4);
    uint16_t audioFormat = 1;
    std::memcpy(h + 20, &audioFormat, 2);
    std::memcpy(h + 22, &channels, 2);
    std::memcpy(h + 24, &sampleRate, 4);
    std::memcpy(h + 28, &byteRate, 4);
    std::memcpy(h + 32, &blockAlign, 2);
    std::memcpy(h + 34, &bits, 2);
    std::memcpy(h + 36, "data", 4);
    std::memcpy(h + 40, &dataBytes, 4);
    os.write(h, 44);
}

// 频谱能量计：low = 相邻样本和（低频响应强），high = 相邻样本差（高频响应强）。
// 对齐/延迟不敏感，适合做「EQ 是否真的改了频谱」的流式自检。
struct SpectrumMeter {
    double lowSq = 0.0;
    double highSq = 0.0;
    double prev = 0.0;
    bool hasPrev = false;
    void feed(float x) {
        if (hasPrev) {
            const double sum = static_cast<double>(x) + prev;
            const double dif = static_cast<double>(x) - prev;
            lowSq += sum * sum;
            highSq += dif * dif;
        }
        prev = x;
        hasPrev = true;
    }
    // 低频/高频能量比；高频能量极小（近 DC 信号）时返回 -1 表示不可用
    double lowHighRatio() const {
        if (highSq < 1e-12) return -1.0;
        return lowSq / highSq;
    }
};

// 流水线上下文：解码线程（生产者）与 AudioSuite 拉取回调（消费者）之间的有界队列。
struct StreamCtx {
    std::mutex m;
    std::condition_variable cvPop;
    std::condition_variable cvPush;
    std::deque<std::vector<float>> chunks;   // 交错 float 样本块
    size_t queued = 0;                       // 队列中 float 样本总数
    size_t cap = 4u * 1024u * 1024u;         // 队列上限（float 样本数，约 16MB）
    std::atomic<bool> producerDone{false};
    std::atomic<bool> failed{false};
    // ---- 诊断计数：只为了让失败时能说清「卡在哪一步」（见 EqResult.inChunks 等）----
    std::atomic<int64_t> inChunks{0};      // 解码回调推出的 PCM 块数
    std::atomic<int64_t> inSamples{0};     // 推出的 float 样本数（交错）
    std::atomic<int> timeouts{0};          // 消费端「20 秒没新数据」的次数
    std::atomic<int32_t> decoderError{-1}; // 解码器 onError 的错误码
    /**
     * 解码输出里遇到**完全不认识的采样格式**（未来新增的枚举值）。
     * planar（OH_BitsPerSample 5~9）现在已经支持（见 appendPlanarAsFloat），这里只兜未知值。
     * 原先是按 U8 interleaved 硬套，等于把整首歌变成噪声还报成功；
     * 这里记下原始 OH_BitsPerSample 值（-1 = 没遇到），收尾时据此报明确失败。
     */
    std::atomic<int32_t> unsupportedFormat{-1};
    /**
     * planar 数据无法安全反交织：声道数非法，或字节数不是「整帧 × 声道数 × 位深」的整数倍。
     * 0 = 没遇到，1 = 遇到。收尾时按失败返回——宁可整首回退原声，也不把错位/半帧数据当成功。
     */
    std::atomic<int32_t> planarLayoutError{0};
    std::atomic<bool> eosSeen{false};      // 是否收到 EOS 输出
    const volatile bool *cancel = nullptr;
    OH_AVDemuxer *demuxer = nullptr;         // 回调线程用它读下一帧
    uint32_t audioTrack = 0;
    int32_t bitsPerSample = SAMPLE_S16LE;    // OH_BitsPerSample（解码器实际输出格式，含 planar）
    int32_t channels = 2;                    // 解码输出**真实**声道数（由输出描述读取；planar 反交织必须用它）
    SpectrumMeter inMeter;

    bool stopRequested() const {
        return failed.load() || (cancel != nullptr && *cancel);
    }

    // 生产者：塞一块 float（交错）。背压：队列满时等待，cancel/failed 随时唤醒。
    void push(std::vector<float> &&chunk) {
        if (chunk.empty()) return;
        /**
         * 频谱计数挪到锁外：inMeter 只由解码回调线程写入，本来就不需要队列锁保护。
         * 原来这一行在锁内，等于每塞一块都要持着队列锁做几千次浮点运算，
         * 消费者（RenderFrame 的拉取回调）在同一个锁上只能干等。
         */
        for (float x : chunk) inMeter.feed(x);

        std::unique_lock<std::mutex> lk(m);
        while (!stopRequested() && !producerDone.load() && queued >= cap) {
            cvPush.wait_for(lk, std::chrono::milliseconds(50));
        }
        if (stopRequested()) return;
        queued += chunk.size();
        inSamples.fetch_add(static_cast<int64_t>(chunk.size()));
        inChunks.fetch_add(1);
        chunks.emplace_back(std::move(chunk));
        cvPop.notify_one();
    }

    void finish() {
        {
            std::lock_guard<std::mutex> lk(m);
            producerDone.store(true);
        }
        cvPop.notify_all();
        cvPush.notify_all();
    }

    void abort() {
        failed.store(true);
        finish();
    }
};

// 消费者：从队列拉样本填进 AudioSuite 要的缓冲。EOF 时置 finished。
int32_t pullForAudioSuite(OH_AudioNode *, void *ud, void *audioData, int32_t size, bool *finished) {
    auto *ctx = static_cast<StreamCtx *>(ud);
    const size_t want = static_cast<size_t>(size) / sizeof(float);
    auto *out = static_cast<float *>(audioData);
    size_t filled = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    *finished = false;
    while (filled < want) {
        bool done = false;
        bool gotData = false;
        {
            std::unique_lock<std::mutex> lk(ctx->m);
            while (ctx->chunks.empty() && !ctx->producerDone.load() && !ctx->stopRequested()) {
                if (std::chrono::steady_clock::now() > deadline) {
                    // 解码器长时间无产出：按失败收场，避免异步任务永远挂着
                    ctx->timeouts.fetch_add(1);
                    ctx->failed.store(true);
                    break;
                }
                ctx->cvPop.wait_for(lk, std::chrono::milliseconds(100));
            }
            if (!ctx->chunks.empty()) {
                std::vector<float> &front = ctx->chunks.front();
                const size_t n = std::min(want - filled, front.size());
                std::memcpy(out + filled, front.data(), n * sizeof(float));
                filled += n;
                if (n == front.size()) {
                    ctx->chunks.pop_front();
                } else {
                    front.erase(front.begin(), front.begin() + static_cast<long>(n));
                }
                ctx->queued -= n;
                ctx->cvPush.notify_one();
                gotData = true;
            } else if (ctx->producerDone.load() && !ctx->stopRequested()) {
                done = true;  // EOF：全部消费完
            }
        }
        if (ctx->stopRequested()) return -1;
        if (done && !gotData) {
            *finished = true;
            break;
        }
    }
    return static_cast<int32_t>(filled * sizeof(float));
}

/**
 * 解码器实际输出的采样格式（**interleaved**，各声道样本交错存放）。
 * SAMPLE_*P（5~9）是 planar 布局，走下面的 appendPlanarAsFloat；
 * 未来新增的枚举值同样不可知，一律判失败，绝不能落进「默认当 U8」的分支把整首歌变成噪声。
 */
bool isInterleavedSampleFormat(int32_t bits) {
    return bits == SAMPLE_U8 || bits == SAMPLE_S16LE || bits == SAMPLE_S24LE ||
           bits == SAMPLE_S32LE || bits == SAMPLE_F32LE;
}

/**
 * planar（平面）采样格式：每个声道的数据各自连续存放（ch0 的全部样本、ch1 的全部样本…）。
 * 与 interleaved 的差别只在**布局**，数值换算规则完全一样；
 * 单声道时 planar 与 interleaved 等价，反交织退化成原样拷贝。
 */
bool isPlanarSampleFormat(int32_t bits) {
    return bits == SAMPLE_U8P || bits == SAMPLE_S16P || bits == SAMPLE_S24P ||
           bits == SAMPLE_S32P || bits == SAMPLE_F32P;
}

// planar 每个样本占的字节数（U8P=1 / S16P=2 / S24P=3 / S32P=F32P=4）；非 planar 返回 0
size_t planarBytesPerSample(int32_t bits) {
    switch (bits) {
        case SAMPLE_U8P: return 1u;
        case SAMPLE_S16P: return 2u;
        case SAMPLE_S24P: return 3u;
        case SAMPLE_S32P:
        case SAMPLE_F32P: return 4u;
        default: return 0u;
    }
}

/** appendAsFloat 的返回：区分「未知格式」与「planar 布局异常」，收尾时给不同的中文 message */
enum class AppendResult {
    kOk = 0,
    kUnsupportedFormat = 1,   // OH_BitsPerSample 完全无法识别
    kBadPlanarLayout = 2,     // planar 声道数非法，或字节数不是整帧
};

// 解码输出样本 -> float（**interleaved**：按 OH_BitsPerSample 解释，交错原样保留）。
// 返回 false 表示采样格式无法识别，调用方必须按失败处理。
bool appendInterleavedAsFloat(const uint8_t *data, size_t bytes, int32_t bits, std::vector<float> &out) {
    /**
     * 按位深算出**精确**样本数，一次性 reserve 到位。
     *
     * 这里踩过一个单位错误：调用点原先写的是 `chunk.reserve(attr.size * 2u)`，
     * 而 `attr.size` 是**字节数**、reserve 要的是**样本个数**。于是 S16 多占 4 倍、
     * S24 多占 6 倍、F32 多占 8 倍——队列名义上限 16MB，实际堆占用被放大到几十上百 MB，
     * 低端机上就是内存压力（Hi-Res 全缓存那条 2300023 的坑同一个来源）。
     *
     * 用 reserve 而不是 resize：resize 会先把新增元素零初始化一遍，紧接着又被真实值覆盖，
     * 等于每个样本白写一次。reserve 之后 push_back 不再触发 realloc，只需一次边界比较。
     */
    size_t bytesPerSample = 0;
    switch (bits) {
        case SAMPLE_U8: bytesPerSample = 1u; break;
        case SAMPLE_S16LE: bytesPerSample = 2u; break;
        case SAMPLE_S24LE: bytesPerSample = 3u; break;
        case SAMPLE_S32LE:
        case SAMPLE_F32LE: bytesPerSample = 4u; break;
        default:
            // planar（5~9）由 appendPlanarAsFloat 处理；这里只兜未知格式：不猜、不降级
            return false;
    }
    if (bytes > 0) {
        out.reserve(out.size() + bytes / bytesPerSample);
    }

    switch (bits) {
        case SAMPLE_U8: {
            for (size_t i = 0; i < bytes; ++i) {
                out.push_back((static_cast<float>(data[i]) - 128.0f) / 128.0f);
            }
            break;
        }
        case SAMPLE_S16LE: {
            const size_t n = bytes / 2;
            for (size_t i = 0; i < n; ++i) {
                int16_t s = 0;
                std::memcpy(&s, data + i * 2, 2);
                out.push_back(static_cast<float>(s) / 32768.0f);
            }
            break;
        }
        case SAMPLE_S24LE: {
            const size_t n = bytes / 3;
            for (size_t i = 0; i < n; ++i) {
                int32_t v = static_cast<int32_t>(data[i * 3]) |
                            (static_cast<int32_t>(data[i * 3 + 1]) << 8) |
                            (static_cast<int32_t>(data[i * 3 + 2]) << 16);
                if (v & 0x800000) v -= 0x1000000;  // 符号扩展
                out.push_back(static_cast<float>(v) / 8388608.0f);
            }
            break;
        }
        case SAMPLE_S32LE: {
            const size_t n = bytes / 4;
            for (size_t i = 0; i < n; ++i) {
                int32_t v = 0;
                std::memcpy(&v, data + i * 4, 4);
                out.push_back(static_cast<float>(v) / 2147483648.0f);
            }
            break;
        }
        case SAMPLE_F32LE: {
            const size_t n = bytes / 4;
            for (size_t i = 0; i < n; ++i) {
                float v = 0.0f;
                std::memcpy(&v, data + i * 4, 4);
                out.push_back(v);
            }
            break;
        }
        default:
            // 上面已经挡过；这里只为让「漏了某个 case」在编译期能被 -Wswitch 提醒
            return false;
    }
    return true;
}

/**
 * planar（SAMPLE_*P）解码输出 -> interleaved float。
 *
 * 布局：共 frames 帧 × channels 声道，按声道分平面连续存放；
 * 第 f 帧第 ch 声道的样本位于 data + (ch * frames + f) * bytesPerSample。
 * AudioSuite 只吃 interleaved，所以这里逐帧把各声道重排成交错顺序；
 * channels==1 时各声道只有一轨，结果与 planar 原样一致。
 *
 * 返回 false 表示无法安全反交织（声道数非法 / 字节数不是整帧）：
 * 宁可整首失败回退原声，也不能把错位或半帧数据交给 EQ（那会是噪声）。
 */
bool appendPlanarAsFloat(const uint8_t *data, size_t bytes, int32_t bits, int32_t channels,
                         std::vector<float> &out) {
    const size_t bytesPerSample = planarBytesPerSample(bits);
    if (bytesPerSample == 0 || channels <= 0) {
        return false;
    }
    const size_t frameBytes = bytesPerSample * static_cast<size_t>(channels);
    if (frameBytes == 0 || bytes % frameBytes != 0) {
        return false;  // 半帧 / 不是整帧：反交织必然错位，按失败处理
    }
    const size_t frames = bytes / frameBytes;
    if (frames == 0) {
        return true;
    }
    // 输出样本数 = frames × channels，与 bytes / bytesPerSample 相等
    out.reserve(out.size() + frames * static_cast<size_t>(channels));

    switch (bits) {
        case SAMPLE_U8P: {
            for (size_t f = 0; f < frames; ++f) {
                for (int32_t ch = 0; ch < channels; ++ch) {
                    const uint8_t v = data[static_cast<size_t>(ch) * frames + f];
                    out.push_back((static_cast<float>(v) - 128.0f) / 128.0f);
                }
            }
            break;
        }
        case SAMPLE_S16P: {
            for (size_t f = 0; f < frames; ++f) {
                for (int32_t ch = 0; ch < channels; ++ch) {
                    const uint8_t *p = data + (static_cast<size_t>(ch) * frames + f) * 2u;
                    int16_t s = 0;
                    std::memcpy(&s, p, 2);
                    out.push_back(static_cast<float>(s) / 32768.0f);
                }
            }
            break;
        }
        case SAMPLE_S24P: {
            for (size_t f = 0; f < frames; ++f) {
                for (int32_t ch = 0; ch < channels; ++ch) {
                    const uint8_t *p = data + (static_cast<size_t>(ch) * frames + f) * 3u;
                    int32_t v = static_cast<int32_t>(p[0]) |
                                (static_cast<int32_t>(p[1]) << 8) |
                                (static_cast<int32_t>(p[2]) << 16);
                    if (v & 0x800000) v -= 0x1000000;  // 符号扩展（与 interleaved S24 一致）
                    out.push_back(static_cast<float>(v) / 8388608.0f);
                }
            }
            break;
        }
        case SAMPLE_S32P: {
            for (size_t f = 0; f < frames; ++f) {
                for (int32_t ch = 0; ch < channels; ++ch) {
                    const uint8_t *p = data + (static_cast<size_t>(ch) * frames + f) * 4u;
                    int32_t v = 0;
                    std::memcpy(&v, p, 4);
                    out.push_back(static_cast<float>(v) / 2147483648.0f);
                }
            }
            break;
        }
        case SAMPLE_F32P: {
            for (size_t f = 0; f < frames; ++f) {
                for (int32_t ch = 0; ch < channels; ++ch) {
                    const uint8_t *p = data + (static_cast<size_t>(ch) * frames + f) * 4u;
                    float v = 0.0f;
                    std::memcpy(&v, p, 4);
                    out.push_back(v);
                }
            }
            break;
        }
        default:
            return false;  // 不会发生（入口已判 planar），防御
    }
    return true;
}

/**
 * 统一入口：interleaved 与 planar 分派。
 * planar 分支是新增的；interleaved 分支仍是原实现（只是拆成 appendInterleavedAsFloat），
 * 因此正常路径（1/2 声道、S16/S24/F32 interleaved）的产物逐字节不变。
 */
AppendResult appendAsFloat(const uint8_t *data, size_t bytes, int32_t bits, int32_t channels,
                           std::vector<float> &out) {
    if (isPlanarSampleFormat(bits)) {
        return appendPlanarAsFloat(data, bytes, bits, channels, out)
                   ? AppendResult::kOk
                   : AppendResult::kBadPlanarLayout;
    }
    return appendInterleavedAsFloat(data, bytes, bits, out)
               ? AppendResult::kOk
               : AppendResult::kUnsupportedFormat;
}

}  // namespace

namespace {

/** 输入形态：本地路径 / 网络地址 / 已打开的 fd（三种只在「解封装源怎么打开」这一步不同） */
enum class InputKind {
    kPath = 0,
    kUrl = 1,
    kFd = 2,
};

/**
 * 管线主体。
 * 三种输入只在「解封装源怎么打开」这一步不同，后面完全共用。
 */
EqResult runPipeline(const std::string &input,
                     InputKind kind,
                     int32_t fd,
                     const std::string &outPath,
                     const int32_t *gains,
                     const volatile bool *cancel) {
    EqResult r;
    if (gains == nullptr) {
        r.code = kErrAudioSuite;
        r.message = "EQ 增益参数为空";
        return r;
    }

    // ---------- 1. 解封装 ----------
    OH_AVSource *source = nullptr;
    int64_t inputBytes = 0;   // 压缩源的大小（估时长用；网络源未知为 0）
    /**
     * kPath 的 FD 回退分支自己 open 的 fd（-1 = 没有自己打开的 fd）。
     * AVSource 的 fd 契约是「调用方在 source 存活期间保持 fd 有效」，
     * 所以这个 fd 只能在 OH_AVSource_Destroy 之后关，统一由 releaseSource 收尾。
     */
    int32_t ownedFd = -1;
    if (kind == InputKind::kUrl) {
        // 网络源：系统解封装器自己拉流（渐进式格式），不必先落地整份文件。
        source = OH_AVSource_CreateWithURI(const_cast<char *>(input.c_str()));
        if (source == nullptr) {
            r.code = kErrOpenSource;
            r.message = "无法打开网络音频地址（格式不支持或网络不可用）";
            return r;
        }
    } else if (kind == InputKind::kFd) {
        // 调用方已经按它自己的权限通道打开了文件（文件选择器导入的音乐走这条）。
        struct stat st {};
        if (fd < 0 || fstat(fd, &st) != 0 || st.st_size <= 0) {
            r.code = kErrOpenSource;
            r.message = "无法读取音频文件大小";
            return r;
        }
        source = OH_AVSource_CreateWithFD(fd, 0, static_cast<int64_t>(st.st_size));
        if (source == nullptr) {
            r.code = kErrOpenSource;
            r.message = "创建音视频源失败（文件损坏或格式不支持）";
            return r;
        }
        inputBytes = static_cast<int64_t>(st.st_size);
    } else {
        FILE *fp = std::fopen(input.c_str(), "rb");
        if (fp == nullptr) {
            r.code = kErrOpenSource;
            r.message = "无法打开输入音频文件";
            return r;
        }
        std::fseek(fp, 0, SEEK_END);
        const int64_t fileSize = std::ftell(fp);
        std::fclose(fp);
        if (fileSize <= 0) {
            r.code = kErrOpenSource;
            r.message = "输入音频文件为空";
            return r;
        }
        inputBytes = fileSize;

        source = OH_AVSource_CreateWithURI(
            const_cast<char *>(("file://" + input).c_str()));
        if (source == nullptr) {
            // URI 方式失败时退回 FD 方式
            int fd = open(input.c_str(), O_RDONLY);
            if (fd < 0) {
                r.code = kErrOpenSource;
                r.message = "无法打开音频文件";
                return r;
            }
            source = OH_AVSource_CreateWithFD(fd, 0, fileSize);
            if (source == nullptr) {
                close(fd);
                r.code = kErrOpenSource;
                r.message = "创建音视频源失败（文件损坏或格式不支持）";
                return r;
            }
            // 创建成功也不能立刻关：AVSource 后续读数据还要用这个 fd，
            // 交给收尾的 releaseSource 在 OH_AVSource_Destroy 之后关闭。
            ownedFd = fd;
        }
    }

    /**
     * 统一的 source 收尾：先销毁 AVSource，再关闭我们自己打开的 fd（顺序不能反，
     * 否则 source 存活期间 fd 已失效，读数据行为未定义）。所有失败/正常返回路径都走它，
     * 避免漏关或 double close（kUrl/kFd 的 ownedFd 恒为 -1，不会误关调用方的 fd）。
     */
    auto releaseSource = [&]() {
        if (source != nullptr) {
            OH_AVSource_Destroy(source);
            source = nullptr;
        }
        if (ownedFd >= 0) {
            close(ownedFd);
            ownedFd = -1;
        }
    };

    OH_AVDemuxer *demuxer = OH_AVDemuxer_CreateWithSource(source);
    if (demuxer == nullptr) {
        releaseSource();
        r.code = kErrDemuxer;
        r.message = "创建解封装器失败";
        return r;
    }

    OH_AVFormat *srcFormat = OH_AVSource_GetSourceFormat(source);
    int32_t trackCount = 0;
    int64_t srcDurationUs = 0;
    int64_t srcBitrate = 0;
    if (srcFormat != nullptr) {
        OH_AVFormat_GetIntValue(srcFormat, OH_MD_KEY_TRACK_COUNT, &trackCount);
        OH_AVFormat_GetLongValue(srcFormat, OH_MD_KEY_DURATION, &srcDurationUs);
        OH_AVFormat_GetLongValue(srcFormat, OH_MD_KEY_BITRATE, &srcBitrate);
        OH_AVFormat_Destroy(srcFormat);
    }
    int32_t audioTrack = -1;
    std::string mime;
    int64_t durationUs = 0;
    for (int32_t i = 0; i < trackCount; ++i) {
        OH_AVFormat *tf = OH_AVSource_GetTrackFormat(source, i);
        if (tf == nullptr) continue;
        const char *m = nullptr;
        if (OH_AVFormat_GetStringValue(tf, OH_MD_KEY_CODEC_MIME, &m) && m != nullptr &&
            std::strncmp(m, "audio/", 6) == 0) {
            audioTrack = i;
            mime = m;
            OH_AVFormat_GetLongValue(tf, OH_MD_KEY_DURATION, &durationUs);
            OH_AVFormat_Destroy(tf);
            break;
        }
        OH_AVFormat_Destroy(tf);
    }
    if (audioTrack < 0 || mime.empty()) {
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrNoAudioTrack;
        r.message = "文件里找不到音频轨道";
        return r;
    }

    /**
     * 总时长决定写进 WAV 头的 data 长度，也就决定了播放器认为这首有多长。
     * **写短了不是「显示不准」这么简单**：真机上「边处理边播」会正好播到那个长度就停住
     * 不再出声（也不会报完成）——FLAC 常见轨道级时长为 0，就是这条踩出来的。
     * 所以按「轨道 -> 容器 -> 码率×文件大小」依次兜底，拿到一个可信的值。
     */
    const char *durSource = "track";
    if (durationUs <= 0 && srcDurationUs > 0) {
        durationUs = srcDurationUs;
        durSource = "container";
    }
    if (durationUs <= 0 && srcBitrate > 0 && inputBytes > 0) {
        // 时长 = 字节数 × 8 / 码率（bps）。压缩源的码率与解出来的 PCM 长度没有直接关系，
        // 但用它算「容器有多长」是准的，正好是这里要的东西。
        durationUs = static_cast<int64_t>(
            static_cast<double>(inputBytes) * 8.0 * 1000000.0 / static_cast<double>(srcBitrate));
        durSource = "bitrate";
    }
    if (durationUs <= 0) {
        durSource = "none";
    }

    // ---------- 2. 解码器（新式 OH_AudioCodec，与 buffer 回调严格配套） ----------
    OH_AVCodec *decoder = OH_AudioCodec_CreateByMime(mime.c_str(), false);
    if (decoder == nullptr) {
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "创建音频解码器失败（格式不支持）";
        return r;
    }

    StreamCtx ctx;
    ctx.cancel = cancel;
    ctx.channels = 2;

    OH_AVCodecCallback cb{};
    cb.onError = [](OH_AVCodec *, int32_t code, void *ud) {
        auto *c = static_cast<StreamCtx *>(ud);
        c->decoderError.store(code);
        c->abort();
    };
    cb.onStreamChanged = [](OH_AVCodec *, OH_AVFormat *, void *) {};
    cb.onNeedInputBuffer = [](OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *ud) {
        auto *c = static_cast<StreamCtx *>(ud);
        if (c->stopRequested()) return;
        if (OH_AVDemuxer_ReadSampleBuffer(c->demuxer, c->audioTrack, buffer) == AV_ERR_OK) {
            OH_AVCodecBufferAttr attr{};
            OH_AVBuffer_GetBufferAttr(buffer, &attr);
            OH_AVBuffer_SetBufferAttr(buffer, &attr);
            OH_AudioCodec_PushInputBuffer(codec, index);
        } else {
            // 文件尾：送 EOS 包
            OH_AVCodecBufferAttr eos{};
            eos.size = 0;
            eos.flags = AVCODEC_BUFFER_FLAGS_EOS;
            OH_AVBuffer_SetBufferAttr(buffer, &eos);
            OH_AudioCodec_PushInputBuffer(codec, index);
        }
    };
    cb.onNewOutputBuffer = [](OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *ud) {
        auto *c = static_cast<StreamCtx *>(ud);
        OH_AVCodecBufferAttr attr{};
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0 &&
            !c->stopRequested()) {
            const uint8_t *data = OH_AVBuffer_GetAddr(buffer);
            if (data != nullptr) {
                std::vector<float> chunk;
                // 精确 reserve 在 appendAsFloat 里按位深算（原来这里按字节数预留，多占 4~8 倍）
                // planar 需要真实声道数反交织，所以把 c->channels（输出描述里读到的）一起传进去
                const AppendResult ar = appendAsFloat(data, static_cast<size_t>(attr.size),
                                                      c->bitsPerSample, c->channels, chunk);
                if (ar == AppendResult::kOk) {
                    c->push(std::move(chunk));
                } else {
                    // 未知格式或 planar 布局异常：记下现场并中止整趟处理，绝不把它当 U8 或当成功
                    if (ar == AppendResult::kUnsupportedFormat) {
                        c->unsupportedFormat.store(c->bitsPerSample);
                    } else {
                        c->planarLayoutError.store(1);
                    }
                    c->abort();
                }
            }
        }
        if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
            c->eosSeen.store(true);
            c->finish();
        }
        OH_AudioCodec_FreeOutputBuffer(codec, index);
    };
    if (OH_AudioCodec_RegisterCallback(decoder, cb, &ctx) != AV_ERR_OK) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "注册解码回调失败";
        return r;
    }

    // demuxer / 轨道信息给回调线程用
    ctx.demuxer = demuxer;
    ctx.audioTrack = static_cast<uint32_t>(audioTrack);

    if (OH_AVDemuxer_SelectTrackByID(demuxer, static_cast<uint32_t>(audioTrack)) != AV_ERR_OK) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDemuxer;
        r.message = "选择音频轨道失败";
        return r;
    }
    OH_AVFormat *inFmt = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(audioTrack));
    if (inFmt == nullptr || OH_AudioCodec_Configure(decoder, inFmt) != AV_ERR_OK) {
        if (inFmt != nullptr) OH_AVFormat_Destroy(inFmt);
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "配置解码器失败";
        return r;
    }
    OH_AVFormat_Destroy(inFmt);
    if (OH_AudioCodec_Prepare(decoder) != AV_ERR_OK) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "解码器 Prepare 失败";
        return r;
    }

    // 解码器实际输出格式：采样率/声道/位深都跟着音源走，否则会变调或按错位深解释
    uint32_t sampleRate = 44100;
    uint32_t channels = 2;
    int32_t bits = SAMPLE_S16LE;
    /** 声道数是否真的从输出描述里读到了：planar 反交织必须用它，拿不到就不能猜 */
    bool channelCountKnown = false;
    OH_AVFormat *outDesc = OH_AudioCodec_GetOutputDescription(decoder);
    if (outDesc != nullptr) {
        int32_t sr = 0;
        int32_t ch = 0;
        int32_t fmt = 0;
        if (OH_AVFormat_GetIntValue(outDesc, OH_MD_KEY_AUD_SAMPLE_RATE, &sr) && sr > 0) {
            sampleRate = static_cast<uint32_t>(sr);
        }
        if (OH_AVFormat_GetIntValue(outDesc, OH_MD_KEY_AUD_CHANNEL_COUNT, &ch) && ch > 0) {
            channels = static_cast<uint32_t>(ch);
            channelCountKnown = true;
        }
        if (OH_AVFormat_GetIntValue(outDesc, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &fmt)) {
            bits = fmt;
        }
        OH_AVFormat_Destroy(outDesc);
    }
    ctx.channels = static_cast<int32_t>(channels);
    ctx.bitsPerSample = bits;

    /**
     * AudioSuite 管线只按「单声道 / 立体声」配置（见下面 format.channelLayout）。
     * 多声道源若继续喂给 CH_LAYOUT_STEREO，交错数据会整体错位，产出的是没法听的音频；
     * 这里直接判失败，让 ArkTS 回退原声——宁可这首没有音效，也不要把错位音频当成功。
     */
    if (channels > 2) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrAudioSuite;
        r.message = "多声道暂不支持音效（声道数=" + std::to_string(channels) + "）";
        return r;
    }

    /**
     * 解码输出采样格式：
     * - interleaved U8/S16/S24/S32/F32（OH_BitsPerSample 0~4）：按交错原样解释（原有路径）；
     * - planar U8P/S16P/S24P/S32P/F32P（5~9）：每个声道的数据连续存放成平面，必须用
     *   **真实声道数**按帧反交织（见 appendPlanarAsFloat）；声道数拿不到就判失败——
     *   这里绝不能猜 2，猜错就是整首歌声道错位（噪声）。
     * - 其它未知枚举值：一律失败，绝不猜成 U8。
     * 解码回调里 appendAsFloat 还会再挡一次，防流中途切换格式。
     */
    const bool planarOutput = isPlanarSampleFormat(bits);
    if (!isInterleavedSampleFormat(bits) && !planarOutput) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "解码输出采样格式不支持（OH_BitsPerSample=" + std::to_string(bits) +
                    "，仅支持 interleaved U8/S16/S24/S32/F32 或 planar U8P/S16P/S24P/S32P/F32P）";
        return r;
    }
    if (planarOutput && (!channelCountKnown || channels == 0)) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "planar 解码输出拿不到真实声道数（OH_BitsPerSample=" + std::to_string(bits) +
                    "），为避免声道错位按失败回退原声";
        return r;
    }

    /**
     * AudioSuite 的采样率是**离散枚举**，必须和实际数据速率精确对上。
     *
     * 这里踩过一个安静的错：原来只列了 48k/32k/96k/8k/16k，其余全走 default → 44100。
     * 而 SDK 的 OH_Audio_SampleRate 其实覆盖 8k~192k 共 14 档，于是 88.2k / 176.4k / 192k
     * 这类 Hi-Res 音源被按 44.1k 声明：滤波器系数按 44.1k 算，数据却是 2~4 倍速率，
     * 频段中心频率被整体压缩到 1/2~1/4（16k 段实际作用在 32k~64k，等于完全没开，
     * 低频段也全部偏移）。系统不会报错，只会让 EQ 变成另一个形状。
     *
     * WAV 头仍然写**真实**采样率；这里只决定 AudioSuite 按什么速率处理。
     */
    OH_Audio_SampleRate suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_44100;
    bool rateMapped = true;
    switch (sampleRate) {
        case 8000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_8000; break;
        case 11025: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_11025; break;
        case 12000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_12000; break;
        case 16000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_16000; break;
        case 22050: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_22050; break;
        case 24000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_24000; break;
        case 32000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_32000; break;
        case 44100: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_44100; break;
        case 48000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_48000; break;
        case 64000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_64000; break;
        case 88200: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_88200; break;
        case 96000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_96000; break;
        case 176400: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_176400; break;
        case 192000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_192000; break;
        default:
            // 枚举里没有的怪速率（极少见）：退回 44.1k 并把这件事写进结果消息，
            // 免得又变成一条「听不出差别」的静默错误
            rateMapped = false;
            break;
    }

    if (OH_AudioCodec_Start(decoder) != AV_ERR_OK) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        r.code = kErrDecoder;
        r.message = "解码器 Start 失败";
        return r;
    }

    // 拿「音效引擎」独占权：算法是进程级单例，绝不并行（见 g_suiteMutex）。
    // 在启动解码器之后、建管线之前拿，且持有到函数结束（含 RenderFrame 与全部收尾）。
    std::unique_lock<std::mutex> suiteLock(g_suiteMutex, std::defer_lock);
    for (int i = 0; i < 100; ++i) {                 // 最多等 5s
        if (suiteLock.try_lock()) {
            break;
        }
        if (cancel != nullptr && *cancel) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (!suiteLock.owns_lock()) {
        OH_AudioCodec_Stop(decoder);
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        releaseSource();
        if (cancel != nullptr && *cancel) {
            r.code = kErrCancelled;
            r.message = "已取消";
        } else {
            r.code = kErrBusy;
            r.message = "音效引擎正被另一趟处理占用";
        }
        return r;
    }

    // ---------- 3. AudioSuite EQ（流式：RenderFrame 拉队列，输出直写 WAV） ----------
    OH_AudioSuiteEngine *engine = nullptr;
    OH_AudioSuitePipeline *pipeline = nullptr;
    OH_AudioNode *inNode = nullptr;
    OH_AudioNode *eqNode = nullptr;
    OH_AudioNode *outNode = nullptr;
    std::ofstream os;
    bool ok = false;
    /** 管线是否真的 StartPipeline 成功过（收尾时决定要不要 Stop） */
    bool started = false;
    /**
     * 落盘是否失败过（磁盘满 / 配额超限 / I/O 错误）
     *
     * 原来完全不看 os 的状态：写不进去就静默产出一个半截 WAV，收尾还照常回填头、
     * 报成功 —— 用户听到的是「放到一半没了」，我们这边日志里一切正常。
     */
    bool writeFailed = false;
    /**
     * 渲染循环失败标志（P0：以前只 break、不看结果，收尾照样回填头并报成功）
     * - renderFailed：RenderFrame 返回非 SUCCESS，或拉取回调返回负数（解码中止/超时）
     * - guardExhausted：循环跑满 guard 上限仍未 finished（渲染器不推进 / 数据量异常）
     * 任一为 true 都**不回填 WAV 头**，按失败返回，让 ArkTS 回退原声。
     */
    bool renderFailed = false;
    bool guardExhausted = false;
    /** 输出已超过 WAV 头 uint32 长度能表示的范围（~4GB），继续写只会得到假的长度 */
    bool tooLarge = false;
    uint32_t dataBytes = 0;
    uint32_t flushed = 0;
    SpectrumMeter outMeter;
    int64_t outSamples = 0;

    if (OH_AudioSuiteEngine_Create(&engine) != AUDIOSUITE_SUCCESS || engine == nullptr) {
        r.code = kErrAudioSuite;
        r.message = "创建音效引擎失败";
    } else if (OH_AudioSuiteEngine_CreatePipeline(engine, &pipeline,
                 OH_AudioSuite_PipelineWorkMode::AUDIOSUITE_PIPELINE_EDIT_MODE) != AUDIOSUITE_SUCCESS ||
               pipeline == nullptr) {
        r.code = kErrAudioSuite;
        r.message = "创建音效管线失败";
    } else {
        OH_AudioFormat format{};
        format.samplingRate = suiteRate;
        format.channelLayout = channels >= 2 ? OH_AudioChannelLayout::CH_LAYOUT_STEREO
                                             : OH_AudioChannelLayout::CH_LAYOUT_MONO;
        format.channelCount = channels;
        format.encodingType = OH_Audio_EncodingType::AUDIO_ENCODING_TYPE_RAW;
        format.sampleFormat = OH_Audio_SampleFormat::AUDIO_SAMPLE_F32LE;

        bool built = true;
        bool gainsOk = true;
        OH_AudioNodeBuilder *b = nullptr;
        OH_AudioSuiteNodeBuilder_Create(&b);
        if (b == nullptr ||
            OH_AudioSuiteNodeBuilder_SetNodeType(b, OH_AudioNode_Type::INPUT_NODE_TYPE_DEFAULT) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteNodeBuilder_SetFormat(b, format) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteNodeBuilder_SetRequestDataCallback(b, pullForAudioSuite, &ctx) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteEngine_CreateNode(pipeline, b, &inNode) != AUDIOSUITE_SUCCESS) {
            built = false;
        }
        if (b != nullptr) OH_AudioSuiteNodeBuilder_Destroy(b);

        OH_AudioSuiteNodeBuilder_Create(&b);
        if (b == nullptr ||
            OH_AudioSuiteNodeBuilder_SetNodeType(b, OH_AudioNode_Type::EFFECT_NODE_TYPE_EQUALIZER) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteEngine_CreateNode(pipeline, b, &eqNode) != AUDIOSUITE_SUCCESS) {
            built = false;
        }
        if (b != nullptr) OH_AudioSuiteNodeBuilder_Destroy(b);
        if (eqNode != nullptr) {
            OH_EqualizerFrequencyBandGains eg{};
            for (int i = 0; i < EQUALIZER_BAND_NUM; ++i) eg.gains[i] = clampGain(gains[i]);
            // 设不上就别起管线：带着半初始化的 EQ 节点 StartPipeline，系统库会崩
            if (OH_AudioSuiteEngine_SetEqualizerFrequencyBandGains(eqNode, eg) != AUDIOSUITE_SUCCESS) {
                gainsOk = false;
            }
        }

        OH_AudioSuiteNodeBuilder_Create(&b);
        if (b == nullptr ||
            OH_AudioSuiteNodeBuilder_SetNodeType(b, OH_AudioNode_Type::OUTPUT_NODE_TYPE_DEFAULT) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteNodeBuilder_SetFormat(b, format) != AUDIOSUITE_SUCCESS ||
            OH_AudioSuiteEngine_CreateNode(pipeline, b, &outNode) != AUDIOSUITE_SUCCESS) {
            built = false;
        }
        if (b != nullptr) OH_AudioSuiteNodeBuilder_Destroy(b);

        if (!built || inNode == nullptr || eqNode == nullptr || outNode == nullptr) {
            r.code = kErrAudioSuite;
            r.message = "创建音效节点失败";
        } else if (!gainsOk) {
            r.code = kErrAudioSuite;
            r.message = "音效参数被系统拒绝（增益需在 -10~+10 dB）";
        } else if (OH_AudioSuiteEngine_ConnectNodes(inNode, eqNode) != AUDIOSUITE_SUCCESS ||
                   OH_AudioSuiteEngine_ConnectNodes(eqNode, outNode) != AUDIOSUITE_SUCCESS) {
            r.code = kErrAudioSuite;
            r.message = "连接音效节点失败";
        } else if (OH_AudioSuiteEngine_StartPipeline(pipeline) != AUDIOSUITE_SUCCESS) {
            r.code = kErrAudioSuite;
            r.message = "启动音效管线失败";
        } else {
            // 只有真起来了才记得要 Stop：没启动的管线去 Stop 是另一条未定义的路径
            started = true;
            os.open(outPath, std::ios::binary | std::ios::trunc);
            if (!os.is_open()) {
                r.code = kErrWriteWav;
                r.message = "无法创建输出文件";
            } else {
                // 流式播放要求头部先声明总长度（否则播放器会认为时长 0 而不播）。
                // 用轨道时长估一个接近真实的数据长度，收尾时再按实际值回填。
                uint32_t estimate = 0;
                if (durationUs > 0) {
                    const double secs = static_cast<double>(durationUs) / 1000000.0;
                    const double bytes = secs * static_cast<double>(sampleRate) *
                                         static_cast<double>(channels) * 2.0;
                    if (bytes > 0.0 && bytes < 4.0e9) {
                        estimate = static_cast<uint32_t>(bytes);
                    }
                }
                if (estimate == 0) {
                    /**
                     * 轨道/容器/码率三级兜底全为 0（FLAC 常见）：写 0 会让播放器认为
                     * 时长 0 直接不播。这里给一个「1 小时」的下限兜住启动，
                     * 收尾仍按真实 dataBytes 回填，所以只是临时的过估。
                     * 用 uint64 计算，再夹到 RIFF 字段安全上限（36 + dataBytes 不能溢出）。
                     */
                    constexpr uint64_t kRiffMax = 0xFFFFFFFFull - 36ull;
                    const uint64_t oneHour = static_cast<uint64_t>(sampleRate) *
                                             static_cast<uint64_t>(channels) * 2ull * 3600ull;
                    estimate = static_cast<uint32_t>(oneHour > kRiffMax ? kRiffMax : oneHour);
                }
                writeWavHeader(os, estimate, sampleRate, static_cast<uint16_t>(channels));
                os.flush();  // 立刻落盘，让播放器能尽早读到头部
                ok = true;
            }
        }
    }

    if (ok) {
        /**
         * 渲染缓冲 4096 个 float。对 1/2 声道都是**整帧**：
         *   单声道 4096 floats = 4096 帧；立体声 4096 floats = 2048 帧。
         * RenderFrame 的 requestFrameSize 单位是字节（这里是 16384B），两种声道数下
         * 都能被「声道数 × 4 字节」整除，不会出现半帧被截断。
         */
        constexpr int32_t kChunkFloats = 4096;
        std::vector<float> buf(kChunkFloats);
        /**
         * 转成 16bit 的落地缓冲：攒一块写一次，而不是每个样本写一次。
         * 一首 4 分钟 44.1k 立体声有 2100 万个样本，原来的 `os.write(&s, 2)`
         * 要过 2100 万次 streambuf 调用（每次只写 2 字节），是应用层最大的一笔开销。
         * 在循环外分配一次，循环内只剩内存写。
         */
        std::vector<int16_t> pcm(kChunkFloats);
        bool finished = false;
        for (int guard = 0; guard < 2000000 && !finished; ++guard) {
            if (ctx.stopRequested()) break;
            int32_t got = 0;
            OH_AudioSuite_Result res = OH_AudioSuiteEngine_RenderFrame(
                pipeline, buf.data(), static_cast<int32_t>(kChunkFloats * sizeof(float)), &got, &finished);
            if (res != AUDIOSUITE_SUCCESS || got < 0) {
                // 渲染器错误 / 拉取回调返回负数（解码中止、20s 无数据超时等）：
                // 以前这里只 break，收尾照常回填头并报成功 —— 用户拿到的是半截 WAV。
                renderFailed = true;
                break;
            }
            if (got == 0) continue;
            const int32_t n = got / static_cast<int32_t>(sizeof(float));
            /**
             * WAV 的 RIFF/data 长度字段是 uint32，最大 ~4GB。累加前先挡：
             * 超过就按失败收场（调用方回退原声），不要让 dataBytes 溢出后写一个假长度。
             */
            if (static_cast<uint64_t>(dataBytes) + static_cast<uint64_t>(n) * 2ull > 0xFFFF0000ull) {
                tooLarge = true;
                break;
            }
            /**
             * 一次遍历同时做：软限幅 / 频谱计数 / 转 16bit。
             *
             * 这里的 clamp 与舍入必须保持原样（std::max + std::min + std::lround）：
             * std::min(1.0f, NaN) 返回 1.0f，换成三元判断会把 NaN 放过去；
             * lround 是「四舍五入远离零」，换成截断会整体差 1 LSB。
             * 软限幅只改 |x| > 0.9 的过载样本（见 softLimit），正常电平产物不变。
             */
            for (int32_t i = 0; i < n; ++i) {
                const float f = softLimit(buf[static_cast<size_t>(i)]);
                outMeter.feed(f);
                pcm[static_cast<size_t>(i)] = static_cast<int16_t>(
                    std::lround(std::max(-1.0f, std::min(1.0f, f)) * 32767.0f));
            }
            outSamples += n;
            os.write(reinterpret_cast<const char *>(pcm.data()),
                     static_cast<std::streamsize>(n) * static_cast<std::streamsize>(sizeof(int16_t)));
            dataBytes += static_cast<uint32_t>(n) * 2u;
            // 边写边落盘：播放器要能读到已产出的部分才能边播边处理
            if (dataBytes - flushed >= 64u * 1024u) {
                os.flush();
                flushed = dataBytes;
                // 每 64KB 看一次状态位：真写不进去（磁盘满）就立刻收手，别再空转解码
                if (!os.good()) {
                    writeFailed = true;
                    break;
                }
            }
        }
        os.flush();
        if (!os.good()) {
            writeFailed = true;
        }
        /**
         * 结束却没等到 finished：排除取消（*cancel）/解码失败/落盘失败/超 4GB 之后，
         * 就只剩「guard 跑满 200 万次渲染仍未 EOS」这一种可能（渲染器不推进或数据量异常），
         * 同样不能当成功返回。
         */
        if (!finished && !ctx.stopRequested() && !writeFailed && !tooLarge && !renderFailed) {
            guardExhausted = true;
        }
    }

    // ---------- 4. 收尾：先停消费者（pipeline），再停解码生产者 ----------
    const bool cancelled = (cancel != nullptr && *cancel);
    /**
     * 注意：必须在 ctx.abort() **之前**取这个快照。
     * abort() 是为了唤醒还卡在队列上的解码回调线程，它自己就会把 failed 置 true；
     * 如果判定写在 abort 之后，那每一次正常跑完的任务都会被当成「解码失败」——
     * 产物被调用方当场删掉、缓存状态永远是失败（真机上就是这么表现的：
     * 听着没问题，日志里却一条成功都没有）。
     */
    const bool ctxFailed = ctx.failed.load();
    /** 解码回调里挡下的**未知**采样格式（-1 = 没遇到；planar 5~9 现已支持，不算未知） */
    const int32_t unsupportedBits = ctx.unsupportedFormat.load();
    /** 解码回调里 planar 数据无法按帧反交织（0 = 没遇到） */
    const bool planarLayoutBad = ctx.planarLayoutError.load() != 0;
    /** 解码器报过错：failed 标志（含 20s 无数据超时）或 onError 回调（初值 -1）都算 */
    const bool decoderErrored = ctxFailed || ctx.decoderError.load() >= 0;
    const bool renderAborted = renderFailed || guardExhausted;
    /**
     * 任何一类失败都不回填 WAV 头：半截产物交给调用方按失败删掉，
     * 绝不能「回填一个看起来正常的头 + r.ok=true」让上层把它当成品。
     */
    const bool processingFailed =
        decoderErrored || unsupportedBits >= 0 || planarLayoutBad || renderAborted ||
        writeFailed || tooLarge;
    if (pipeline != nullptr) {
        if (started) OH_AudioSuiteEngine_StopPipeline(pipeline);
        OH_AudioSuiteEngine_DestroyPipeline(pipeline);
    }
    if (engine != nullptr) {
        OH_AudioSuiteEngine_Destroy(engine);
    }
    ctx.abort();  // 唤醒可能还在等队列的解码回调线程
    OH_AudioCodec_Stop(decoder);
    OH_AudioCodec_Destroy(decoder);
    OH_AVDemuxer_Destroy(demuxer);
    releaseSource();

    if (os.is_open()) {
        // 写失败的产物是半截的：头也不用回填了，交给调用方当失败删掉
        if (ok && !processingFailed && !cancelled && dataBytes > 0) {
            // 回填 WAV 头里的真实 data 长度
            os.seekp(0, std::ios::beg);
            writeWavHeader(os, dataBytes, sampleRate, static_cast<uint16_t>(channels));
            os.flush();
        }
        os.close();
    }

    if (cancelled) {
        r.code = kErrCancelled;
        r.message = "已取消";
        return r;
    }
    // 现场计数：失败时一定带上，方便判断是「解码器报错」还是「消费端等不到数据」
    r.inChunks = ctx.inChunks.load();
    r.inSamples = ctx.inSamples.load();
    r.timeouts = ctx.timeouts.load();
    r.decoderError = ctx.decoderError.load();
    if (planarLayoutBad) {
        // planar 反交织失败：要么声道数非法，要么字节数不是整帧；宁可回退原声也不出噪声
        r.code = kErrDecoder;
        r.message = "planar 解码输出无法按帧反交织（OH_BitsPerSample=" +
                    std::to_string(ctx.bitsPerSample) + " 声道数=" +
                    std::to_string(ctx.channels) + "），已按失败回退原声";
        return r;
    }
    if (unsupportedBits >= 0) {
        // 比通用解码失败更具体：未知位深会被按错格式解释成整首歌噪声
        r.code = kErrDecoder;
        r.message = "解码输出采样格式不支持（OH_BitsPerSample=" + std::to_string(unsupportedBits) +
                    "，仅支持 interleaved U8/S16/S24/S32/F32 或 planar U8P/S16P/S24P/S32P/F32P）";
        return r;
    }
    if (decoderErrored) {
        r.code = kErrDecoder;
        const bool eos = ctx.eosSeen.load();
        r.message = "音频解码失败或超时（块=" + std::to_string(r.inChunks) +
                    " 样本=" + std::to_string(r.inSamples) +
                    " 超时=" + std::to_string(r.timeouts) +
                    " 解码错误码=" + std::to_string(r.decoderError) +
                    (eos ? " 已收到EOS" : " 未收到EOS") + "）";
        return r;
    }
    if (renderAborted) {
        // 渲染循环没正常跑完：绝不能回填头报成功（产物是半截的）
        r.code = kErrAudioSuite;
        r.message = std::string("音效渲染失败（") +
                    (guardExhausted ? "渲染循环超出保护上限" : "渲染器返回错误") +
                    " 块=" + std::to_string(r.inChunks) +
                    " 样本=" + std::to_string(r.inSamples) +
                    " 超时=" + std::to_string(r.timeouts) + "）";
        return r;
    }
    if (writeFailed) {
        // 优先级排在「无输出」之前：有数据但没写全，真实原因是落盘失败
        r.code = kErrWriteWav;
        r.message = "写入输出文件失败（磁盘空间不足或存储配额超限）";
        return r;
    }
    if (tooLarge) {
        // WAV 头是 32 位长度：超过 ~4GB 只能失败（产物会写出一个被截断的假长度）
        r.code = kErrWriteWav;
        r.message = "输出音频超过 WAV 长度上限（约 4GB），无法写入";
        return r;
    }
    if (!ok || dataBytes == 0 || outSamples == 0) {
        r.code = ok ? kErrAudioSuite : r.code;
        r.message = ok ? "音效处理失败（无输出）" : r.message;
        return r;
    }

    // 自检指标：输出/输入的低频/高频能量比之商。≈1.0 说明频谱没变（EQ 未生效），
    // >1 表示相对增强了低频，<1 表示增强了高频。对滤波延迟不敏感。
    const double inRatio = ctx.inMeter.lowHighRatio();
    const double outRatio = outMeter.lowHighRatio();
    if (inRatio > 0 && outRatio > 0) {
        r.delta = outRatio / inRatio;
    }

    r.ok = true;
    r.outBytes = 44 + dataBytes;
    r.durationUs = durationUs;
    r.sampleRate = static_cast<int32_t>(sampleRate);
    r.channels = static_cast<int32_t>(channels);
    // 输出帧数：交错样本 / 声道数。与 durationUs 一对比就知道「容器时长」可不可信
    r.outFrames = channels > 0 ? outSamples / static_cast<int64_t>(channels) : outSamples;
    r.message = std::string("durFrom=") + durSource + " bitrate=" + std::to_string(srcBitrate) +
                " inputBytes=" + std::to_string(inputBytes) +
                " suiteRate=" + std::to_string(static_cast<int32_t>(suiteRate)) +
                (rateMapped ? "" : "(unmapped!)");
    return r;
}

}  // namespace

EqResult processAudio(const std::string &inPath,
                      const std::string &outPath,
                      const int32_t *gains,
                      const volatile bool *cancel) {
    return runPipeline(inPath, InputKind::kPath, -1, outPath, gains, cancel);
}

EqResult processAudioUrl(const std::string &url,
                         const std::string &outPath,
                         const int32_t *gains,
                         const volatile bool *cancel) {
    return runPipeline(url, InputKind::kUrl, -1, outPath, gains, cancel);
}

EqResult processAudioFd(int32_t fd,
                        const std::string &outPath,
                        const int32_t *gains,
                        const volatile bool *cancel) {
    return runPipeline("", InputKind::kFd, fd, outPath, gains, cancel);
}

}  // namespace lxeq
