#include "utils.h"

#include <flutter_windows.h>
#include <ShlObj.h>
#include <filesystem>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

namespace {

std::filesystem::path ExecutablePath() {
  wchar_t buffer[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return std::filesystem::current_path();
  }
  return std::filesystem::path(buffer);
}

std::filesystem::path ExecutableDirectory() {
  return ExecutablePath().parent_path();
}

std::filesystem::path LegacyHotUpdateRoot() {
  return ExecutableDirectory() / L"hot_update";
}

std::filesystem::path WritableHotUpdateRoot() {
  PWSTR local_app_data = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(
          FOLDERID_LocalAppData,
          KF_FLAG_CREATE,
          nullptr,
          &local_app_data)) &&
      local_app_data != nullptr) {
    const auto app_name = ExecutablePath().stem();
    std::filesystem::path root(local_app_data);
    ::CoTaskMemFree(local_app_data);
    return root / app_name / L"hot_update";
  }
  if (local_app_data != nullptr) {
    ::CoTaskMemFree(local_app_data);
  }
  return LegacyHotUpdateRoot();
}

std::filesystem::path WritableHotUpdateBundleRoot() {
  return WritableHotUpdateRoot() / L"runtime_bundle";
}

void DeleteIfExists(const std::filesystem::path& path) {
  std::error_code error;
  if (std::filesystem::exists(path, error)) {
    std::filesystem::remove_all(path, error);
  }
}

bool HasEnoughFlutterAssetsContent(const std::filesystem::path& flutter_assets,
                                  int min_count = 1) {
  std::error_code error;
  if (!std::filesystem::is_directory(flutter_assets, error)) {
    return false;
  }

  int count = 0;
  for (auto it = std::filesystem::recursive_directory_iterator(
           flutter_assets,
           std::filesystem::directory_options::skip_permission_denied,
           error);
       !error && it != std::filesystem::recursive_directory_iterator();
       ++it) {
    const auto& entry = *it;
    if (!entry.is_regular_file(error)) {
      continue;
    }
    const auto name = entry.path().filename().wstring();
    if (name == L"AssetManifest.bin" || name == L"AssetManifest.bin.json" ||
        name == L"AssetManifest.json" || name == L"FontManifest.json" ||
        name == L"NativeAssetsManifest.json" || name == L"NOTICES.Z") {
      continue;
    }
    count += 1;
    if (count >= min_count) {
      return true;
    }
  }
  return false;
}

bool IsValidHotUpdateBundle(const std::filesystem::path& current) {
  std::error_code error;
  const auto app = current / L"app.so";
  const auto icu = current / L"icudtl.dat";
  const auto flutter_assets = current / L"flutter_assets";
  const auto asset_manifest_bin = flutter_assets / L"AssetManifest.bin";
  const auto asset_manifest_json = flutter_assets / L"AssetManifest.json";
  return std::filesystem::exists(app, error) &&
         std::filesystem::exists(icu, error) &&
         std::filesystem::is_directory(flutter_assets, error) &&
         (std::filesystem::exists(asset_manifest_bin, error) ||
          std::filesystem::exists(asset_manifest_json, error)) &&
         HasEnoughFlutterAssetsContent(flutter_assets);
}

bool ReplaceDirectory(
    const std::filesystem::path& source,
    const std::filesystem::path& target) {
  std::error_code error;
  if (!std::filesystem::exists(source, error)) {
    return false;
  }
  DeleteIfExists(target);
  std::filesystem::create_directories(target.parent_path(), error);
  error.clear();
  std::filesystem::rename(source, target, error);
  if (!error) {
    return true;
  }
  error.clear();
  std::filesystem::copy(
      source,
      target,
      std::filesystem::copy_options::recursive |
          std::filesystem::copy_options::overwrite_existing,
      error);
  if (!error) {
    DeleteIfExists(source);
    return true;
  }
  return false;
}

void ActivatePendingHotUpdate() {
  const auto bundle_root = WritableHotUpdateBundleRoot();
  const auto current = bundle_root / L"current";
  std::error_code error;
  std::filesystem::create_directories(bundle_root, error);
  if (ReplaceDirectory(bundle_root / L"pending", current)) {
    if (!IsValidHotUpdateBundle(current)) {
      DeleteIfExists(current);
    }
    return;
  }
  if (ReplaceDirectory(LegacyHotUpdateRoot() / L"pending", current)) {
    if (!IsValidHotUpdateBundle(current)) {
      DeleteIfExists(current);
    }
    return;
  }
  if (!std::filesystem::exists(current, error)) {
    ReplaceDirectory(LegacyHotUpdateRoot() / L"current", current);
    if (!IsValidHotUpdateBundle(current)) {
      DeleteIfExists(current);
    }
  }
}

}  // namespace

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

std::wstring ResolveFlutterDataDirectory() {
  const auto data_directory = ExecutableDirectory() / L"data";
#ifdef _DEBUG
  return data_directory.wstring();
#else
  ActivatePendingHotUpdate();
  const auto writable_current = WritableHotUpdateBundleRoot() / L"current";
  std::error_code error;
  if (std::filesystem::exists(writable_current, error) &&
      !IsValidHotUpdateBundle(writable_current)) {
    DeleteIfExists(writable_current);
  }
  if (IsValidHotUpdateBundle(writable_current)) {
    return writable_current.wstring();
  }
  const auto legacy_current = LegacyHotUpdateRoot() / L"current";
  error.clear();
  if (std::filesystem::exists(legacy_current, error) &&
      !IsValidHotUpdateBundle(legacy_current)) {
    DeleteIfExists(legacy_current);
  }
  error.clear();
  if (std::filesystem::exists(legacy_current, error) &&
      IsValidHotUpdateBundle(legacy_current)) {
    return legacy_current.wstring();
  }
  return data_directory.wstring();
#endif
}

bool RelaunchCurrentExecutable() {
  const auto executable = ExecutablePath();
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info = {};
  std::wstring command = L"\"" + executable.wstring() + L"\"";
  const BOOL started = ::CreateProcessW(
      nullptr,
      command.data(),
      nullptr,
      nullptr,
      FALSE,
      0,
      nullptr,
      executable.parent_path().wstring().c_str(),
      &startup_info,
      &process_info);
  if (!started) {
    return false;
  }
  ::CloseHandle(process_info.hThread);
  ::CloseHandle(process_info.hProcess);
  return true;
}
