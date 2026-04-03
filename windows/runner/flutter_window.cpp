#include "flutter_window.h"

#include <optional>
#include <variant>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <shellapi.h>
#include <wininet.h>
#include <cstdlib>
#include <cstdio>
#include <cctype>
#include <fcntl.h>
#include <io.h>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>
#include <condition_variable>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>

#include "flutter/generated_plugin_registrant.h"
#include "resources/mihomo_windows/mihomo.h"
#include "utils.h"

namespace {
// Window Message for traffic updates (must be unique)
constexpr UINT WM_TRAFFIC_UPDATE = WM_USER + 101;
// Window Message for latency test completion
constexpr UINT WM_LATENCY_COMPLETE = WM_USER + 102;
constexpr UINT WM_NATIVE_LOG = WM_USER + 103;
constexpr UINT WM_START_COMPLETE = WM_USER + 104;

struct LatencyTaskResult {
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  std::string value;
  std::string error_code;
  std::string error_message;
};

struct StartTaskResult {
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  std::string error_code;
  std::string error_message;
};

// Global Window Handle for posting messages
HWND g_main_window_handle = nullptr;

HMODULE g_mihomo_module = nullptr;
constexpr wchar_t kInternetSettingsPath[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kProxyEnableValueName[] = L"ProxyEnable";
constexpr wchar_t kProxyServerValueName[] = L"ProxyServer";
constexpr wchar_t kProxyOverrideValueName[] = L"ProxyOverride";
constexpr wchar_t kProxyServerValue[] = L"127.0.0.1:7890";
constexpr wchar_t kProxyOverrideValue[] = L"localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*";
bool g_proxy_snapshot_saved = false;
DWORD g_proxy_enable_snapshot = 0;
std::wstring g_proxy_server_snapshot;
std::wstring g_proxy_override_snapshot;
bool g_has_proxy_server_snapshot = false;
bool g_has_proxy_override_snapshot = false;
using StartFn = char* (*)(char*, char*);
using StopFn = void (*)();
using ForceUpdateConfigFn = char* (*)(char*);
using SetLogLevelFn = void (*)(char*);
using SetModeFn = void (*)(char*);
using GetModeFn = char* (*)();
using TrafficUpFn = long long (*)();
using TrafficDownFn = long long (*)();
using IsRunningFn = int (*)();
using GetProxiesFn = char* (*)();
using SelectProxyFn = int (*)(char*, char*);
using TestLatencyFn = char* (*)(char*);
using LastErrorFn = char* (*)();
using FreeCStringFn = void (*)(char*);

struct MihomoApi {
  StartFn start = nullptr;
  StopFn stop = nullptr;
  ForceUpdateConfigFn force_update_config = nullptr;
  SetLogLevelFn set_log_level = nullptr;
  SetModeFn set_mode = nullptr;
  GetModeFn get_mode = nullptr;
  TrafficUpFn traffic_up = nullptr;
  TrafficDownFn traffic_down = nullptr;
  IsRunningFn is_running = nullptr;
  GetProxiesFn get_proxies = nullptr;
  SelectProxyFn select_proxy = nullptr;
  TestLatencyFn test_latency = nullptr;
  LastErrorFn last_error = nullptr;
  FreeCStringFn free_cstring = nullptr;
} g_api;

std::wstring GetCurrentDir() {
  wchar_t buffer[MAX_PATH];
  GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  std::wstring full(buffer);
  const auto pos = full.find_last_of(L"\\/");
  if (pos == std::wstring::npos) {
    return L".";
  }
  return full.substr(0, pos);
}

bool FileExists(const std::string& path) {
  const DWORD attributes = GetFileAttributesA(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::vector<char> ToMutableBuffer(const std::string& value) {
  std::vector<char> out(value.begin(), value.end());
  out.push_back('\0');
  return out;
}

std::string TakeCString(char* ptr) {
  if (ptr == nullptr) {
    return "";
  }
  std::string value(ptr);
  if (g_api.free_cstring != nullptr) {
    g_api.free_cstring(ptr);
  }
  return value;
}

std::string ExtractJsonStringField(
    const std::string& json,
    size_t start,
    size_t end,
    const std::string& key) {
  size_t key_pos = json.find("\"" + key + "\":", start);
  if (key_pos == std::string::npos || key_pos > end) {
    return "";
  }
  size_t value_start = json.find_first_not_of(" \t\n\r", key_pos + key.length() + 3);
  if (value_start == std::string::npos || value_start > end || json[value_start] != '"') {
    return "";
  }
  value_start++;
  size_t value_end = json.find('"', value_start);
  if (value_end == std::string::npos || value_end > end) {
    return "";
  }
  return json.substr(value_start, value_end - value_start);
}

std::string ExtractJsonLiteralField(
    const std::string& json,
    size_t start,
    size_t end,
    const std::string& key) {
  size_t key_pos = json.find("\"" + key + "\":", start);
  if (key_pos == std::string::npos || key_pos > end) {
    return "";
  }
  size_t value_start = json.find_first_not_of(" \t\n\r", key_pos + key.length() + 3);
  if (value_start == std::string::npos || value_start > end) {
    return "";
  }
  size_t value_end = json.find_first_of(",}", value_start);
  if (value_end == std::string::npos || value_end > end) {
    return "";
  }
  return json.substr(value_start, value_end - value_start);
}

bool FindJsonObjectRange(
    const std::string& json,
    size_t search_start,
    size_t search_end,
    const std::string& key,
    size_t* object_start,
    size_t* object_end) {
  const std::string json_key = "\"" + key + "\":";
  size_t key_pos = json.find(json_key, search_start);
  if (key_pos == std::string::npos || key_pos > search_end) {
    return false;
  }
  size_t value_start = json.find('{', key_pos + json_key.length());
  if (value_start == std::string::npos || value_start > search_end) {
    return false;
  }
  int brace_depth = 1;
  size_t value_end = value_start + 1;
  bool in_quotes = false;
  while (value_end < json.length() && brace_depth > 0) {
    const char c = json[value_end];
    if (c == '"' && json[value_end - 1] != '\\') {
      in_quotes = !in_quotes;
    }
    if (!in_quotes) {
      if (c == '{') {
        brace_depth++;
      } else if (c == '}') {
        brace_depth--;
      }
    }
    value_end++;
  }
  if (brace_depth != 0 || value_end - 1 > search_end) {
    return false;
  }
  *object_start = value_start;
  *object_end = value_end;
  return true;
}

bool FindProxiesMapRange(
    const std::string& json,
    size_t* object_start,
    size_t* object_end) {
  if (json.empty()) {
    return false;
  }
  return FindJsonObjectRange(
      json,
      0,
      json.length() - 1,
      "proxies",
      object_start,
      object_end);
}

std::string FindSelectedProxyNameFromJson(
    const std::string& json,
    const std::string& group_name) {
  size_t proxies_start = 0;
  size_t proxies_end = 0;
  if (!FindProxiesMapRange(json, &proxies_start, &proxies_end)) {
    return "";
  }
  size_t group_start = 0;
  size_t group_end = 0;
  if (!FindJsonObjectRange(
          json,
          proxies_start,
          proxies_end,
          group_name,
          &group_start,
          &group_end)) {
    return "";
  }
  return ExtractJsonStringField(json, group_start, group_end, "now");
}

bool FindProxyObjectRange(
    const std::string& json,
    const std::string& proxy_name,
    size_t* object_start,
    size_t* object_end) {
  size_t proxies_start = 0;
  size_t proxies_end = 0;
  if (!FindProxiesMapRange(json, &proxies_start, &proxies_end)) {
    return false;
  }
  return FindJsonObjectRange(
      json,
      proxies_start,
      proxies_end,
      proxy_name,
      object_start,
      object_end);
}

std::string BuildSelectedProxyInfoStr(
    const std::string& json,
    const std::string& group_name) {
  const std::string selected_name = FindSelectedProxyNameFromJson(json, group_name);
  if (selected_name.empty()) {
    return "";
  }
  size_t object_start = 0;
  size_t object_end = 0;
  if (!FindProxyObjectRange(json, selected_name, &object_start, &object_end)) {
    return selected_name + "|Unknown|Unknown|false";
  }
  std::string type = ExtractJsonStringField(json, object_start, object_end, "type");
  std::string country = ExtractJsonStringField(json, object_start, object_end, "country");
  std::string udp = ExtractJsonLiteralField(json, object_start, object_end, "udp");
  if (type.empty()) {
    type = "Unknown";
  }
  if (country.empty()) {
    country = "Unknown";
  }
  if (udp.empty()) {
    udp = "false";
  }
  return selected_name + "|" + type + "|" + country + "|" + udp;
}

std::string ReadLastError() {
  if (g_api.last_error == nullptr) {
    return "";
  }
  return TakeCString(g_api.last_error());
}

std::string decryptKey(const unsigned char* data, size_t len, unsigned char key) {
    std::string res(len, '\0');
    for (size_t i = 0; i < len; ++i) {
        res[i] = data[i] ^ key;
    }
    return res;
}

void RunnerLog(const std::string& line);
std::string BoolText(bool value);
std::string WideToUtf8(const std::wstring& value);

bool EnsureMihomoApi() {
  if (g_mihomo_module != nullptr && g_api.start != nullptr) {
    return true;
  }
  const auto dll_path = GetCurrentDir() + L"\\mihomo_windows\\mihomo.dll";
  g_mihomo_module = LoadLibraryW(dll_path.c_str());
  if (g_mihomo_module == nullptr) {
    RunnerLog(
        "LoadLibrary failed path=" + WideToUtf8(dll_path) +
        " error=" + std::to_string(GetLastError()));
    return false;
  }

  g_api.start = reinterpret_cast<StartFn>(GetProcAddress(g_mihomo_module, "Start"));
  g_api.stop = reinterpret_cast<StopFn>(GetProcAddress(g_mihomo_module, "Stop"));
  g_api.force_update_config =
      reinterpret_cast<ForceUpdateConfigFn>(GetProcAddress(g_mihomo_module, "ForceUpdateConfig"));
  g_api.set_log_level =
      reinterpret_cast<SetLogLevelFn>(GetProcAddress(g_mihomo_module, "SetLogLevel"));
  g_api.set_mode = reinterpret_cast<SetModeFn>(GetProcAddress(g_mihomo_module, "SetMode"));
  g_api.get_mode = reinterpret_cast<GetModeFn>(GetProcAddress(g_mihomo_module, "GetMode"));
  g_api.traffic_up = reinterpret_cast<TrafficUpFn>(GetProcAddress(g_mihomo_module, "TrafficUp"));
  g_api.traffic_down = reinterpret_cast<TrafficDownFn>(GetProcAddress(g_mihomo_module, "TrafficDown"));
  g_api.is_running = reinterpret_cast<IsRunningFn>(GetProcAddress(g_mihomo_module, "IsRunning"));
  g_api.get_proxies = reinterpret_cast<GetProxiesFn>(GetProcAddress(g_mihomo_module, "GetProxies"));
  g_api.select_proxy = reinterpret_cast<SelectProxyFn>(GetProcAddress(g_mihomo_module, "SelectProxy"));
  g_api.test_latency = reinterpret_cast<TestLatencyFn>(GetProcAddress(g_mihomo_module, "TestLatency"));
  g_api.last_error = reinterpret_cast<LastErrorFn>(GetProcAddress(g_mihomo_module, "LastError"));
  g_api.free_cstring = reinterpret_cast<FreeCStringFn>(GetProcAddress(g_mihomo_module, "FreeCString"));

  const bool ready =
      g_api.start != nullptr && g_api.stop != nullptr &&
      g_api.set_mode != nullptr && g_api.get_mode != nullptr &&
      g_api.traffic_up != nullptr && g_api.traffic_down != nullptr &&
      g_api.is_running != nullptr && g_api.get_proxies != nullptr &&
      g_api.select_proxy != nullptr && g_api.test_latency != nullptr;
  RunnerLog(
      "EnsureMihomoApi ready=" + BoolText(ready) +
      " dll=" + WideToUtf8(dll_path));
  return ready;
}

// Traffic Monitor Thread
std::atomic<bool> g_traffic_monitor_active{false};
std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> g_traffic_sink;
std::thread g_traffic_thread;
std::mutex g_traffic_mutex;
std::condition_variable g_traffic_cv;
flutter::EncodableMap g_pending_traffic_data;
bool g_has_pending_traffic = false;
std::optional<int64_t> g_last_traffic_up;
std::optional<int64_t> g_last_traffic_down;
std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> g_native_log_sink;
std::thread g_native_log_thread;
std::mutex g_native_log_mutex;
std::deque<std::string> g_pending_native_logs;
std::deque<std::string> g_recent_native_logs;
std::atomic<bool> g_native_log_capture_active{false};
HANDLE g_native_log_read_handle = nullptr;
HANDLE g_native_log_write_handle = nullptr;
HANDLE g_original_stdout_handle = nullptr;
HANDLE g_original_stderr_handle = nullptr;
int g_original_stdout_fd = -1;
int g_original_stderr_fd = -1;

bool RedirectCrtStdStreams(HANDLE write_handle) {
  const HANDLE current_process = GetCurrentProcess();
  HANDLE stdout_handle = nullptr;
  HANDLE stderr_handle = nullptr;
  if (!DuplicateHandle(
          current_process,
          write_handle,
          current_process,
          &stdout_handle,
          0,
          FALSE,
          DUPLICATE_SAME_ACCESS)) {
    return false;
  }
  if (!DuplicateHandle(
          current_process,
          write_handle,
          current_process,
          &stderr_handle,
          0,
          FALSE,
          DUPLICATE_SAME_ACCESS)) {
    CloseHandle(stdout_handle);
    return false;
  }

  const int stdout_fd = _open_osfhandle(
      reinterpret_cast<intptr_t>(stdout_handle),
      _O_TEXT);
  if (stdout_fd == -1) {
    CloseHandle(stdout_handle);
    CloseHandle(stderr_handle);
    return false;
  }
  const int stderr_fd = _open_osfhandle(
      reinterpret_cast<intptr_t>(stderr_handle),
      _O_TEXT);
  if (stderr_fd == -1) {
    _close(stdout_fd);
    CloseHandle(stderr_handle);
    return false;
  }

  fflush(stdout);
  fflush(stderr);
  g_original_stdout_fd = _dup(_fileno(stdout));
  g_original_stderr_fd = _dup(_fileno(stderr));
  if (g_original_stdout_fd == -1 || g_original_stderr_fd == -1 ||
      _dup2(stdout_fd, _fileno(stdout)) != 0 ||
      _dup2(stderr_fd, _fileno(stderr)) != 0) {
    if (g_original_stdout_fd != -1) {
      _close(g_original_stdout_fd);
      g_original_stdout_fd = -1;
    }
    if (g_original_stderr_fd != -1) {
      _close(g_original_stderr_fd);
      g_original_stderr_fd = -1;
    }
    _close(stdout_fd);
    _close(stderr_fd);
    return false;
  }
  _close(stdout_fd);
  _close(stderr_fd);
  setvbuf(stdout, nullptr, _IONBF, 0);
  setvbuf(stderr, nullptr, _IONBF, 0);
  return true;
}

void RestoreCrtStdStreams() {
  fflush(stdout);
  fflush(stderr);
  if (g_original_stdout_fd != -1) {
    _dup2(g_original_stdout_fd, _fileno(stdout));
    _close(g_original_stdout_fd);
    g_original_stdout_fd = -1;
  }
  if (g_original_stderr_fd != -1) {
    _dup2(g_original_stderr_fd, _fileno(stderr));
    _close(g_original_stderr_fd);
    g_original_stderr_fd = -1;
  }
  setvbuf(stdout, nullptr, _IONBF, 0);
  setvbuf(stderr, nullptr, _IONBF, 0);
}

void EnqueueNativeLog(const std::string& line) {
  if (line.empty()) {
    return;
  }
  const std::string debug_line = "MIHOMO_WINDOWS: " + line + "\n";
  OutputDebugStringA(debug_line.c_str());
  {
    std::lock_guard<std::mutex> lock(g_native_log_mutex);
    g_pending_native_logs.push_back(line);
    while (g_pending_native_logs.size() > 200) {
      g_pending_native_logs.pop_front();
    }
    g_recent_native_logs.push_back(line);
    while (g_recent_native_logs.size() > 400) {
      g_recent_native_logs.pop_front();
    }
  }
  if (g_main_window_handle != nullptr) {
    PostMessage(g_main_window_handle, WM_NATIVE_LOG, 0, 0);
  }
}

void RunnerLog(const std::string& line) {
  EnqueueNativeLog("RUNNER: " + line);
}

std::string BoolText(bool value) {
  return value ? "true" : "false";
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(
      CP_UTF8,
      0,
      value.c_str(),
      -1,
      nullptr,
      0,
      nullptr,
      nullptr);
  if (size <= 1) {
    return "";
  }
  std::string utf8(static_cast<size_t>(size) - 1, '\0');
  WideCharToMultiByte(
      CP_UTF8,
      0,
      value.c_str(),
      -1,
      utf8.data(),
      size,
      nullptr,
      nullptr);
  return utf8;
}

std::string GetRecentNativeLogs() {
  std::deque<std::string> recent_logs;
  {
    std::lock_guard<std::mutex> lock(g_native_log_mutex);
    recent_logs = g_recent_native_logs;
  }
  std::string joined;
  for (const auto& line : recent_logs) {
    if (!joined.empty()) {
      joined.append("\n");
    }
    joined.append(line);
  }
  return joined;
}

bool StartNativeLogCapture() {
  if (g_native_log_capture_active) {
    return true;
  }
  SECURITY_ATTRIBUTES sa{};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  HANDLE read_handle = nullptr;
  HANDLE write_handle = nullptr;
  if (!CreatePipe(&read_handle, &write_handle, &sa, 0)) {
    return false;
  }
  if (!SetHandleInformation(read_handle, HANDLE_FLAG_INHERIT, 0)) {
    CloseHandle(read_handle);
    CloseHandle(write_handle);
    return false;
  }
  g_original_stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE);
  g_original_stderr_handle = GetStdHandle(STD_ERROR_HANDLE);
  const bool stdout_ok = SetStdHandle(STD_OUTPUT_HANDLE, write_handle) == TRUE;
  const bool stderr_ok = SetStdHandle(STD_ERROR_HANDLE, write_handle) == TRUE;
  if (!stdout_ok || !stderr_ok) {
    if (g_original_stdout_handle != nullptr) {
      SetStdHandle(STD_OUTPUT_HANDLE, g_original_stdout_handle);
      g_original_stdout_handle = nullptr;
    }
    if (g_original_stderr_handle != nullptr) {
      SetStdHandle(STD_ERROR_HANDLE, g_original_stderr_handle);
      g_original_stderr_handle = nullptr;
    }
    CloseHandle(read_handle);
    CloseHandle(write_handle);
    return false;
  }
  if (!RedirectCrtStdStreams(write_handle)) {
    if (g_original_stdout_handle != nullptr) {
      SetStdHandle(STD_OUTPUT_HANDLE, g_original_stdout_handle);
      g_original_stdout_handle = nullptr;
    }
    if (g_original_stderr_handle != nullptr) {
      SetStdHandle(STD_ERROR_HANDLE, g_original_stderr_handle);
      g_original_stderr_handle = nullptr;
    }
    CloseHandle(read_handle);
    CloseHandle(write_handle);
    return false;
  }
  g_native_log_read_handle = read_handle;
  g_native_log_write_handle = write_handle;
  g_native_log_capture_active = true;
  g_native_log_thread = std::thread([]() {
    std::string pending;
    char buffer[512];
    while (g_native_log_capture_active) {
      DWORD bytes_read = 0;
      const BOOL ok = ReadFile(
          g_native_log_read_handle,
          buffer,
          static_cast<DWORD>(sizeof(buffer)),
          &bytes_read,
          nullptr);
      if (!ok || bytes_read == 0) {
        break;
      }
      if (g_original_stdout_handle != nullptr) {
        DWORD bytes_written = 0;
        WriteFile(
            g_original_stdout_handle,
            buffer,
            bytes_read,
            &bytes_written,
            nullptr);
      }
      pending.append(buffer, bytes_read);
      size_t newline_pos = 0;
      while ((newline_pos = pending.find_first_of("\r\n")) != std::string::npos) {
        const std::string line = pending.substr(0, newline_pos);
        pending.erase(0, newline_pos + 1);
        while (!pending.empty() &&
               (pending.front() == '\r' || pending.front() == '\n')) {
          pending.erase(0, 1);
        }
        EnqueueNativeLog(line);
      }
    }
    if (!pending.empty()) {
      EnqueueNativeLog(pending);
    }
    g_native_log_capture_active = false;
  });
  RunnerLog("native log capture started");
  return true;
}

void StopNativeLogCapture() {
  g_native_log_capture_active = false;
  RestoreCrtStdStreams();
  if (g_native_log_write_handle != nullptr) {
    CloseHandle(g_native_log_write_handle);
    g_native_log_write_handle = nullptr;
  }
  if (g_native_log_thread.joinable()) {
    g_native_log_thread.join();
  }
  if (g_native_log_read_handle != nullptr) {
    CloseHandle(g_native_log_read_handle);
    g_native_log_read_handle = nullptr;
  }
  if (g_original_stderr_handle != nullptr) {
    SetStdHandle(STD_ERROR_HANDLE, g_original_stderr_handle);
    g_original_stderr_handle = nullptr;
  }
  if (g_original_stdout_handle != nullptr) {
    SetStdHandle(STD_OUTPUT_HANDLE, g_original_stdout_handle);
    g_original_stdout_handle = nullptr;
  }
}

void StopTrafficMonitor() {
  g_traffic_monitor_active = false;
  g_traffic_cv.notify_one();
  if (g_traffic_thread.joinable()) {
    g_traffic_thread.join();
  }
  g_last_traffic_up.reset();
  g_last_traffic_down.reset();
}

void StartTrafficMonitor() {
  if (g_traffic_monitor_active) return;
  
  // Ensure strictly clean state
  StopTrafficMonitor();

  g_traffic_monitor_active = true;
  g_traffic_thread = std::thread([]() {
    while (g_traffic_monitor_active) {
      if (EnsureMihomoApi()) {
        const auto up = static_cast<int64_t>(g_api.traffic_up());
        const auto down = static_cast<int64_t>(g_api.traffic_down());

        const bool changed =
            !g_last_traffic_up.has_value() || !g_last_traffic_down.has_value() ||
            g_last_traffic_up.value() != up || g_last_traffic_down.value() != down;
        if (changed) {
          g_last_traffic_up = up;
          g_last_traffic_down = down;

          {
            std::lock_guard<std::mutex> lock(g_traffic_mutex);
            g_pending_traffic_data = flutter::EncodableMap{
              {flutter::EncodableValue("up"), flutter::EncodableValue(up)},
              {flutter::EncodableValue("down"), flutter::EncodableValue(down)}
            };
            g_has_pending_traffic = true;
          }

          if (g_main_window_handle) {
             PostMessage(g_main_window_handle, WM_TRAFFIC_UPDATE, 0, 0);
          }
        }
      }
      
      std::unique_lock<std::mutex> lock(g_traffic_mutex);
      if (g_traffic_cv.wait_for(lock, std::chrono::seconds(1), []{ return !g_traffic_monitor_active; })) {
        break;
      }
    }
  });
}

class TrafficStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  TrafficStreamHandler() = default;
  virtual ~TrafficStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
    g_traffic_sink = std::move(events);
    StartTrafficMonitor();
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override {
    g_traffic_sink = nullptr;
    StopTrafficMonitor();
    return nullptr;
  }
};

class NativeLogsStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  NativeLogsStreamHandler() = default;
  virtual ~NativeLogsStreamHandler() = default;

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
    g_native_log_sink = std::move(events);
    std::deque<std::string> pending_logs;
    {
      std::lock_guard<std::mutex> lock(g_native_log_mutex);
      pending_logs.swap(g_pending_native_logs);
    }
    for (const auto& line : pending_logs) {
      if (g_native_log_sink) {
        g_native_log_sink->Success(flutter::EncodableValue(line));
      }
    }
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override {
    g_native_log_sink = nullptr;
    return nullptr;
  }
};

std::string GetStringArg(const flutter::MethodCall<>& call, const std::string& key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return "";
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end() || !std::holds_alternative<std::string>(it->second)) {
    return "";
  }
  return std::get<std::string>(it->second);
}

bool HasEnvProxy(const char* key) {
  char* value = nullptr;
  size_t size = 0;
  const errno_t code = _dupenv_s(&value, &size, key);
  if (code != 0 || value == nullptr) {
    return false;
  }
  const bool has_value = size > 1;
  free(value);
  return has_value;
}

std::string ReadProxyServerFromRegistry() {
  wchar_t proxy_server[512] = {0};
  DWORD proxy_server_size = sizeof(proxy_server);
  const LSTATUS status = RegGetValueW(
      HKEY_CURRENT_USER,
      kInternetSettingsPath,
      kProxyServerValueName,
      RRF_RT_REG_SZ,
      nullptr,
      proxy_server,
      &proxy_server_size);
  if (status != ERROR_SUCCESS) {
    return "";
  }
  const std::wstring value(proxy_server);
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) {
    return "";
  }
  std::string utf8(static_cast<size_t>(size) - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), size, nullptr, nullptr);
  return utf8;
}

bool IsLoopbackProxyString(const std::string& value) {
  if (value.empty()) {
    return false;
  }
  std::string lower = value;
  for (auto& c : lower) {
    c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
  }
  return lower.find("127.0.0.1:7890") != std::string::npos ||
         lower.find("localhost:7890") != std::string::npos;
}

std::string ReadProxyStateSummary() {
  DWORD proxy_enabled = 0;
  DWORD proxy_enabled_size = sizeof(proxy_enabled);
  const LSTATUS status = RegGetValueW(
      HKEY_CURRENT_USER,
      kInternetSettingsPath,
      kProxyEnableValueName,
      RRF_RT_DWORD,
      nullptr,
      &proxy_enabled,
      &proxy_enabled_size);
  const std::string proxy_server = ReadProxyServerFromRegistry();
  return "ProxyEnable=" +
         std::to_string(status == ERROR_SUCCESS ? proxy_enabled : 0) +
         ", ProxyServer=" +
         (proxy_server.empty() ? "<empty>" : proxy_server);
}

bool QueryRegString(
    HKEY key,
    const wchar_t* value_name,
    std::wstring* out_value,
    bool* out_exists) {
  DWORD type = 0;
  DWORD bytes = 0;
  const LSTATUS query_size_status = RegQueryValueExW(
      key,
      value_name,
      nullptr,
      &type,
      nullptr,
      &bytes);
  if (query_size_status == ERROR_FILE_NOT_FOUND) {
    *out_exists = false;
    out_value->clear();
    return true;
  }
  if (query_size_status != ERROR_SUCCESS || type != REG_SZ || bytes == 0) {
    return false;
  }
  std::wstring buffer(bytes / sizeof(wchar_t), L'\0');
  const LSTATUS read_status = RegQueryValueExW(
      key,
      value_name,
      nullptr,
      &type,
      reinterpret_cast<LPBYTE>(buffer.data()),
      &bytes);
  if (read_status != ERROR_SUCCESS) {
    return false;
  }
  if (!buffer.empty() && buffer.back() == L'\0') {
    buffer.pop_back();
  }
  *out_exists = true;
  *out_value = buffer;
  return true;
}

bool SetRegString(HKEY key, const wchar_t* value_name, const std::wstring& value) {
  return RegSetValueExW(
             key,
             value_name,
             0,
             REG_SZ,
             reinterpret_cast<const BYTE*>(value.c_str()),
             static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

bool DeleteRegValueIfExists(HKEY key, const wchar_t* value_name) {
  const LSTATUS status = RegDeleteValueW(key, value_name);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

bool SaveProxySnapshot(HKEY key) {
  if (g_proxy_snapshot_saved) {
    return true;
  }
  DWORD proxy_enable = 0;
  DWORD proxy_enable_size = sizeof(proxy_enable);
  const LSTATUS proxy_enable_status = RegGetValueW(
      HKEY_CURRENT_USER,
      kInternetSettingsPath,
      kProxyEnableValueName,
      RRF_RT_DWORD,
      nullptr,
      &proxy_enable,
      &proxy_enable_size);
  g_proxy_enable_snapshot = proxy_enable_status == ERROR_SUCCESS ? proxy_enable : 0;
  if (!QueryRegString(key, kProxyServerValueName, &g_proxy_server_snapshot, &g_has_proxy_server_snapshot)) {
    return false;
  }
  if (!QueryRegString(key, kProxyOverrideValueName, &g_proxy_override_snapshot, &g_has_proxy_override_snapshot)) {
    return false;
  }
  g_proxy_snapshot_saved = true;
  return true;
}

bool RestoreProxySnapshot(HKEY key) {
  if (!g_proxy_snapshot_saved) {
    const DWORD proxy_enable = 0;
    return RegSetValueExW(
               key,
               kProxyEnableValueName,
               0,
               REG_DWORD,
               reinterpret_cast<const BYTE*>(&proxy_enable),
               sizeof(proxy_enable)) == ERROR_SUCCESS;
  }
  if (g_has_proxy_server_snapshot) {
    if (!SetRegString(key, kProxyServerValueName, g_proxy_server_snapshot)) {
      return false;
    }
  } else if (!DeleteRegValueIfExists(key, kProxyServerValueName)) {
    return false;
  }
  if (g_has_proxy_override_snapshot) {
    if (!SetRegString(key, kProxyOverrideValueName, g_proxy_override_snapshot)) {
      return false;
    }
  } else if (!DeleteRegValueIfExists(key, kProxyOverrideValueName)) {
    return false;
  }
  return RegSetValueExW(
             key,
             kProxyEnableValueName,
             0,
             REG_DWORD,
             reinterpret_cast<const BYTE*>(&g_proxy_enable_snapshot),
             sizeof(g_proxy_enable_snapshot)) == ERROR_SUCCESS;
}

bool ApplySystemProxy(bool enable) {
  RunnerLog(
      std::string("ApplySystemProxy request enable=") + BoolText(enable) +
      " before=" + ReadProxyStateSummary());
  HKEY internet_settings = nullptr;
  const LSTATUS open_status = RegOpenKeyExW(
      HKEY_CURRENT_USER,
      kInternetSettingsPath,
      0,
      KEY_SET_VALUE | KEY_QUERY_VALUE,
      &internet_settings);
  if (open_status != ERROR_SUCCESS || internet_settings == nullptr) {
    RunnerLog(
        "ApplySystemProxy open registry failed error=" +
        std::to_string(open_status));
    return false;
  }

  if (enable) {
    if (!SaveProxySnapshot(internet_settings)) {
      RegCloseKey(internet_settings);
      RunnerLog("ApplySystemProxy save snapshot failed");
      return false;
    }
    if (!SetRegString(internet_settings, kProxyServerValueName, kProxyServerValue) ||
        !SetRegString(internet_settings, kProxyOverrideValueName, kProxyOverrideValue)) {
      RegCloseKey(internet_settings);
      RunnerLog("ApplySystemProxy write proxy server failed");
      return false;
    }
    const DWORD proxy_enable = 1;
    if (RegSetValueExW(
            internet_settings,
            kProxyEnableValueName,
            0,
            REG_DWORD,
            reinterpret_cast<const BYTE*>(&proxy_enable),
            sizeof(proxy_enable)) != ERROR_SUCCESS) {
      RegCloseKey(internet_settings);
      RunnerLog("ApplySystemProxy enable proxy flag failed");
      return false;
    }
  } else {
    if (!RestoreProxySnapshot(internet_settings)) {
      RegCloseKey(internet_settings);
      RunnerLog("ApplySystemProxy restore snapshot failed");
      return false;
    }
  }
  RegCloseKey(internet_settings);

  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  RunnerLog(
      std::string("ApplySystemProxy success enable=") + BoolText(enable) +
      " after=" + ReadProxyStateSummary());
  return true;
}

void CleanupProxySettings() {
  ApplySystemProxy(false);
  if (EnsureMihomoApi()) {
     g_api.stop();
  }
}

BOOL WINAPI ConsoleCtrlHandler(DWORD dwCtrlType) {
  switch (dwCtrlType) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
      CleanupProxySettings();
      return FALSE; 
    default:
      return FALSE;
  }
}
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  StopNativeLogCapture();
  StopTrafficMonitor();
  g_native_log_sink = nullptr;
  g_traffic_sink = nullptr;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Register cleanup handlers for unexpected termination
  SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
  std::atexit(CleanupProxySettings);
  
  g_main_window_handle = GetHandle();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Setup MethodChannel for Mihomo
  static std::unique_ptr<flutter::MethodChannel<>> mihomo_channel;
  static std::unique_ptr<flutter::MethodChannel<>> security_channel;
  static std::unique_ptr<flutter::MethodChannel<>> hot_update_channel;
  static std::unique_ptr<flutter::EventChannel<>> traffic_channel;
  static std::unique_ptr<flutter::EventChannel<>> native_logs_channel;

  mihomo_channel = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "com.accelerator.tg/mihomo",
      &flutter::StandardMethodCodec::GetInstance());
  security_channel = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "com.accelerator.tg/security",
      &flutter::StandardMethodCodec::GetInstance());
  hot_update_channel = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "com.accelerator.tg/hot_update",
      &flutter::StandardMethodCodec::GetInstance());

  traffic_channel = std::make_unique<flutter::EventChannel<>>(
      flutter_controller_->engine()->messenger(), "com.accelerator.tg/mihomo/traffic",
      &flutter::StandardMethodCodec::GetInstance());
  traffic_channel->SetStreamHandler(std::make_unique<TrafficStreamHandler>());
  native_logs_channel = std::make_unique<flutter::EventChannel<>>(
      flutter_controller_->engine()->messenger(), "com.accelerator.tg/mihomo/logs",
      &flutter::StandardMethodCodec::GetInstance());
  native_logs_channel->SetStreamHandler(std::make_unique<NativeLogsStreamHandler>());

  security_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "isDebuggerAttached") {
          BOOL remote_debugger = FALSE;
          CheckRemoteDebuggerPresent(GetCurrentProcess(), &remote_debugger);
          const bool attached = IsDebuggerPresent() || remote_debugger == TRUE;
          result->Success(flutter::EncodableValue(attached));
        } else if (call.method_name() == "isAppDebuggable") {
          result->Success(flutter::EncodableValue(false));
        } else if (call.method_name() == "isProxyDetected") {
          DWORD proxy_enabled = 0;
          DWORD proxy_enabled_size = sizeof(proxy_enabled);
          const LSTATUS status = RegGetValueW(
              HKEY_CURRENT_USER,
              L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
              L"ProxyEnable",
              RRF_RT_DWORD,
              nullptr,
              &proxy_enabled,
              &proxy_enabled_size);
          const std::string proxy_server = ReadProxyServerFromRegistry();
          const bool loopback_proxy = IsLoopbackProxyString(proxy_server);
          const bool http_proxy = HasEnvProxy("HTTP_PROXY");
          const bool https_proxy = HasEnvProxy("HTTPS_PROXY");
          const bool detected = (status == ERROR_SUCCESS && proxy_enabled == 1 && !loopback_proxy) ||
                                http_proxy || https_proxy;
          result->Success(flutter::EncodableValue(detected));
        } else {
          result->NotImplemented();
        }
      });

  hot_update_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "restartApp") {
          const bool restarted = RelaunchCurrentExecutable();
          if (!restarted) {
            result->Error("RESTART_FAILED", "Failed to relaunch executable", nullptr);
            return;
          }
          result->Success(flutter::EncodableValue(true));
          PostQuitMessage(0);
        } else {
          result->NotImplemented();
        }
      });

  mihomo_channel->SetMethodCallHandler(
       [](const flutter::MethodCall<>& call,
          std::unique_ptr<flutter::MethodResult<>> result) {
         if (call.method_name() == "initAssets") {
            result->Success();
         } else if (call.method_name() == "start") {
            if (!StartNativeLogCapture()) {
              RunnerLog("native log capture unavailable");
            }
            if (!EnsureMihomoApi()) {
              result->Error("DLL_LOAD_FAILED", "Failed to load mihomo.dll", nullptr);
              return;
            }
            const std::string config_path = GetStringArg(call, "configPath");
            RunnerLog("start request configPath=" + config_path);
            if (config_path.empty()) {
              result->Error("INVALID_ARGUMENT", "configPath is empty", nullptr);
              return;
            }

            // Extract directory and filename from config_path
            std::string home_dir = ".";
            std::string config_file = "config.yaml";
            
            const size_t last_sep = config_path.find_last_of("\\/");
            if (last_sep != std::string::npos) {
                home_dir = config_path.substr(0, last_sep);
                // We trust the filename matches what we expect, or we could extract it:
                // config_file = config_path.substr(last_sep + 1);
            } else {
                home_dir = config_path;
            }

            const std::string config_file_path = home_dir + "\\config.yaml";
            const std::string mmdb_file_path = home_dir + "\\Country.mmdb";
            if (!FileExists(config_file_path)) {
              result->Error("CONFIG_MISSING", "Missing config.yaml: " + config_file_path, nullptr);
              return;
            }
            if (!FileExists(mmdb_file_path)) {
              result->Error("MMDB_MISSING", "Missing Country.mmdb: " + mmdb_file_path, nullptr);
              return;
            }

            std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_result = std::move(result);
            std::thread([shared_result, home_dir, config_file]() {
              std::string error_code;
              std::string error_message;

              if (g_api.set_log_level != nullptr) {
                auto log_level = ToMutableBuffer("debug");
                g_api.set_log_level(log_level.data());
                RunnerLog("set native log level=debug");
              }

              auto home = ToMutableBuffer(home_dir);
              auto config_name = ToMutableBuffer(config_file);
              const std::string start_result =
                  TakeCString(g_api.start(home.data(), config_name.data()));
              const bool running = g_api.is_running() != 0;
              if (!start_result.empty() || !running) {
                const std::string last_error = ReadLastError();
                RunnerLog(
                    "start failed running=" + BoolText(running) +
                    " startResult=" +
                    (start_result.empty() ? "<empty>" : start_result) +
                    " lastError=" +
                    (last_error.empty() ? "<empty>" : last_error));
                error_code = "START_FAILED";
                error_message = !start_result.empty()
                                    ? start_result
                                    : (last_error.empty() ? "Start failed"
                                                          : last_error);
              } else if (!ApplySystemProxy(true)) {
                RunnerLog(
                    "start failed because system proxy enable returned false");
                g_api.stop();
                error_code = "PROXY_SETUP_FAILED";
                error_message = "Failed to enable system proxy";
              } else {
                const std::string mode = TakeCString(g_api.get_mode());
                RunnerLog(
                    "start success running=" + BoolText(running) +
                    " mode=" + (mode.empty() ? "<empty>" : mode) + " " +
                    ReadProxyStateSummary());
              }

              auto* task = new StartTaskResult();
              task->result = shared_result;
              task->error_code = error_code;
              task->error_message = error_message;

              if (g_main_window_handle) {
                PostMessage(g_main_window_handle, WM_START_COMPLETE,
                            (WPARAM)task, 0);
              } else {
                if (!error_code.empty()) {
                  shared_result->Error(error_code, error_message, nullptr);
                } else {
                  shared_result->Success();
                }
                delete task;
              }
            }).detach();
          } else if (call.method_name() == "stop") {
            RunnerLog("stop request");
            if (EnsureMihomoApi()) {
              g_api.stop();
            }
            ApplySystemProxy(false);
            RunnerLog("stop completed");
            result->Success();
         } else if (call.method_name() == "ensureSystemProxy") {
            const bool applied = ApplySystemProxy(true);
            RunnerLog(
                std::string("ensureSystemProxy result=") + BoolText(applied) +
                " " + ReadProxyStateSummary());
            result->Success(flutter::EncodableValue(applied));
         } else if (call.method_name() == "isRunning") {
            if (!EnsureMihomoApi()) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            result->Success(flutter::EncodableValue(g_api.is_running() != 0));
         } else if (call.method_name() == "getRecentNativeLogs") {
            result->Success(flutter::EncodableValue(GetRecentNativeLogs()));
         } else if (call.method_name() == "queryTunnelState") {
            if (!EnsureMihomoApi() || g_api.is_running() == 0) {
              result->Success();
              return;
            }
            std::string mode = TakeCString(g_api.get_mode());
            if (mode.empty()) {
              mode = "rule";
            }
            result->Success(flutter::EncodableValue("{\"mode\":\"" + mode + "\"}"));
         } else if (call.method_name() == "queryTrafficNow") {
            if (!EnsureMihomoApi()) {
              result->Success(flutter::EncodableMap{});
              return;
            }
            const auto up = static_cast<int64_t>(g_api.traffic_up());
            const auto down = static_cast<int64_t>(g_api.traffic_down());
            flutter::EncodableMap map;
            map[flutter::EncodableValue("up")] = flutter::EncodableValue(up);
            map[flutter::EncodableValue("down")] = flutter::EncodableValue(down);
            result->Success(flutter::EncodableValue(map));
         } else if (call.method_name() == "changeMode") {
            if (!EnsureMihomoApi()) {
              result->Error("SET_MODE_FAILED", "Mihomo API unavailable", nullptr);
              return;
            }
            const std::string mode = GetStringArg(call, "mode");
            if (mode.empty()) {
              result->Error("INVALID_MODE", "Invalid mode", nullptr);
              return;
            }
            auto mode_buf = ToMutableBuffer(mode);
            g_api.set_mode(mode_buf.data());
            const std::string actual = TakeCString(g_api.get_mode());
            RunnerLog(
                "changeMode requested=" + mode +
                " actual=" + (actual.empty() ? "<empty>" : actual));
            result->Success(flutter::EncodableValue(!actual.empty() && _stricmp(actual.c_str(), mode.c_str()) == 0));
         } else if (call.method_name() == "getMode") {
            if (!EnsureMihomoApi()) {
              result->Error("GET_MODE_FAILED", "Mihomo API unavailable", nullptr);
              return;
            }
            const std::string mode = TakeCString(g_api.get_mode());
            if (mode.empty()) {
              RunnerLog("getMode returned empty");
            }
            result->Success(flutter::EncodableValue(mode));
         } else if (call.method_name() == "getProxies") {
            if (!EnsureMihomoApi()) {
              result->Error("GET_PROXIES_FAILED", "Mihomo API unavailable", nullptr);
              return;
            }
            const std::string proxies = TakeCString(g_api.get_proxies());
            if (proxies.empty()) {
              RunnerLog("getProxies returned empty");
            } else {
              RunnerLog("getProxies bytes=" + std::to_string(proxies.size()));
              if (proxies.size() <= 80) {
                RunnerLog("getProxies raw=" + proxies);
              }
            }
            result->Success(flutter::EncodableValue(proxies));
         } else if (call.method_name() == "selectProxy") {
            if (!EnsureMihomoApi()) {
              result->Error("SELECT_PROXY_FAILED", "Mihomo API unavailable", nullptr);
              return;
            }
            std::string proxy_name = GetStringArg(call, "name");
            if (proxy_name.empty()) {
               proxy_name = GetStringArg(call, "proxyName");
            }
            std::string group_name = GetStringArg(call, "groupName");
            if (group_name.empty()) {
               group_name = "GLOBAL";
            }
            
            if (proxy_name.empty()) {
              result->Error("INVALID_ARGUMENT", "proxyName cannot be empty", nullptr);
              return;
            }
            auto group_buf = ToMutableBuffer(group_name);
            auto proxy_buf = ToMutableBuffer(proxy_name);
            const bool selected = g_api.select_proxy(group_buf.data(), proxy_buf.data()) != 0;
            RunnerLog(
                "selectProxy group=" + group_name +
                " name=" + proxy_name +
                " ok=" + BoolText(selected));
            result->Success(flutter::EncodableValue(selected));
         } else if (call.method_name() == "urlTest") {
            if (!EnsureMihomoApi()) {
              result->Error("TEST_LATENCY_FAILED", "Mihomo API unavailable", nullptr);
              return;
            }
             std::string proxy_name = GetStringArg(call, "name");
             if (proxy_name.empty()) {
                 result->Error("INVALID_ARGUMENT", "name cannot be empty", nullptr);
                 return;
             }
             
             // Keep the result alive
             std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_result = std::move(result);
             
             std::thread([shared_result, proxy_name]() {
                auto name_buf = ToMutableBuffer(proxy_name);
                std::string latency = TakeCString(g_api.test_latency(name_buf.data()));
                
                auto* task = new LatencyTaskResult();
                task->result = shared_result;
                task->value = latency;
                
                if (g_main_window_handle) {
                    PostMessage(g_main_window_handle, WM_LATENCY_COMPLETE, (WPARAM)task, 0);
                } else {
                    delete task;
                }
             }).detach();
          } else if (call.method_name() == "getSelectedProxy") {
             if (!EnsureMihomoApi()) {
               result->Error("GET_SELECTED_PROXY_FAILED", "Mihomo API unavailable", nullptr);
               return;
             }
             std::string group_name = GetStringArg(call, "groupName");
             if (group_name.empty()) {
                 result->Error("INVALID_ARGUMENT", "groupName cannot be empty", nullptr);
                 return;
             }
             std::string json = TakeCString(g_api.get_proxies());
             const std::string selected_name =
                 FindSelectedProxyNameFromJson(json, group_name);
             if (selected_name.empty()) {
                 result->Success(); // Not found
                 return;
             }
             result->Success(flutter::EncodableValue(selected_name));
          } else if (call.method_name() == "getSelectedProxySync") {
             if (!EnsureMihomoApi()) {
               result->Success(flutter::EncodableValue(""));
               return;
             }
             std::string group_name = GetStringArg(call, "groupName");
             if (group_name.empty()) group_name = "GLOBAL";
             std::string json = TakeCString(g_api.get_proxies());
             result->Success(flutter::EncodableValue(
                 FindSelectedProxyNameFromJson(json, group_name)));
         } else if (call.method_name() == "getSelectedProxyInfoSync") {
            if (!EnsureMihomoApi()) {
              result->Success(flutter::EncodableValue(""));
              return;
            }
            std::string group_name = GetStringArg(call, "groupName");
            if (group_name.empty()) group_name = "GLOBAL";
            std::string json = TakeCString(g_api.get_proxies());
            if (json.empty()) {
              result->Success(flutter::EncodableValue(""));
              return;
            }
            result->Success(
                flutter::EncodableValue(
                    BuildSelectedProxyInfoStr(json, group_name)));
          } else if (call.method_name() == "getProxyListStr") {
            if (!EnsureMihomoApi()) {
              result->Error("GET_PROXIES_FAILED", "Mihomo API unavailable", nullptr);
              return;
            }
            std::string json = TakeCString(g_api.get_proxies());
            if (json.empty()) {
                RunnerLog("getProxyListStr source json empty");
                result->Success(flutter::EncodableValue(""));
                return;
            }
            if (json.size() <= 80) {
                RunnerLog("getProxyListStr source raw=" + json);
            }
            auto get_val = [&](size_t start, size_t end, const std::string& key) -> std::string {
                size_t key_pos = json.find("\"" + key + "\":", start);
                if (key_pos == std::string::npos || key_pos > end) return "";
                size_t val_start = json.find_first_not_of(" \t\n\r", key_pos + key.length() + 3);
                if (val_start == std::string::npos || val_start > end) return "";
                if (json[val_start] == '"') {
                    size_t val_end = json.find('"', val_start + 1);
                    if (val_end == std::string::npos || val_end > end) return "";
                    return json.substr(val_start + 1, val_end - val_start - 1);
                } else {
                    size_t val_end = json.find_first_of(",}", val_start);
                    if (val_end == std::string::npos || val_end > end) return "";
                    return json.substr(val_start, val_end - val_start);
                }
            };

            std::vector<std::string> global_list;
            size_t global_start = 0;
            size_t global_end = 0;
            if (FindProxyObjectRange(json, "GLOBAL", &global_start, &global_end)) {
                size_t all_pos = json.find("\"all\":", global_start);
                if (all_pos != std::string::npos) {
                    size_t list_start = json.find("[", all_pos);
                    size_t list_end = json.find("]", list_start);
                    if (list_start != std::string::npos &&
                        list_end != std::string::npos &&
                        list_end <= global_end) {
                        std::string all_list = json.substr(list_start + 1, list_end - list_start - 1);
                        size_t cur = 0;
                        while (cur < all_list.length()) {
                            size_t next_quote = all_list.find('"', cur);
                            if (next_quote == std::string::npos) break;
                            size_t close_quote = all_list.find('"', next_quote + 1);
                            if (close_quote == std::string::npos) break;
                            std::string proxy_name = all_list.substr(next_quote + 1, close_quote - next_quote - 1);
                            cur = close_quote + 1;
                            if (proxy_name != "DIRECT" && proxy_name != "REJECT") {
                                global_list.push_back(proxy_name);
                            }
                        }
                    }
                }
            }

            std::unordered_map<std::string, std::string> proxy_map;
            size_t proxies_pos = json.find("\"proxies\":");
            if (proxies_pos != std::string::npos) {
                size_t start = json.find("{", proxies_pos);
                if (start != std::string::npos) {
                    start++;
                    size_t cur = start;
                    while (cur < json.length()) {
                        size_t next_quote = json.find_first_not_of(" \t\n\r,", cur);
                        if (next_quote == std::string::npos) break;
                        if (json[next_quote] == '}') break;
                        if (json[next_quote] != '"') break;
                        size_t key_end = json.find('"', next_quote + 1);
                        if (key_end == std::string::npos) break;
                        std::string name = json.substr(next_quote + 1, key_end - next_quote - 1);
                        size_t colon = json.find(':', key_end);
                        if (colon == std::string::npos) break;
                        size_t val_start = json.find_first_not_of(" \t\n\r", colon + 1);
                        if (val_start == std::string::npos) break;
                        if (json[val_start] == '{') {
                            int brace = 1;
                            size_t val_end = val_start + 1;
                            bool in_q = false;
                            while (val_end < json.length() && brace > 0) {
                                char c = json[val_end];
                                if (c == '"' && json[val_end - 1] != '\\') in_q = !in_q;
                                if (!in_q) {
                                    if (c == '{') brace++;
                                    else if (c == '}') brace--;
                                }
                                val_end++;
                            }
                            std::string type = get_val(val_start, val_end, "type");
                            if (type != "Selector" && type != "URLTest" &&
                                type != "Fallback" && type != "LoadBalance") {
                                std::string server = get_val(val_start, val_end, "server");
                                std::string udp = get_val(val_start, val_end, "udp");
                                proxy_map[name] = type + "-" + server + "-" + "Unknown" + "-" + udp;
                            }
                            cur = val_end;
                        } else {
                            cur = json.find(',', val_start);
                            if (cur == std::string::npos) break;
                            cur++;
                        }
                    }
                }
            }

            std::string out_str = "";
            for (const auto& name : global_list) {
                auto it = proxy_map.find(name);
                if (it != proxy_map.end()) {
                    if (!out_str.empty()) out_str += "|";
                    out_str += name + "-" + it->second;
                }
            }
            RunnerLog(
                "getProxyListStr nodes=" + std::to_string(global_list.size()) +
                " payloadBytes=" + std::to_string(out_str.size()));
            result->Success(flutter::EncodableValue(out_str));

          } else if (call.method_name() == "reloadConfig") {
            if (!EnsureMihomoApi() || g_api.force_update_config == nullptr) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            auto name = ToMutableBuffer("config.yaml");
            const std::string reload_result = TakeCString(g_api.force_update_config(name.data()));
            result->Success(flutter::EncodableValue(reload_result.empty()));
          } else if (call.method_name() == "getAesKey") {
             const unsigned char enc[] = {
                 0x62, 0x63, 0x1b, 0x6d, 0x18, 0x6c, 0x19, 0x6f, 0x1e, 0x6e, 0x1f, 0x69, 0x1c, 0x68, 0x6a, 0x6b,
                 0x63, 0x62, 0x6d, 0x6c, 0x6f, 0x6e, 0x69, 0x68, 0x6b, 0x6a, 0x1b, 0x18, 0x19, 0x1e, 0x1f, 0x1c,
                 0x6b, 0x68, 0x69, 0x6e, 0x6f, 0x6c, 0x68, 0x62, 0x63, 0x6a, 0x1b, 0x18, 0x19, 0x1e, 0x1f, 0x1c,
                 0x62, 0x63, 0x1b, 0x6d, 0x18, 0x6c, 0x19, 0x6f, 0x1e, 0x6e, 0x1f, 0x69, 0x1c, 0x68, 0x6a, 0x6b
             };
             result->Success(flutter::EncodableValue(decryptKey(enc, sizeof(enc), 0x5A)));
           } else if (call.method_name() == "getObfuscateKey") {
             const unsigned char enc[] = {
                0x6d, 0x17, 0x62, 0x14, 0x63, 0x18, 0x62, 0xc, 0x6d, 0x19, 0x63, 0x2, 0x62, 0x0, 0x6d, 0x1b,
                0x63, 0x9, 0x62, 0x1e, 0x6d, 0x1c, 0x63, 0x1d, 0x62, 0x12, 0x6d, 0x10, 0x63, 0x11, 0x62, 0x16,
                0x6d, 0xa, 0x63, 0x15, 0x62, 0x13, 0x6d, 0xf, 0x63, 0x3, 0x62, 0xd, 0x6d, 0xe, 0x63, 0x8,
                0x62, 0xa, 0x6d, 0x17, 0x63, 0x14, 0x62, 0x18, 0x6d, 0xc, 0x63, 0x19, 0x62, 0x2, 0x6d, 0x0,
                0x63, 0x1b, 0x62, 0x9, 0x6d, 0x1e, 0x63, 0x1c, 0x62, 0x1d, 0x6d, 0x12, 0x63, 0x10, 0x62, 0x11,
                0x6d, 0x16, 0x6c, 0xa
            };
            result->Success(flutter::EncodableValue(decryptKey(enc, sizeof(enc), 0x5A)));
          } else if (call.method_name() == "getServerUrlKey") {
            const unsigned char enc[] = {
                0x32, 0x2e, 0x2e, 0x2a, 0x29, 0x60, 0x75, 0x75, 0x2c, 0x2a, 0x34, 0x3b, 0x2a, 0x33, 0x29, 0x74,
                0x39, 0x35, 0x37
            };
            result->Success(flutter::EncodableValue(decryptKey(enc, sizeof(enc), 0x5A)));
          } else if (call.method_name() == "queryGroupNames") {
            result->Success(flutter::EncodableValue("[]"));
         } else if (call.method_name() == "queryGroup") {
            result->Success(flutter::EncodableValue("{}"));
         } else if (call.method_name() == "patchSelector") {
            result->Success(flutter::EncodableValue(false));
         } else if (call.method_name() == "patchOverride") {
            if (!EnsureMihomoApi()) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            const std::string mode = GetStringArg(call, "mode");
            if (mode.empty()) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            auto mode_buf = ToMutableBuffer(mode);
            g_api.set_mode(mode_buf.data());
            result->Success(flutter::EncodableValue(true));
         } else if (call.method_name() == "queryProviders") {
            result->Success(flutter::EncodableValue("{}"));
         } else if (call.method_name() == "updateNotification") {
            result->Success(flutter::EncodableValue(true));
         } else {
            result->NotImplemented();
         }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ApplySystemProxy(false);
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_TRAFFIC_UPDATE: {
      try {
        if (g_traffic_sink) {
          std::lock_guard<std::mutex> lock(g_traffic_mutex);
          if (g_has_pending_traffic) {
            g_traffic_sink->Success(flutter::EncodableValue(g_pending_traffic_data));
            g_has_pending_traffic = false;
          }
        }
      } catch (...) {}
      return 0;
    }
    case WM_LATENCY_COMPLETE: {
      try {
        std::unique_ptr<LatencyTaskResult> task(reinterpret_cast<LatencyTaskResult*>(wparam));
        if (task && task->result) {
            if (task->error_code.empty()) {
                task->result->Success(flutter::EncodableValue(task->value));
            } else {
                task->result->Error(task->error_code, task->error_message, nullptr);
            }
        }
      } catch (...) {}
      return 0;
    }
    case WM_START_COMPLETE: {
      try {
        std::unique_ptr<StartTaskResult> task(reinterpret_cast<StartTaskResult*>(wparam));
        if (task && task->result) {
          if (task->error_code.empty()) {
            task->result->Success();
          } else {
            task->result->Error(task->error_code, task->error_message, nullptr);
          }
        }
      } catch (...) {}
      return 0;
    }
    case WM_NATIVE_LOG: {
      try {
        if (g_native_log_sink) {
          std::deque<std::string> pending_logs;
          {
            std::lock_guard<std::mutex> lock(g_native_log_mutex);
            pending_logs.swap(g_pending_native_logs);
          }
          for (const auto& line : pending_logs) {
            g_native_log_sink->Success(flutter::EncodableValue(line));
          }
        }
      } catch (...) {}
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
