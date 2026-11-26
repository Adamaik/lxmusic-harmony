# 音效控制台的 Native 实现：解码 -> AudioSuite 10 段 EQ -> 重封装 WAV。
# 只在本机 SDK（API 26 / 鸿蒙 7）上验证过；库名取自该 SDK 的 sysroot。
cmake_minimum_required(VERSION 3.16)
project(audioeffect)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(audioeffect SHARED
  napi_init.cpp
  eq_pipeline.cpp
)

target_include_directories(audioeffect PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${OHOS_SDK_NATIVE}/sysroot/usr/include
)

# 注意：OHOS_ARCH 在 hvigor 里是 "arm64-v8a"，但 sysroot 的库目录名是
# "aarch64-linux-ohos"。写死后者，否则链接器找不到 stub 库。
target_link_directories(audioeffect PUBLIC
  ${OHOS_SDK_NATIVE}/sysroot/usr/lib/aarch64-linux-ohos
)

target_link_libraries(audioeffect PUBLIC
  ace_napi.z
  ohaudiosuite
  native_media_avsource
  native_media_adec
  native_media_acodec
  native_media_avdemuxer
  native_media_codecbase
  native_media_core
)
