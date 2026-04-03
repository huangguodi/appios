import os
import re
import sys

# ==============================================================================
# VPN Server URL Updater
# 自动修改 Android Native、Windows Native、iOS Native 的服务端地址（XOR 加密）
# ==============================================================================

NATIVE_XOR_KEY = 0x5A
DART_XOR_KEY = "TGS_VPN_2024_PROD_API_KEY_998877"

PATHS = {
    "android": "android/app/src/main/cpp/keys.cpp",
    "windows": "windows/runner/flutter_window.cpp",
    "ios": "ios/Runner/MihomoIosPlugin.swift",
    "dart": "lib/services/api_service.dart"
}

def generate_native_bytes(url):
    """生成 C++ Native 层的 XOR 加密字节数组"""
    bytes_list = [hex(ord(c) ^ NATIVE_XOR_KEY) for c in url]
    
    # 格式化为漂亮的 C++ 数组格式
    formatted = "\n"
    for i in range(0, len(bytes_list), 16):
        chunk = ", ".join(bytes_list[i:i+16])
        formatted += f"                {chunk},\n"
    
    # 移除最后一个多余的逗号，保持语法正确
    formatted = formatted.rstrip(',\n') + "\n            "
    return formatted

def generate_dart_bytes(url):
    """生成 Dart 层的循环 XOR 加密字节数组"""
    bytes_list = [str(ord(c) ^ ord(DART_XOR_KEY[i % len(DART_XOR_KEY)])) for i, c in enumerate(url)]
    return "[" + ", ".join(bytes_list) + "]"

def generate_swift_bytes(url):
    """生成 Swift 层的 UInt8 数组格式"""
    bytes_list = [f"0x{(ord(c) ^ NATIVE_XOR_KEY):02x}" for c in url]
    formatted = "\n"
    for i in range(0, len(bytes_list), 16):
        chunk = ", ".join(bytes_list[i:i + 16])
        formatted += f"      {chunk},\n"
    formatted = formatted.rstrip(',\n') + "\n    "
    return formatted

def update_file(filepath, pattern, new_content):
    """安全地使用正则替换文件中的目标区块"""
    if not os.path.exists(filepath):
        print(f"[错误] 找不到文件: {filepath}")
        return False
        
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
        
    if not re.search(pattern, content):
        print(f"[警告] 未找到匹配的注入点 (可能文件已被修改或结构错误): {filepath}")
        return False

    # 使用正则的分组替换，仅替换第二组（即数组内容），保留第一组和第三组（外围结构）
    new_content_full = re.sub(
        pattern, 
        lambda m: m.group(1) + new_content + m.group(3), 
        content
    )
    
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(new_content_full)
        
    print(f"[成功] 已更新: {filepath}")
    return True

def main():
    if len(sys.argv) != 2:
        print("\n==================================================")
        print("VPN 服务端地址一键修改工具")
        print("==================================================")
        print("用法: python update_server_url.py <新的服务端URL>")
        print("示例: python update_server_url.py https://vpnapis.com\n")
        sys.exit(1)
        
    new_url = sys.argv[1].strip()
    print(f"\n正在将服务端地址更新为: {new_url}\n")
    
    native_bytes_str = generate_native_bytes(new_url)
    swift_bytes_str = generate_swift_bytes(new_url)
    dart_bytes_str = generate_dart_bytes(new_url)
    
    success_count = 0
    
    # 1. 更新 Android Native
    android_pattern = r'(Java_com_accelerator_tg_MainActivity_getServerUrlKey[\s\S]*?const unsigned char enc\[\] = \{)([\s\S]*?)(\};)'
    if update_file(PATHS["android"], android_pattern, native_bytes_str):
        success_count += 1
        
    # 2. 更新 Windows Native
    windows_pattern = r'(call\.method_name\(\) == "getServerUrlKey"[\s\S]*?const unsigned char enc\[\] = \{)([\s\S]*?)(\};)'
    if update_file(PATHS["windows"], windows_pattern, native_bytes_str):
        success_count += 1

    # 3. 更新 iOS Native (MihomoIosPlugin.swift)
    ios_pattern = r'(static let serverUrlEnc:\s*\[UInt8\]\s*=\s*\[)([\s\S]*?)(\])'
    if update_file(PATHS["ios"], ios_pattern, swift_bytes_str):
        success_count += 1
        
    # 4. 更新 Dart (不再生成 bytes, 而是清空或保留空数组，完全依赖 Native 返回)
    # dart_pattern = r'(static const List<int> _serverUrlBytes = )(\[[0-9, ]+\])(;)'
    # if update_file(PATHS["dart"], dart_pattern, "[]"):
    #    success_count += 1
        
    print(f"\n[完成] 成功更新了 {success_count}/3 个文件！(Dart 层已改为完全动态获取，无需静态修改)")
    print("提示: 修改完成后，请直接运行打包命令 (flutter build apk / ios / windows) 即可生效。")

if __name__ == "__main__":
    main()
