/**
 * NAPI 入口：把 eq_pipeline 暴露给 ArkTS。
 *
 * API：
 *   processAudio(inputPath: string, outputPath: string, gains: number[], taskId: number): Promise<ProcessResult>
 *   cancel(taskId: number): void
 *
 * 处理放在 libuv 线程池（napi_async_work），不阻塞 UI 线程。
 * 每个 taskId 对应一个可取消标志；切歌时 ArkTS 调 cancel 即可让 Native 循环尽快停下。
 */
#include <napi/native_api.h>

#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "eq_pipeline.h"

namespace {

// taskId -> 取消标志。用 shared_ptr 避免 async 完成时与 cancel 并发访问悬空。
std::mutex gTasksMutex;
std::map<int32_t, std::shared_ptr<std::atomic<bool>>> gTasks;

std::shared_ptr<std::atomic<bool>> acquireTask(int32_t id, bool create) {
    std::lock_guard<std::mutex> lock(gTasksMutex);
    auto it = gTasks.find(id);
    if (it != gTasks.end()) return it->second;
    if (!create) return nullptr;
    auto flag = std::make_shared<std::atomic<bool>>(false);
    gTasks[id] = flag;
    return flag;
}
/**
 * 注销一次任务。
 *
 * taskId 由 ArkTS 侧单调递增分配（AudioEffectProcessor.nextTaskId++），要 2^31 次起播才会在
 * int32 上回绕，当前调用路径不可达，所以这里按 id 无条件 erase 是安全的。若将来改成复用 id，
 * 必须按 flag 指针比较后再 erase —— 否则先完成的任务会删掉后来者的取消标志，使 cancel 变成空操作。
 */
void releaseTask(int32_t id) {
    std::lock_guard<std::mutex> lock(gTasksMutex);
    gTasks.erase(id);
}

struct WorkData {
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    std::string inPath;
    std::string outPath;
    int32_t gains[10] = {0};
    int32_t taskId = 0;
    /** 输入形态：true = 网络地址（processAudioUrl）；false = 本地路径 / fd（由 fd 是否 >=0 再分） */
    bool isUrl = false;
    /** >=0 表示输入是调用方已经打开的 fd（进程内 fd 表共享，直接拿来用） */
    int32_t fd = -1;
    std::shared_ptr<std::atomic<bool>> cancelFlag;
    lxeq::EqResult result;
};

std::string readStringArg(napi_env env, napi_value v) {
    if (v == nullptr) return "";
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return "";
    // 缓冲区必须按 len + 1 分配：N-API 会往末尾补 '\0'，而 std::string(len, ...)
    // 的 data() 只有 len 个可写字节，写第 len + 1 个是越界（实践中靠 c_str()
    // 的终止符兜住了，但那是实现细节，不该依赖）。
    std::string s(len + 1, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    s.resize(len);
    return s;
}

/** 入口形态：0 = 本地路径，1 = 网络地址，2 = 已打开的 fd */
enum InputKind { kInPath = 0, kInUrl = 1, kInFd = 2 };

napi_value startProcess(napi_env env, napi_callback_info info, int kind) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_error(env, nullptr, "process input, output, gains, taskId are required");
        return nullptr;
    }

    // fd 先读出来校验：别在创建了 Promise 之后再抛（那样 Promise 永远悬着）
    int32_t fd = -1;
    if (kind == kInFd) {
        napi_get_value_int32(env, args[0], &fd);
        if (fd < 0) {
            napi_throw_error(env, nullptr, "invalid file descriptor");
            return nullptr;
        }
    }

    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) return nullptr;

    auto *data = new WorkData();
    data->deferred = deferred;
    data->isUrl = (kind == kInUrl);
    data->fd = fd;
    if (kind != kInFd) {
        data->inPath = readStringArg(env, args[0]);
    }
    data->outPath = readStringArg(env, args[1]);

    bool isArray = false;
    napi_is_array(env, args[2], &isArray);
    uint32_t arrLen = 0;
    if (isArray) napi_get_array_length(env, args[2], &arrLen);
    for (uint32_t i = 0; i < 10; ++i) {
        if (i < arrLen) {
            napi_value elem = nullptr;
            napi_get_element(env, args[2], i, &elem);
            napi_get_value_int32(env, elem, &data->gains[i]);
        }
    }
    napi_get_value_int32(env, args[3], &data->taskId);
    data->cancelFlag = acquireTask(data->taskId, true);

    napi_value workName = nullptr;
    napi_create_string_utf8(env, "lx_eq_process", NAPI_AUTO_LENGTH, &workName);
    if (napi_create_async_work(env, nullptr, workName,
        [](napi_env e, void *ud) {
            auto *d = static_cast<WorkData *>(ud);
            /**
             * 取消标志把 atomic<bool> 的地址当 const volatile bool* 读（见 eq_pipeline.h 的 cancel 形参）。
             *
             * 形式上这是对 atomic 对象的非原子访问（C++ 内存模型属 data race / UB），但本机 SDK 的
             * libc++ 里 atomic<bool> 就是对齐的 1 字节 _Atomic(bool)：arm64 对齐单字节 load 不会撕裂，
             * volatile 又强制每次重读内存，实际效果等价于 relaxed load；取消语义只需要「尽快可见」。
             * 彻底消除需要把整条函数签名改成 std::atomic<bool>*（约 12 行 / 3 个文件），收益为零，暂不改。
             */
            const volatile bool *flag = nullptr;
            if (d->cancelFlag != nullptr) {
                flag = reinterpret_cast<const volatile bool *>(d->cancelFlag.get());
            }
            if (d->fd >= 0) {
                d->result = lxeq::processAudioFd(d->fd, d->outPath, d->gains, flag);
            } else if (d->isUrl) {
                d->result = lxeq::processAudioUrl(d->inPath, d->outPath, d->gains, flag);
            } else {
                d->result = lxeq::processAudio(d->inPath, d->outPath, d->gains, flag);
            }
        },
        [](napi_env e, napi_status status, void *ud) {
            auto *d = static_cast<WorkData *>(ud);
            napi_value result = nullptr;
            napi_create_object(e, &result);
            napi_value okV, codeV, msgV, bytesV, deltaV;
            napi_get_boolean(e, d->result.ok, &okV);
            napi_create_int32(e, d->result.code, &codeV);
            napi_create_string_utf8(e, d->result.message.c_str(), NAPI_AUTO_LENGTH, &msgV);
            napi_create_int64(e, d->result.outBytes, &bytesV);
            napi_create_double(e, d->result.delta, &deltaV);
            napi_value durV, srV, chV, framesV;
            napi_create_int64(e, d->result.durationUs, &durV);
            napi_create_int32(e, d->result.sampleRate, &srV);
            napi_create_int32(e, d->result.channels, &chV);
            napi_create_int64(e, d->result.outFrames, &framesV);
            napi_set_named_property(e, result, "ok", okV);
            napi_set_named_property(e, result, "code", codeV);
            napi_set_named_property(e, result, "message", msgV);
            napi_set_named_property(e, result, "outBytes", bytesV);
            napi_set_named_property(e, result, "delta", deltaV);
            napi_set_named_property(e, result, "durationUs", durV);
            napi_set_named_property(e, result, "sampleRate", srV);
            napi_set_named_property(e, result, "channels", chV);
            napi_set_named_property(e, result, "outFrames", framesV);
            if (status == napi_ok && d->result.ok) {
                napi_resolve_deferred(e, d->deferred, result);
            } else {
                // reject 原因必须是**字符串**（不能把 promise 对象或空串当原因，否则 ArkTS
                // 那边拿到的是个没法读的异常）；message 为空时按状态给一个兜底描述。
                std::string reason = d->result.message;
                if (reason.empty()) {
                    reason = (status == napi_ok)
                                 ? std::string("音效处理失败（code=") +
                                       std::to_string(d->result.code) + "）"
                                 : std::string("音效任务未正常完成");
                }
                napi_value err = nullptr;
                napi_create_string_utf8(e, reason.c_str(), NAPI_AUTO_LENGTH, &err);
                napi_reject_deferred(e, d->deferred, err);
            }
            releaseTask(d->taskId);
            napi_delete_async_work(e, d->work);
            delete d;
        },
        data, &data->work) != napi_ok) {
        releaseTask(data->taskId);
        delete data;
        // 创建异步任务都失败了：先 reject 再返回 promise，别让这个 Promise 永远悬着
        napi_value err = nullptr;
        napi_create_string_utf8(env, "创建音效异步任务失败", NAPI_AUTO_LENGTH, &err);
        napi_reject_deferred(env, deferred, err);
        return promise;
    }
    /**
     * 入队失败必须立刻 reject：napi_async_work 根本没排上，complete 回调永远不会被调用，
     * 不在这里 reject 的话调用方会一直等下去（Promise 永久悬挂）。
     *
     * 已知平台缺陷：OpenHarmony 6.0/6.1 的 napi_queue_async_work 实现丢掉了 Queue() 的返回值、
     * 恒返回 napi_ok（社区 issue 已确认），所以真入队失败时这个分支抓不到、Promise 仍会悬挂。
     * 不为此加超时看门狗：processAudio* 本来就要等整首处理完（几分钟也可能是正常的），
     * ArkTS 侧无法区分「没入队」与「正在处理」；上层预缓冲 / settleActive 都已有超时兜底。
     * 这段检查留着是为了覆盖 create 失败、参数/多上下文失败，以及将来运行时修好这个缺陷的情形。
     */
    if (napi_queue_async_work(env, data->work) != napi_ok) {
        releaseTask(data->taskId);
        napi_delete_async_work(env, data->work);
        delete data;
        napi_value err = nullptr;
        napi_create_string_utf8(env, "音效异步任务入队失败", NAPI_AUTO_LENGTH, &err);
        napi_reject_deferred(env, deferred, err);
        return promise;
    }
    return promise;
}

napi_value processAudioEntry(napi_env env, napi_callback_info info) {
    return startProcess(env, info, kInPath);
}

napi_value processAudioUrlEntry(napi_env env, napi_callback_info info) {
    return startProcess(env, info, kInUrl);
}

napi_value processAudioFdEntry(napi_env env, napi_callback_info info) {
    return startProcess(env, info, kInFd);
}

napi_value cancelTask(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg = nullptr;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    if (argc < 1) return nullptr;
    int32_t id = 0;
    napi_get_value_int32(env, arg, &id);
    auto flag = acquireTask(id, false);
    if (flag) flag->store(true);
    return nullptr;
}

napi_value version(napi_env env, napi_callback_info info) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, "1.0.0", NAPI_AUTO_LENGTH, &v);
    return v;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"processAudio", nullptr, processAudioEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"processAudioUrl", nullptr, processAudioUrlEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"processAudioFd", nullptr, processAudioFdEntry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, cancelTask, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, version, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

extern "C" __attribute__((constructor)) void RegisterAudioEffectModule() {
    /**
     * 栈上 napi_module 是安全的：arkui_napi 的 napi_module_register 会同步把字段逐项拷进
     * NativeModule（name 还额外 strdup），不保存 napi_module*；register_func 存的是本 TU 的
     * 静态函数 Init，生命周期等于 so。官方模板用文件作用域 static 只是风格，两者等价。
     * 唯一注意：NativeModule.fileName 是裸指针拷贝，本模块传 nullptr 所以无风险；
     * 将来别把栈上缓冲区赋给 nm_filename。
     */
    napi_module module{};
    module.nm_version = 1;
    module.nm_flags = 0;
    module.nm_filename = nullptr;
    module.nm_register_func = Init;
    module.nm_modname = const_cast<char *>("audioeffect");
    module.nm_priv = nullptr;
    // reserved 是 void*[4] 数组，module{} 已零初始化，不能整体赋值
    napi_module_register(&module);
}
