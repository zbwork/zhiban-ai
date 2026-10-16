cmake_minimum_required(VERSION 3.20)
project(zhiban_local_sandbox LANGUAGES CXX)
add_executable(zhiban-local-sandbox sandbox.cpp)
target_compile_features(zhiban-local-sandbox PRIVATE cxx_std_17)
target_compile_definitions(zhiban-local-sandbox PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
target_link_libraries(zhiban-local-sandbox PRIVATE userenv advapi32 ole32 ws2_32)
if(MSVC)
  target_compile_options(zhiban-local-sandbox PRIVATE /W4 /EHsc)
  set_property(TARGET zhiban-local-sandbox PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Build against the bundled Node's public, stable Node-API (no user-installed SDK).
include(FetchContent)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
FetchContent_Declare(local_agent_node_headers
  URL https://nodejs.org/dist/v24.19.0/node-v24.19.0-headers.tar.gz
  URL_HASH SHA256=54f14a297d47ea0794fe272363703d9dc419c96ac68f20d890f98b63754a3e4c)
FetchContent_MakeAvailable(local_agent_node_headers)
set(NODE_IMPORT_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/node.lib")
file(DOWNLOAD https://nodejs.org/dist/v24.19.0/win-x64/node.lib "${NODE_IMPORT_LIBRARY}"
  EXPECTED_HASH SHA256=63ec831bbf164d1b23197d6fac1944dfb146534e332889ca0755d250e8dedff9 TLS_VERIFY ON)
add_library(zhiban-windows-path MODULE realpath.cpp)
target_include_directories(zhiban-windows-path PRIVATE "${local_agent_node_headers_SOURCE_DIR}/include/node")
target_link_libraries(zhiban-windows-path PRIVATE "${NODE_IMPORT_LIBRARY}")
target_compile_features(zhiban-windows-path PRIVATE cxx_std_17)
target_compile_definitions(zhiban-windows-path PRIVATE NAPI_VERSION=8 WIN32_LEAN_AND_MEAN NOMINMAX)
set_target_properties(zhiban-windows-path PROPERTIES PREFIX "" SUFFIX ".node"
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
