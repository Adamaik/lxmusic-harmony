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
                napi_value err = nullptr;
                napi_create_string_utf8(e, d->result.message.c_str(), NAPI_AUTO_LENGTH, &err);
                napi_reject_deferred(e, d->deferred, err);
            }
            releaseTask(d->taskId);
            napi_delete_async_work(e, d->work);
            delete d;
        },
        data, &data->work) != napi_ok) {
        releaseTask(data->taskId);
        napi_reject_deferred(env, deferred, promise);
        delete data;
        return nullptr;
    }
    napi_queue_async_work(env, data->work);
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
