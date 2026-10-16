// Node-API adapter for AppContainer: resolve the object in the kernel without
// querying the mount manager, which is unavailable to a networkless container.
#include <node_api.h>
#include <windows.h>
#include <string>
#include <vector>

static napi_value fail(napi_env env, DWORD error) {
  const char* code = error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? "ENOENT"
    : error == ERROR_ACCESS_DENIED ? "EACCES" : "EIO";
  napi_throw_error(env, code, "Windows canonical path resolution failed");
  return nullptr;
}

static napi_value realpath(napi_env env, napi_callback_info info) {
  size_t argc = 1, length = 0; napi_value arg;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1 ||
      napi_get_value_string_utf16(env, arg, nullptr, 0, &length) != napi_ok) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_TYPE", "path must be a string"); return nullptr;
  }
  std::vector<char16_t> input(length + 1);
  if (napi_get_value_string_utf16(env, arg, input.data(), input.size(), &length) != napi_ok) return nullptr;
  for (size_t i = 0; i < length; ++i) if (!input[i]) {
    napi_throw_type_error(env, "ERR_INVALID_ARG_VALUE", "path must not contain null bytes"); return nullptr;
  }
  HANDLE file = CreateFileW(reinterpret_cast<wchar_t*>(input.data()), 0,
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (file == INVALID_HANDLE_VALUE) return fail(env, GetLastError());
  DWORD size = GetFinalPathNameByHandleW(file, nullptr, 0, VOLUME_NAME_NT);
  if (!size) { DWORD error = GetLastError(); CloseHandle(file); return fail(env, error); }
  std::vector<wchar_t> buffer(size + 1);
  DWORD count = GetFinalPathNameByHandleW(file, buffer.data(), static_cast<DWORD>(buffer.size()), VOLUME_NAME_NT);
  DWORD error = GetLastError(); CloseHandle(file);
  if (!count || count >= buffer.size()) return fail(env, error);
  // This map is supplied by the trusted supervisor before entering AppContainer.
  // It only changes spelling after resolving the real target; it grants no access.
  DWORD mapSize = GetEnvironmentVariableW(L"LOCAL_AGENT_DOS_DEVICES", nullptr, 0);
  if (!mapSize) return fail(env, ERROR_INVALID_DRIVE);
  std::vector<wchar_t> mapBuffer(mapSize);
  if (!GetEnvironmentVariableW(L"LOCAL_AGENT_DOS_DEVICES", mapBuffer.data(), mapSize)) return fail(env, ERROR_INVALID_DRIVE);
  const std::wstring target(buffer.data(), count), mappings(mapBuffer.data());
  for (size_t start = 0; start < mappings.size();) {
    size_t end = mappings.find(L'\n', start); if (end == std::wstring::npos) end = mappings.size();
    const auto entry = mappings.substr(start, end - start);
    if (entry.size() > 3 && entry[1] == L':' && entry[2] == L'=') {
      const auto device = entry.substr(3);
      if (target.size() >= device.size() && _wcsnicmp(target.c_str(), device.c_str(), device.size()) == 0 &&
          (target.size() == device.size() || target[device.size()] == L'\\')) {
        auto path = entry.substr(0, 2) + target.substr(device.size());
        if (path.size() == 2) path += L'\\';
        napi_value result;
        if (napi_create_string_utf16(env, reinterpret_cast<const char16_t*>(path.data()), path.size(), &result) != napi_ok) return nullptr;
        return result;
      }
    }
    start = end + 1;
  }
  return fail(env, ERROR_INVALID_DRIVE);
}

NAPI_MODULE_INIT() {
  napi_value fn;
  if (napi_create_function(env, "realpath", NAPI_AUTO_LENGTH, realpath, nullptr, &fn) != napi_ok ||
      napi_set_named_property(env, exports, "realpath", fn) != napi_ok) return nullptr;
  return exports;
}
