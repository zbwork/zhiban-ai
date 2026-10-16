// AppContainer broker. No elevation, global firewall changes, or loopback exemptions.
// The child has a fresh SID, explicit file grants and a kill-on-close Job Object.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <userenv.h>
#include <aclapi.h>
#include <sddl.h>
#include <objbase.h>
#include <tlhelp32.h>
#include <securityappcontainer.h>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <stdexcept>
#include <iostream>

namespace fs = std::filesystem;
struct Handle {
  HANDLE value = nullptr;
  explicit Handle(HANDLE v = nullptr) : value(v) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};
static void check(bool ok) { if (!ok) throw std::runtime_error("local.windows_sandbox_failed"); }
static std::wstring quote(const std::wstring& s) {
  std::wstring out = L"\""; size_t slashes = 0;
  for (wchar_t c : s) {
    if (c == L'\\') { ++slashes; continue; }
    out.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\'); slashes = 0; out += c;
  }
  out.append(slashes * 2, L'\\'); return out + L"\"";
}
static HANDLE parentProcess() {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  check(snapshot.value != INVALID_HANDLE_VALUE);
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry); DWORD parent = 0;
  if (Process32FirstW(snapshot.value, &entry)) do {
    if (entry.th32ProcessID == GetCurrentProcessId()) { parent = entry.th32ParentProcessID; break; }
  } while (Process32NextW(snapshot.value, &entry));
  check(parent != 0);
  HANDLE handle = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, parent);
  check(handle != nullptr);
  FILETIME parentCreated{}, selfCreated{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(handle, &parentCreated, &exited, &kernel, &user) ||
      !GetProcessTimes(GetCurrentProcess(), &selfCreated, &exited, &kernel, &user) ||
      CompareFileTime(&parentCreated, &selfCreated) > 0) { CloseHandle(handle); check(false); }
  return handle;
}
struct Grant { std::wstring path; DWORD mask; ACCESS_MODE mode; };
struct AclLock {
  Handle mutex;
  AclLock() {
    HANDLE raw = nullptr; check(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)); Handle token(raw);
    DWORD size = 0; GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> info(size);
    check(GetTokenInformation(token.value, TokenUser, info.data(), size, &size));
    LPWSTR sid = nullptr;
    check(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(info.data())->User.Sid, &sid));
    const auto name = L"Global\\ZhiBan.Local.Acl." + std::wstring(sid); LocalFree(sid);
    mutex.value = CreateMutexW(nullptr, FALSE, name.c_str()); check(mutex.value != nullptr);
    const DWORD waited = WaitForSingleObject(mutex.value, 30000);
    check(waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED);
  }
  ~AclLock() { ReleaseMutex(mutex.value); }
};
struct Profile {
  std::wstring name; PSID sid = nullptr; PSID restrictionSid = nullptr;
  std::vector<std::wstring> paths;
  Profile() {
    GUID id; check(SUCCEEDED(CoCreateGuid(&id))); wchar_t text[40]; StringFromGUID2(id, text, 40);
    // A unique non-account SID for the ordinary restricted-token deny pass.
    DWORD words[4]; memcpy(words, &id, sizeof(words));
    std::wstring restrictionName = L"S-1-4";
    for (DWORD word : words) restrictionName += L"-" + std::to_wstring(word);
    check(ConvertStringSidToSidW(restrictionName.c_str(), &restrictionSid));
    name = L"ZhiBan.Local.";
    for (wchar_t c : std::wstring(text)) if (c != L'{' && c != L'}') name += c;
    check(SUCCEEDED(CreateAppContainerProfile(name.c_str(), name.c_str(), L"Temporary local task", nullptr, 0, &sid)));
  }
  void acl(const std::wstring& path, DWORD mask, ACCESS_MODE mode, bool record = true) {
    AclLock lock;
    PACL oldAcl = nullptr, next = nullptr; PSECURITY_DESCRIPTOR descriptor = nullptr;
    check(GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, &oldAcl, nullptr, &descriptor) == ERROR_SUCCESS);
    EXPLICIT_ACCESSW entry{}; entry.grfAccessPermissions = mask; entry.grfAccessMode = mode;
    entry.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
    entry.Trustee.TrusteeForm = TRUSTEE_IS_SID; entry.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN;
    entry.Trustee.ptstrName = static_cast<LPWSTR>(sid);
    EXPLICIT_ACCESSW entries[] = {entry, entry};
    entries[1].Trustee.ptstrName = static_cast<LPWSTR>(restrictionSid);
    DWORD error = SetEntriesInAclW(mode == GRANT_ACCESS ? 1 : 2, entries, oldAcl, &next);
    if (error == ERROR_SUCCESS) {
      error = SetNamedSecurityInfoW(const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, next, nullptr);
    }
    if (next) LocalFree(next); LocalFree(descriptor);
    // Machine-wide installations can already be readable to AppContainers while
    // denying ordinary users WRITE_DAC. Do not request elevation or widen those
    // ACLs. The child must succeed using existing rights; startup probes verify it.
    if (error == ERROR_ACCESS_DENIED && mode == GRANT_ACCESS &&
        mask == (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE)) return;
    check(error == ERROR_SUCCESS);
    if (record) paths.push_back(path);
  }
  ~Profile() {
    // Remove only our unique SID, never restore a stale copy of the user's ACL.
    for (auto it = paths.rbegin(); it != paths.rend(); ++it) {
      try { acl(*it, 0, REVOKE_ACCESS, false); } catch (...) { /* orphan SID has no future token */ }
    }
    if (restrictionSid) LocalFree(restrictionSid);
    if (sid) FreeSid(sid);
    if (!name.empty()) DeleteAppContainerProfile(name.c_str());
  }
};
// Each pipe instance is owned by this broker and accessible only by its AppContainer.
// It forwards bytes to ONE fixed loopback port; callers cannot choose an upstream.
static bool pipeConnect(HANDLE pipe) {
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr)); check(event.value != nullptr);
  OVERLAPPED pending{}; pending.hEvent = event.value;
  if (ConnectNamedPipe(pipe, &pending)) return true;
  const DWORD error = GetLastError(); if (error == ERROR_PIPE_CONNECTED) return true;
  DWORD count = 0; return error == ERROR_IO_PENDING && GetOverlappedResult(pipe, &pending, &count, TRUE);
}
static bool pipeTransfer(HANDLE pipe, void* buffer, DWORD length, DWORD* count, bool reading) {
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr)); if (!event.value) return false;
  OVERLAPPED pending{}; pending.hEvent = event.value;
  const BOOL done = reading ? ReadFile(pipe, buffer, length, count, &pending) : WriteFile(pipe, buffer, length, count, &pending);
  return done || (GetLastError() == ERROR_IO_PENDING && GetOverlappedResult(pipe, &pending, count, TRUE));
}
struct Relay {
  std::wstring name; std::wstring childName; PSECURITY_DESCRIPTOR descriptor = nullptr; int port;
  Relay(PSID sid, PSID restrictionSid, int target) : port(target) {
    LPWSTR sidText = nullptr; check(ConvertSidToStringSidW(sid, &sidText));
    GUID id; check(SUCCEEDED(CoCreateGuid(&id))); wchar_t text[40]; StringFromGUID2(id, text, 40);
    name = L"\\\\.\\pipe\\LOCAL\\ZhiBan-" + std::wstring(text);
    childName = name;
    // LOCAL is virtualized for the child. The desktop broker must create the
    // pipe in that container's namespace, not in its own literal LOCAL folder.
    ULONG pathSize = 0;
    GetAppContainerNamedObjectPath(nullptr, sid, 0, nullptr, &pathSize);
    check(pathSize > 0);
    std::vector<wchar_t> objectPath(pathSize);
    check(GetAppContainerNamedObjectPath(nullptr, sid, pathSize, objectPath.data(), &pathSize));
    DWORD sessionId = 0; check(ProcessIdToSessionId(GetCurrentProcessId(), &sessionId));
    name = L"\\\\.\\pipe\\Sessions\\" + std::to_wstring(sessionId) + L"\\" +
        std::wstring(objectPath.data()) + L"\\ZhiBan-" + std::wstring(text);
    std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;OW)(A;;GRGW;;;" + std::wstring(sidText) + L")S:(ML;;NW;;;LW)";
    LPWSTR restrictionText = nullptr; check(ConvertSidToStringSidW(restrictionSid, &restrictionText));
    const auto mandatory = sddl.find(L"S:(ML;");
    sddl.insert(mandatory, L"(A;;GRGW;;;" + std::wstring(restrictionText) + L")");
    LocalFree(restrictionText); LocalFree(sidText);
    check(ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr));
  }
  ~Relay() = default; // Descriptor lives until ExitProcess; relay threads may still accept.
  void start() {
    SECURITY_ATTRIBUTES sa{sizeof(sa), descriptor, FALSE};
    // Create the first pipe before launching the child; subsequent connections use
    // independent instances. Process exit closes all relay handles and sockets.
    HANDLE first = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 64, 65536, 65536, 0, &sa);
    check(first != INVALID_HANDLE_VALUE);
    const std::wstring pipeName = name; const int targetPort = port;
    // Keep descriptor alive until the process exits; main joins neither blocked I/O nor user work.
    PSECURITY_DESCRIPTOR pipeDescriptor = descriptor;
    std::thread([first, pipeName, targetPort, pipeDescriptor]() {
      HANDLE current = first;
      for (;;) {
        if (!pipeConnect(current)) { CloseHandle(current); return; }
        SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(static_cast<u_short>(targetPort));
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
        if (socket == INVALID_SOCKET || connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
          if (socket != INVALID_SOCKET) closesocket(socket); CloseHandle(current); return;
        }
        std::thread([current, socket]() {
          std::thread incoming([current, socket]() {
            char buffer[16384]; DWORD count;
            while (pipeTransfer(current, buffer, sizeof(buffer), &count, true) && count) {
              DWORD sent = 0;
              while (sent < count) { int n = send(socket, buffer + sent, static_cast<int>(count - sent), 0); if (n <= 0) break; sent += static_cast<DWORD>(n); }
              if (sent != count) break;
            }
            shutdown(socket, SD_BOTH);
          });
          char buffer[16384]; int count;
          while ((count = recv(socket, buffer, sizeof(buffer), 0)) > 0) {
            DWORD written = 0;
            if (!pipeTransfer(current, buffer, static_cast<DWORD>(count), &written, false) || written != static_cast<DWORD>(count)) break;
          }
          shutdown(socket, SD_BOTH); CancelIoEx(current, nullptr); incoming.join();
          closesocket(socket); DisconnectNamedPipe(current); CloseHandle(current);
        }).detach();
        SECURITY_ATTRIBUTES attrs{sizeof(attrs), pipeDescriptor, FALSE};
        current = CreateNamedPipeW(pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 64, 65536, 65536, 0, &attrs);
        if (current == INVALID_HANDLE_VALUE) return;
      }
    }).detach();
  }
};

int wmain(int argc, wchar_t** argv) {
  try {
    std::vector<Grant> grants; int port = 0, commandIndex = 0; bool network = false;
    DWORD maxProcesses = 64; SIZE_T memory = 2048ull * 1024 * 1024; LONGLONG cpu = 900ll * 10000000;
    for (int i = 1; i < argc; ++i) {
      std::wstring arg = argv[i];
      if (arg == L"--") { commandIndex = i + 1; break; }
      if (arg == L"--network") { network = true; continue; }
      check(i + 1 < argc); std::wstring value = argv[++i];
      if (arg == L"--broker-port") { port = std::stoi(value); check(port > 0 && port <= 65535); }
      else if (arg == L"--read" || arg == L"--write" || arg == L"--deny") {
        check(fs::path(value).is_absolute() && fs::exists(value));
        DWORD rights = arg == L"--read" ? (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE) : (FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_GENERIC_EXECUTE | DELETE);
        grants.push_back({fs::canonical(value).wstring(), rights, arg == L"--deny" ? DENY_ACCESS : GRANT_ACCESS});
      } else if (arg == L"--processes") { maxProcesses = std::stoul(value); check(maxProcesses > 0 && maxProcesses <= 64); }
      else if (arg == L"--memory-mb") { const auto n = std::stoul(value); check(n > 0 && n <= 2048); memory = static_cast<SIZE_T>(n) * 1024 * 1024; }
      else if (arg == L"--cpu-seconds") { const auto n = std::stoul(value); check(n > 0 && n <= 900); cpu = static_cast<LONGLONG>(n) * 10000000; }
      else check(false);
    }
    check(commandIndex > 0 && commandIndex < argc && port > 0);
    check(fs::path(argv[commandIndex]).is_absolute());
    Handle parent(parentProcess());
    Profile profile;
    for (const auto& grant : grants) {
      profile.acl(grant.path, grant.mask, grant.mode);
    }
    WSADATA wsa{}; check(WSAStartup(MAKEWORD(2, 2), &wsa) == 0);
    Relay relay(profile.sid, profile.restrictionSid, port); relay.start();
    check(SetEnvironmentVariableW(L"LOCAL_AGENT_BROKER_PIPE", relay.childName.c_str()));
    check(SetEnvironmentVariableW(L"LOCAL_AGENT_BROKER_PORT", std::to_wstring(port).c_str()));
    std::wstring devices;
    for (wchar_t drive = L'A'; drive <= L'Z'; ++drive) {
      const wchar_t name[] = {drive, L':', 0}; wchar_t target[32768];
      if (QueryDosDeviceW(name, target, 32768)) devices += std::wstring(name) + L"=" + target + L"\n";
    }
    check(SetEnvironmentVariableW(L"LOCAL_AGENT_DOS_DEVICES", devices.c_str()));
    Handle job(CreateJobObjectW(nullptr, nullptr)); check(job.value != nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_JOB_MEMORY | JOB_OBJECT_LIMIT_JOB_TIME;
    limits.BasicLimitInformation.ActiveProcessLimit = maxProcesses;
    limits.BasicLimitInformation.PerJobUserTimeLimit.QuadPart = cpu; limits.JobMemoryLimit = memory;
    check(SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)));
    // No breakaway and no inherited job handle: killing the broker kills descendants.
    SIZE_T bytes = 0; InitializeProcThreadAttributeList(nullptr, 2, 0, &bytes);
    std::vector<BYTE> storage(bytes); auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    check(InitializeProcThreadAttributeList(attrs, 2, 0, &bytes));
    PSID internet = nullptr, privateNetwork = nullptr;
    if (network) {
      check(ConvertStringSidToSidW(L"S-1-15-3-1", &internet));
      check(ConvertStringSidToSidW(L"S-1-15-3-3", &privateNetwork));
    }
    SID_AND_ATTRIBUTES capabilities[] = {{internet, SE_GROUP_ENABLED}, {privateNetwork, SE_GROUP_ENABLED}};
    SECURITY_CAPABILITIES security{profile.sid, network ? capabilities : nullptr, network ? 2u : 0u, 0};
    check(UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &security, sizeof(security), nullptr, nullptr));
    HANDLE inherited[3]{};
    for (int i = 0; i < 3; ++i) check(DuplicateHandle(GetCurrentProcess(), GetStdHandle(i == 0 ? STD_INPUT_HANDLE : i == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE), GetCurrentProcess(), &inherited[i], 0, TRUE, DUPLICATE_SAME_ACCESS));
    check(UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), nullptr, nullptr));
    STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = attrs;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = inherited[0]; startup.StartupInfo.hStdOutput = inherited[1]; startup.StartupInfo.hStdError = inherited[2];
    std::wstring command;
    for (int i = commandIndex; i < argc; ++i) { if (!command.empty()) command += L' '; command += quote(argv[i]); }
    PROCESS_INFORMATION process{};
    Handle currentToken, restricted;
    check(OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT, &currentToken.value));
    DWORD groupBytes = 0;
    GetTokenInformation(currentToken.value, TokenGroups, nullptr, 0, &groupBytes);
    std::vector<BYTE> groupBuffer(groupBytes);
    check(GetTokenInformation(currentToken.value, TokenGroups, groupBuffer.data(), groupBytes, &groupBytes));
    auto tokenGroups = reinterpret_cast<TOKEN_GROUPS*>(groupBuffer.data());
    DWORD userBytes = 0; GetTokenInformation(currentToken.value, TokenUser, nullptr, 0, &userBytes);
    std::vector<BYTE> userBuffer(userBytes);
    check(GetTokenInformation(currentToken.value, TokenUser, userBuffer.data(), userBytes, &userBytes));
    // Preserve the original principals for system initialization. AppContainer
    // still gates reads/network; this additional full (not WRITE_RESTRICTED)
    // access check makes our unique deny SID effective for reads as well.
    std::vector<SID_AND_ATTRIBUTES> restriction{{profile.restrictionSid, 0}, {reinterpret_cast<TOKEN_USER*>(userBuffer.data())->User.Sid, 0}};
    for (DWORD i = 0; i < tokenGroups->GroupCount; ++i) if (tokenGroups->Groups[i].Attributes & SE_GROUP_ENABLED) restriction.push_back({tokenGroups->Groups[i].Sid, 0});
    check(CreateRestrictedToken(currentToken.value, DISABLE_MAX_PRIVILEGE, 0, nullptr, 0, nullptr, static_cast<DWORD>(restriction.size()), restriction.data(), &restricted.value));
    DWORD daclBytes = 0;
    GetTokenInformation(restricted.value, TokenDefaultDacl, nullptr, 0, &daclBytes);
    std::vector<BYTE> daclBuffer(daclBytes);
    check(GetTokenInformation(restricted.value, TokenDefaultDacl, daclBuffer.data(), daclBytes, &daclBytes));
    EXPLICIT_ACCESSW defaultEntry{}; defaultEntry.grfAccessPermissions = GENERIC_ALL; defaultEntry.grfAccessMode = GRANT_ACCESS;
    defaultEntry.Trustee.TrusteeForm = TRUSTEE_IS_SID; defaultEntry.Trustee.ptstrName = static_cast<LPWSTR>(profile.restrictionSid);
    PACL defaultAcl = nullptr;
    check(SetEntriesInAclW(1, &defaultEntry, reinterpret_cast<TOKEN_DEFAULT_DACL*>(daclBuffer.data())->DefaultDacl, &defaultAcl) == ERROR_SUCCESS);
    TOKEN_DEFAULT_DACL tokenDacl{defaultAcl};
    check(SetTokenInformation(restricted.value, TokenDefaultDacl, &tokenDacl, sizeof(tokenDacl))); LocalFree(defaultAcl);
    check(CreateProcessAsUserW(restricted.value, argv[commandIndex], command.data(), nullptr, nullptr, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
        nullptr, nullptr, &startup.StartupInfo, &process));
    Handle child(process.hProcess), thread(process.hThread);
    const bool assigned = AssignProcessToJobObject(job.value, child.value) != FALSE;
    if (!assigned) TerminateProcess(child.value, 1);
    check(assigned);
    if (WaitForSingleObject(parent.value, 0) != WAIT_TIMEOUT) {
      TerminateJobObject(job.value, 1); check(false);
    }
    check(ResumeThread(thread.value) != static_cast<DWORD>(-1));
    for (auto handle : inherited) CloseHandle(handle);
    DeleteProcThreadAttributeList(attrs); if (internet) LocalFree(internet); if (privateNetwork) LocalFree(privateNetwork);
    HANDLE watched[] = {child.value, parent.value};
    const DWORD ended = WaitForMultipleObjects(2, watched, FALSE, INFINITE);
    DWORD code = 1;
    if (ended == WAIT_OBJECT_0) GetExitCodeProcess(child.value, &code);
    check(TerminateJobObject(job.value, code));
    // No new children can run. Relay threads exit with this short-lived broker;
    // perform ACL cleanup before exiting, then exit without racing their descriptors.
    for (auto it = profile.paths.rbegin(); it != profile.paths.rend(); ++it) profile.acl(*it, 0, REVOKE_ACCESS, false);
    profile.paths.clear(); DeleteAppContainerProfile(profile.name.c_str());
    ExitProcess(code);
  } catch (...) {
    std::cerr << "local.windows_sandbox_failed\n";
    ExitProcess(1);
  }
}
