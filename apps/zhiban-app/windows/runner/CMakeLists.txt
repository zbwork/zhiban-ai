cmake_minimum_required(VERSION 3.20)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "desktop_network_bridge.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Older Flutter SDKs use Skia by default and have no Impeller switch API.
# Recheck the actual headers when configuring, including after SDK changes.
include(CheckCXXSourceCompiles)
include(CMakePushCheckState)
cmake_push_check_state(RESET)
set(CMAKE_REQUIRED_INCLUDES
  "${FLUTTER_MANAGED_DIR}/ephemeral/cpp_client_wrapper/include"
  "${FLUTTER_MANAGED_DIR}/ephemeral")
unset(ZHIBAN_FLUTTER_HAS_IMPELLER_SWITCH CACHE)
check_cxx_source_compiles("
  #include <flutter/dart_project.h>
  void configure(flutter::DartProject& project) {
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  }
  int main() { return 0; }
" ZHIBAN_FLUTTER_HAS_IMPELLER_SWITCH)
cmake_pop_check_state()
if(ZHIBAN_FLUTTER_HAS_IMPELLER_SWITCH)
  target_compile_definitions(${BINARY_NAME} PRIVATE ZHIBAN_FLUTTER_HAS_IMPELLER_SWITCH)
endif()

# Force MSVC to read source files as UTF-8 so non-ASCII content (e.g. the window
# title L"知办AI" in main.cpp) parses correctly and never trips C4819, which the
# standard /WX setting would escalate to a build error on GBK (code page 936).
if(MSVC)
  target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Local Agent is part of every Windows package, not a global runtime prerequisite.
# TARGET build events must be registered in the directory that creates the target.
find_package(Python3 3.12 COMPONENTS Interpreter REQUIRED)
find_program(LOCAL_BRIDGE_GO_EXECUTABLE NAMES go REQUIRED)
add_custom_target(zhiban-local-bridge-bundle
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/bundle_local_bridge_windows.py"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/zhiban-local-bridge.exe"
    --go "${LOCAL_BRIDGE_GO_EXECUTABLE}" --version "${FLUTTER_VERSION}"
  COMMENT "Build and probe local coding Bridge (Windows x64)" VERBATIM)
add_dependencies(${BINARY_NAME} zhiban-local-bridge-bundle)
add_subdirectory("../../../../services/dsh-runtime/native/windows" "${CMAKE_BINARY_DIR}/local-agent-native")
add_dependencies(${BINARY_NAME} zhiban-local-sandbox zhiban-windows-path)
add_custom_target(zhiban-local-agent-bundle ALL
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/bundle_local_agent_windows.py"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/local-agent" --sandbox "$<TARGET_FILE:zhiban-local-sandbox>" --path-addon "$<TARGET_FILE:zhiban-windows-path>"
  DEPENDS zhiban-local-sandbox zhiban-windows-path
  COMMENT "Bundle and probe Local Agent (Windows x64)" VERBATIM)
add_dependencies(${BINARY_NAME} zhiban-local-agent-bundle)

# ============================================================================
# F16 RTC · 可选 DingRTC Windows native bridge（easyo/rtc/methods + events）。
# 仅当提供本地 DingRTC Windows SDK 路径时编译；否则 runner 完全不变，
# 运行期 easyo/rtc/* 为 MissingPlugin（未完成态、非目标）。**不提交 SDK 二进制到仓库。**
# 设置方式（二选一）：
#   - CMake cache 变量：-DDINGRTC_WINDOWS_SDK_DIR=<解压后的 DingRTC_Windows_SDK_3_9_0 目录>
#   - 环境变量：    DINGRTC_WINDOWS_SDK_DIR=<同上>
# 该目录需包含 api/engine_interface.h 与 lib/x64/DingRTC.lib。
# ============================================================================
set(DINGRTC_WINDOWS_SDK_DIR "" CACHE PATH
  "Path to extracted DingRTC Windows SDK (contains api/ and lib/x64). Empty = auto-detect project-local third_party/, else RTC bridge disabled.")
if(NOT DINGRTC_WINDOWS_SDK_DIR AND DEFINED ENV{DINGRTC_WINDOWS_SDK_DIR})
  set(DINGRTC_WINDOWS_SDK_DIR "$ENV{DINGRTC_WINDOWS_SDK_DIR}")
endif()
# 项目内默认路径（免配环境变量）：把 SDK 解压到 windows/runner/third_party/DingRTC_Windows_SDK_3_9_0。
# 该目录由 apps/zhiban-app/.gitignore 排除，二进制不入仓（见 F16 文档「不提交 SDK 二进制」）。
if(NOT DINGRTC_WINDOWS_SDK_DIR)
  set(_dingrtc_local "${CMAKE_CURRENT_SOURCE_DIR}/third_party/DingRTC_Windows_SDK_3_9_0")
  if(EXISTS "${_dingrtc_local}/api/engine_interface.h")
    set(DINGRTC_WINDOWS_SDK_DIR "${_dingrtc_local}")
  endif()
endif()

if(DINGRTC_WINDOWS_SDK_DIR
    AND EXISTS "${DINGRTC_WINDOWS_SDK_DIR}/api/engine_interface.h"
    AND EXISTS "${DINGRTC_WINDOWS_SDK_DIR}/lib/x64/DingRTC.lib")
  message(STATUS "F16 RTC: DingRTC Windows SDK found at ${DINGRTC_WINDOWS_SDK_DIR} -> RTC bridge ENABLED.")

  # 桥单独成库（不套用 /WX 严格告警，隔离第三方头文件与桥实现）。
  add_library(dingrtc_bridge STATIC "dingrtc_bridge.cpp")
  target_compile_features(dingrtc_bridge PRIVATE cxx_std_17)
  if(MSVC)
    target_compile_options(dingrtc_bridge PRIVATE "/utf-8")
  endif()
  target_compile_definitions(dingrtc_bridge PRIVATE HAVE_DINGRTC NOMINMAX UNICODE _UNICODE)
  target_include_directories(dingrtc_bridge PRIVATE
    "${DINGRTC_WINDOWS_SDK_DIR}/api"
    "${CMAKE_CURRENT_SOURCE_DIR}")
  # flutter_wrapper_plugin 提供 PluginRegistrar(Windows)/PluginRegistrarManager/
  # MethodChannel/EventChannel 的实现符号（plugin 用的那套 C++ client wrapper）；
  # flutter_wrapper_app 只含 runner app 那套（FlutterEngine/ViewController），缺它会 LNK2019。
  target_link_libraries(dingrtc_bridge PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
  target_link_libraries(dingrtc_bridge PRIVATE "${DINGRTC_WINDOWS_SDK_DIR}/lib/x64/DingRTC.lib")

  target_link_libraries(${BINARY_NAME} PRIVATE dingrtc_bridge)
  target_compile_definitions(${BINARY_NAME} PRIVATE HAVE_DINGRTC)

  # 运行时 DLL（DingRTC.dll / ffmpeg.dll 等）复制到 exe 目录。
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${DINGRTC_WINDOWS_SDK_DIR}/lib/x64"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>"
    COMMENT "F16 RTC: copying DingRTC Windows runtime DLLs (lib/x64) next to ${BINARY_NAME}")
else()
  message(STATUS "F16 RTC: DingRTC Windows SDK not found (set DINGRTC_WINDOWS_SDK_DIR). "
                 "RTC bridge DISABLED; easyo/rtc/* will be MissingPlugin at runtime (未完成态).")
endif()

# ============================================================================
# F18 桌面更新 · 可选 WinSparkle Windows 自动更新 bridge（cn.qkfintech.zhiban/update）。
# 仅当提供 WinSparkle SDK 路径时编译；否则 runner 完全不变，运行期 update 通道为
# MissingPlugin（未完成态、非目标）。**不提交 WinSparkle 二进制到仓库。**
# 设置方式（二选一）：
#   - CMake cache 变量：-DWINSPARKLE_DIR=<解压后的 WinSparkle 目录>
#   - 环境变量：        WINSPARKLE_DIR=<同上>
# 该目录需包含 include/winsparkle.h 与 x64/Release/WinSparkle.lib + WinSparkle.dll。
# 同时兼容旧的 x64/ 平铺布局。
# 也可解压到 windows/runner/third_party/WinSparkle 免配置（由 .gitignore 排除）。
# ============================================================================
set(WINSPARKLE_DIR "" CACHE PATH
  "Path to extracted WinSparkle SDK (contains include/ and x64/). Empty = auto-detect project-local third_party/WinSparkle, else update bridge disabled.")
if(NOT WINSPARKLE_DIR AND DEFINED ENV{WINSPARKLE_DIR})
  set(WINSPARKLE_DIR "$ENV{WINSPARKLE_DIR}")
endif()
if(NOT WINSPARKLE_DIR)
  set(_winsparkle_local "${CMAKE_CURRENT_SOURCE_DIR}/third_party/WinSparkle")
  if(EXISTS "${_winsparkle_local}/include/winsparkle.h")
    set(WINSPARKLE_DIR "${_winsparkle_local}")
  endif()
endif()

set(_winsparkle_binary_dir "")
foreach(_winsparkle_candidate "${WINSPARKLE_DIR}/x64/Release" "${WINSPARKLE_DIR}/x64")
  if(EXISTS "${_winsparkle_candidate}/WinSparkle.lib"
      AND EXISTS "${_winsparkle_candidate}/WinSparkle.dll")
    set(_winsparkle_binary_dir "${_winsparkle_candidate}")
    break()
  endif()
endforeach()

if(WINSPARKLE_DIR
    AND EXISTS "${WINSPARKLE_DIR}/include/winsparkle.h"
    AND _winsparkle_binary_dir)
  message(STATUS "F18 Update: WinSparkle found at ${WINSPARKLE_DIR} -> Windows auto-update ENABLED.")

  # 桥单独成库（与 dingrtc_bridge 同理：隔离第三方头文件与 /WX 严格告警）。
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/ed25519-public-key.txt" _windows_update_public_key)
  string(STRIP "${_windows_update_public_key}" _windows_update_public_key)
  add_library(winsparkle_bridge STATIC "winsparkle_bridge.cpp")
  target_compile_definitions(winsparkle_bridge PRIVATE
    "ZHIBAN_WINDOWS_UPDATE_PUBLIC_KEY=\"${_windows_update_public_key}\"")
  target_compile_features(winsparkle_bridge PRIVATE cxx_std_17)
  if(MSVC)
    target_compile_options(winsparkle_bridge PRIVATE "/utf-8")
  endif()
  target_compile_definitions(winsparkle_bridge PRIVATE HAVE_WINSPARKLE NOMINMAX UNICODE _UNICODE)
  target_compile_definitions(winsparkle_bridge PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
  target_include_directories(winsparkle_bridge PRIVATE
    "${WINSPARKLE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}")
  # flutter_wrapper_plugin 提供 PluginRegistrar(Windows)/PluginRegistrarManager/MethodChannel
  # 的 C++ client wrapper 实现符号；缺它会 LNK2019（同 dingrtc_bridge）。
  target_link_libraries(winsparkle_bridge PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
  target_link_libraries(winsparkle_bridge PRIVATE "${_winsparkle_binary_dir}/WinSparkle.lib")

  target_link_libraries(${BINARY_NAME} PRIVATE winsparkle_bridge)
  target_compile_definitions(${BINARY_NAME} PRIVATE HAVE_WINSPARKLE)

  # 运行时 WinSparkle.dll 复制到 exe 目录。
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${_winsparkle_binary_dir}/WinSparkle.dll"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>"
    COMMENT "F18 Update: copying WinSparkle.dll next to ${BINARY_NAME}")
else()
  message(STATUS "F18 Update: WinSparkle not found (set WINSPARKLE_DIR). "
                 "Windows auto-update DISABLED; cn.qkfintech.zhiban/update will be MissingPlugin at runtime (未完成态).")
endif()
