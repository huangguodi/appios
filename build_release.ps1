# ==============================================================================
# 🚀 Flutter Cross-Platform Release Build Script
# Automatically builds Android APK and Windows ZIP, then moves them to dist/
# ==============================================================================

# 设置控制台输出编码为 UTF-8，防止中文乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$distDir = "dist"
$javaCandidates = @(
    "C:\Program Files\Android\Android Studio\jbr",
    "C:\Program Files\Android\Android Studio\jre"
)

if (-not $env:JAVA_HOME) {
    $resolvedJavaHome = $javaCandidates | Where-Object { Test-Path (Join-Path $_ "bin\java.exe") } | Select-Object -First 1
    if ($resolvedJavaHome) {
        $env:JAVA_HOME = $resolvedJavaHome
    }
}

if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
    $env:Path = "$($env:JAVA_HOME)\bin;$env:Path"
}

# 1. Clean and Setup Dist Directory
Write-Host "🧹 正在清理..." -ForegroundColor Cyan
if (-not (Test-Path $distDir)) { 
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

# 2. Build Android APK
Write-Host "`n🤖 正在构建 Android Release APK..." -ForegroundColor Green
flutter build apk --release

$apkSource = "build\app\outputs\flutter-apk\app-release.apk"
if (Test-Path $apkSource) {
    Copy-Item $apkSource "$distDir\app-release.apk" -Force
    Write-Host "✅ Android APK 已复制到 $distDir\app-release.apk" -ForegroundColor Green
} else {
    Write-Error "❌ Android 构建失败: 未在 $apkSource 找到 APK"
}

# 3. Build Windows Release
Write-Host "正在构建 Windows Release..." -ForegroundColor Cyan
flutter build windows --release

# 4. Package Windows Artifacts
$winBuildDir = "build\windows\x64\runner\Release"
if (-not (Test-Path $winBuildDir)) {
    Write-Error "❌ Windows 构建失败: 未在 $winBuildDir 找到目录"
}

# Create ZIP
Write-Host "🤐 正在压缩 Windows 应用程序..." -ForegroundColor Cyan
$zipPath = "$distDir\windows-release.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# 创建临时目录结构以包含 Accelerator 文件夹
$tempDir = Join-Path $distDir "temp_pack"
$acceleratorDir = Join-Path $tempDir "Accelerator"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $acceleratorDir -Force | Out-Null

# 复制构建产物到 Accelerator 目录
Copy-Item "$winBuildDir\*" -Destination $acceleratorDir -Recurse -Force

# 等待一小段时间确保文件释放
Start-Sleep -Seconds 2

Compress-Archive -Path $acceleratorDir -DestinationPath $zipPath -Force

# 清理临时目录
Remove-Item $tempDir -Recurse -Force

Write-Host "✅ Windows 版本已打包至 $zipPath" -ForegroundColor Green

# Summary
Write-Host "`n🎉 构建完成！" -ForegroundColor Yellow
Write-Host "📂 构建产物已存放在 '$distDir' 文件夹中："
Write-Host "   - Android: $distDir\app-release.apk"
Write-Host "   - Windows: $distDir\windows-release.zip"
