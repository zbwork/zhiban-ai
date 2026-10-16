cmake_minimum_required(VERSION 3.14)
project(EasyOUpdateVerification LANGUAGES CXX RC)

get_filename_component(APP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(EPHEMERAL "${APP_ROOT}/windows/flutter/ephemeral")
set(WRAPPER "${EPHEMERAL}/cpp_client_wrapper")
foreach(required TEST_PUBLIC_KEY WINSPARKLE_DIR)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "${required} must be explicitly configured")
  endif()
endforeach()
if(NOT EXISTS "${EPHEMERAL}/flutter_windows.dll.lib")
  message(FATAL_ERROR "Build the Windows Flutter app first to prepare its native SDK")
endif()

# Compile the actual bridge. Only replace its pinned key in this generated,
# isolated fixture translation unit; the production source/key stays unchanged.
file(READ "${APP_ROOT}/windows/runner/winsparkle_bridge.cpp" BRIDGE)
string(REGEX MATCH "constexpr char kEdDsaPublicKey\\[\\] =[^;]+;" KEY_DECL "${BRIDGE}")
if(NOT KEY_DECL)
  message(FATAL_ERROR "Production public-key declaration changed; inspect fixture extraction")
endif()
string(REPLACE "${KEY_DECL}"
  "constexpr char kEdDsaPublicKey[] = \"${TEST_PUBLIC_KEY}\";" BRIDGE "${BRIDGE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/fixture_bridge.cpp" "${BRIDGE}")

add_library(fixture_flutter STATIC
  "${WRAPPER}/core_implementations.cc" "${WRAPPER}/standard_codec.cc"
  "${WRAPPER}/plugin_registrar.cc" "${WRAPPER}/flutter_engine.cc"
  "${WRAPPER}/flutter_view_controller.cc")
target_compile_features(fixture_flutter PUBLIC cxx_std_17)
target_compile_definitions(fixture_flutter PUBLIC NOMINMAX UNICODE _UNICODE)
target_include_directories(fixture_flutter PUBLIC "${WRAPPER}/include" "${EPHEMERAL}")
target_link_libraries(fixture_flutter PUBLIC "${EPHEMERAL}/flutter_windows.dll.lib")

foreach(build 100 101)
  add_executable(fixture${build} fixture.cpp fixture.rc)
  target_compile_features(fixture${build} PRIVATE cxx_std_17)
  target_compile_options(fixture${build} PRIVATE /utf-8 /W4)
  target_compile_definitions(fixture${build} PRIVATE HAVE_WINSPARKLE FLUTTER_VERSION_BUILD=${build})
  target_include_directories(fixture${build} PRIVATE "${APP_ROOT}/windows/runner"
    "${WINSPARKLE_DIR}/include" "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(fixture${build} PRIVATE fixture_flutter "${WINSPARKLE_DIR}/x64/WinSparkle.lib")
  set_target_properties(fixture${build} PROPERTIES OUTPUT_NAME EasyOUpdateFixture
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_BINARY_DIR}/${build}")
  add_custom_command(TARGET fixture${build} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${EPHEMERAL}/flutter_windows.dll"
      "${WINSPARKLE_DIR}/x64/WinSparkle.dll" "$<TARGET_FILE_DIR:fixture${build}>")
endforeach()
