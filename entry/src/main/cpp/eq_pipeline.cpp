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
 * - 支持 8/16/24/32bit 与 float 解码输出（Hi-Res 音源常见 24bit）。
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
    std::atomic<bool> eosSeen{false};      // 是否收到 EOS 输出
    const volatile bool *cancel = nullptr;
    OH_AVDemuxer *demuxer = nullptr;         // 回调线程用它读下一帧
    uint32_t audioTrack = 0;
    int32_t bitsPerSample = SAMPLE_S16LE;    // OH_BitsPerSample（解码器实际输出格式）
    int32_t channels = 2;
    SpectrumMeter inMeter;

    bool stopRequested() const {
        return failed.load() || (cancel != nullptr && *cancel);
    }

    // 生产者：塞一块 float（交错）。背压：队列满时等待，cancel/failed 随时唤醒。
    void push(std::vector<float> &&chunk) {
        std::unique_lock<std::mutex> lk(m);
        while (!stopRequested() && !producerDone.load() && queued >= cap) {
            cvPush.wait_for(lk, std::chrono::milliseconds(50));
        }
        if (stopRequested() || chunk.empty()) return;
        queued += chunk.size();
        inSamples.fetch_add(static_cast<int64_t>(chunk.size()));
        inChunks.fetch_add(1);
        for (float x : chunk) inMeter.feed(x);
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

// 解码输出样本 -> float（按 OH_BitsPerSample 解释，交错原样保留）
void appendAsFloat(const uint8_t *data, size_t bytes, int32_t bits, std::vector<float> &out) {
    switch (bits) {
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
        case SAMPLE_U8:
        default: {
            for (size_t i = 0; i < bytes; ++i) {
                out.push_back((static_cast<float>(data[i]) - 128.0f) / 128.0f);
            }
            break;
        }
    }
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
            close(fd);  // AVSource 创建成功后不再需要持有 fd
        }
    }

    OH_AVDemuxer *demuxer = OH_AVDemuxer_CreateWithSource(source);
    if (demuxer == nullptr) {
        OH_AVSource_Destroy(source);
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
        OH_AVSource_Destroy(source);
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
        OH_AVSource_Destroy(source);
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
                chunk.reserve(attr.size * 2u);
                appendAsFloat(data, static_cast<size_t>(attr.size), c->bitsPerSample, chunk);
                c->push(std::move(chunk));
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
        OH_AVSource_Destroy(source);
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
        OH_AVSource_Destroy(source);
        r.code = kErrDemuxer;
        r.message = "选择音频轨道失败";
        return r;
    }
    OH_AVFormat *inFmt = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(audioTrack));
    if (inFmt == nullptr || OH_AudioCodec_Configure(decoder, inFmt) != AV_ERR_OK) {
        if (inFmt != nullptr) OH_AVFormat_Destroy(inFmt);
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        OH_AVSource_Destroy(source);
        r.code = kErrDecoder;
        r.message = "配置解码器失败";
        return r;
    }
    OH_AVFormat_Destroy(inFmt);
    if (OH_AudioCodec_Prepare(decoder) != AV_ERR_OK) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        OH_AVSource_Destroy(source);
        r.code = kErrDecoder;
        r.message = "解码器 Prepare 失败";
        return r;
    }

    // 解码器实际输出格式：采样率/声道/位深都跟着音源走，否则会变调或按错位深解释
    uint32_t sampleRate = 44100;
    uint32_t channels = 2;
    int32_t bits = SAMPLE_S16LE;
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
        }
        if (OH_AVFormat_GetIntValue(outDesc, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &fmt)) {
            bits = fmt;
        }
        OH_AVFormat_Destroy(outDesc);
    }
    ctx.channels = static_cast<int32_t>(channels);
    ctx.bitsPerSample = bits;

    // AudioSuite 采样率是离散枚举，非标准值就近映射；WAV 头仍写真实采样率
    OH_Audio_SampleRate suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_44100;
    switch (sampleRate) {
        case 48000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_48000; break;
        case 32000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_32000; break;
        case 96000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_96000; break;
        case 8000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_8000; break;
        case 16000: suiteRate = OH_Audio_SampleRate::SAMPLE_RATE_16000; break;
        default: break;  // 44100 及其它：用 44100
    }

    if (OH_AudioCodec_Start(decoder) != AV_ERR_OK) {
        OH_AudioCodec_Destroy(decoder);
        OH_AVDemuxer_Destroy(demuxer);
        OH_AVSource_Destroy(source);
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
        OH_AVSource_Destroy(source);
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
                writeWavHeader(os, estimate, sampleRate, static_cast<uint16_t>(channels));
                os.flush();  // 立刻落盘，让播放器能尽早读到头部
                ok = true;
            }
        }
    }

    if (ok) {
        constexpr int32_t kChunkFloats = 4096;
        std::vector<float> buf(kChunkFloats);
        bool finished = false;
        for (int guard = 0; guard < 2000000 && !finished; ++guard) {
            if (ctx.stopRequested()) break;
            int32_t got = 0;
            OH_AudioSuite_Result res = OH_AudioSuiteEngine_RenderFrame(
                pipeline, buf.data(), static_cast<int32_t>(kChunkFloats * sizeof(float)), &got, &finished);
            if (res != AUDIOSUITE_SUCCESS || got < 0) break;
            if (got == 0) continue;
            const int32_t n = got / static_cast<int32_t>(sizeof(float));
            for (int32_t i = 0; i < n; ++i) outMeter.feed(buf[static_cast<size_t>(i)]);
            outSamples += n;
            for (int32_t i = 0; i < n; ++i) {
                float f = std::max(-1.0f, std::min(1.0f, buf[static_cast<size_t>(i)]));
                int16_t s = static_cast<int16_t>(std::lround(f * 32767.0f));
                os.write(reinterpret_cast<const char *>(&s), 2);
                dataBytes += 2;
            }
            // 边写边落盘：播放器要能读到已产出的部分才能边播边处理
            if (dataBytes - flushed >= 64u * 1024u) {
                os.flush();
                flushed = dataBytes;
            }
        }
        os.flush();
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
    OH_AVSource_Destroy(source);

    if (os.is_open()) {
        if (ok && !cancelled && !ctxFailed && dataBytes > 0) {
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
    if (ctxFailed) {
        r.code = kErrDecoder;
        const bool eos = ctx.eosSeen.load();
        r.message = "音频解码失败或超时（块=" + std::to_string(r.inChunks) +
                    " 样本=" + std::to_string(r.inSamples) +
                    " 超时=" + std::to_string(r.timeouts) +
                    " 解码错误码=" + std::to_string(r.decoderError) +
                    (eos ? " 已收到EOS" : " 未收到EOS") + "）";
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
                " inputBytes=" + std::to_string(inputBytes);
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
