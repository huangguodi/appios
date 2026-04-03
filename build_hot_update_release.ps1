[CmdletBinding()]
param(
    [ValidateSet("debug", "release")]
    [string]$AndroidBuildMode = "release"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$distDir = "dist"
$tempRoot = Join-Path $distDir "temp_hot_update"

function Reset-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function New-ZipFromDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )

    if (Test-Path $ZipPath) {
        Remove-Item -Path $ZipPath -Force
    }

    $resolvedSourceDir = (Resolve-Path $SourceDir).Path
    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    try {
        Get-ChildItem -Path $resolvedSourceDir -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($resolvedSourceDir.Length).TrimStart('\', '/')
            $entryName = $relativePath.Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $_.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Copy-ZipEntryToFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchiveEntry]$Entry,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $parentDir = Split-Path -Path $DestinationPath -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $entryStream = $Entry.Open()
    $fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

    try {
        $entryStream.CopyTo($fileStream)
    }
    finally {
        $fileStream.Dispose()
        $entryStream.Dispose()
    }
}

function Extract-AndroidHotUpdateFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApkPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDir
    )

    $resolvedApkPath = (Resolve-Path $ApkPath).Path
    $zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedApkPath)

    try {
        $libEntry = $zip.GetEntry("lib/arm64-v8a/libapp.so")
        if ($null -ne $libEntry) {
            Copy-ZipEntryToFile -Entry $libEntry -DestinationPath (Join-Path $DestinationDir "libapp.so")
        }
        else {
            Write-Host "Android APK 未包含 libapp.so，将继续仅导出资源文件" -ForegroundColor Yellow
        }

        $assetEntries = @($zip.Entries | Where-Object {
            $_.FullName.StartsWith("assets/flutter_assets/") -and
            -not [string]::IsNullOrEmpty($_.Name)
        })

        if ($assetEntries.Count -eq 0) {
            throw "Android 提取失败：未在 APK 中找到 assets/flutter_assets"
        }

        foreach ($entry in $assetEntries) {
            $relativePath = $entry.FullName.Substring("assets/".Length)
            $destinationPath = Join-Path $DestinationDir ($relativePath.Replace("/", "\"))
            Copy-ZipEntryToFile -Entry $entry -DestinationPath $destinationPath
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Export-AndroidHotUpdatePackage {
    if ($AndroidBuildMode -ne "release") {
        throw "Android 热更新仅支持 release 包，调试包已关闭热更新"
    }

    $buildLabel = $AndroidBuildMode.ToUpperInvariant()
    Write-Host "`n正在构建 Android $buildLabel APK..." -ForegroundColor Green
    flutter build apk --$AndroidBuildMode

    $apkSource = "build\app\outputs\flutter-apk\app-$AndroidBuildMode.apk"
    if (-not (Test-Path $apkSource)) {
        throw "Android 构建失败：未在 $apkSource 找到 APK"
    }

    $stagingDir = Join-Path $tempRoot "android"
    Reset-Directory -Path $stagingDir

    Extract-AndroidHotUpdateFiles -ApkPath $apkSource -DestinationDir $stagingDir

    $zipPath = Join-Path $distDir "android-hot-update.zip"
    New-ZipFromDirectory -SourceDir $stagingDir -ZipPath $zipPath
    Write-Host ("Android 热更新包已生成 [{0}]：{1}" -f $buildLabel, $zipPath) -ForegroundColor Green
}

function Export-WindowsHotUpdatePackage {
    Write-Host "`n正在构建 Windows Release..." -ForegroundColor Cyan
    flutter build windows --release

    $dataDir = "build\windows\x64\runner\Release\data"
    if (-not (Test-Path $dataDir)) {
        throw "Windows 构建失败：未在 $dataDir 找到 data 目录"
    }

    $binarySource = Join-Path $dataDir "app.so"
    $assetsSource = Join-Path $dataDir "flutter_assets"

    if (-not (Test-Path $binarySource)) {
        throw "Windows 提取失败：未在 data 目录中找到 app.so"
    }

    if (-not (Test-Path $assetsSource)) {
        throw "Windows 提取失败：未在 data 目录中找到 flutter_assets"
    }

    $stagingDir = Join-Path $tempRoot "windows"
    Reset-Directory -Path $stagingDir

    Copy-Item -Path $binarySource -Destination (Join-Path $stagingDir "app.so") -Force
    Copy-Item -Path $assetsSource -Destination (Join-Path $stagingDir "flutter_assets") -Recurse -Force

    $zipPath = Join-Path $distDir "windows-hot-update.zip"
    New-ZipFromDirectory -SourceDir $stagingDir -ZipPath $zipPath
    Write-Host ("Windows 热更新包已生成：{0}" -f $zipPath) -ForegroundColor Green
}

function Export-IOSHotUpdatePackage {
    if (-not $IsMacOS) {
        Write-Host "`n当前环境不是 macOS，跳过 iOS 热更新包构建" -ForegroundColor Yellow
        return
    }

    Write-Host "`n正在构建 iOS Release..." -ForegroundColor Magenta
    flutter build ios --release --no-codesign

    $appSource = "build\ios\iphoneos\Runner.app"
    if (-not (Test-Path $appSource)) {
        throw "iOS 构建失败：未在 $appSource 找到 Runner.app"
    }

    $binarySource = Join-Path $appSource "Frameworks\App.framework\App"
    $assetsSource = Join-Path $appSource "Frameworks\App.framework\flutter_assets"

    if (-not (Test-Path $binarySource)) {
        throw "iOS 提取失败：未在 Runner.app 中找到 Frameworks/App.framework/App"
    }

    if (-not (Test-Path $assetsSource)) {
        throw "iOS 提取失败：未在 Runner.app 中找到 Frameworks/App.framework/flutter_assets"
    }

    $stagingDir = Join-Path $tempRoot "ios"
    Reset-Directory -Path $stagingDir

    Copy-Item -Path $binarySource -Destination (Join-Path $stagingDir "App") -Force
    Copy-Item -Path $assetsSource -Destination (Join-Path $stagingDir "flutter_assets") -Recurse -Force

    $zipPath = Join-Path $distDir "ios-hot-update.zip"
    New-ZipFromDirectory -SourceDir $stagingDir -ZipPath $zipPath
    Write-Host ("iOS 热更新包已生成：{0}" -f $zipPath) -ForegroundColor Green
}

if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

try {
    Reset-Directory -Path $tempRoot

    Export-AndroidHotUpdatePackage
    Export-WindowsHotUpdatePackage
    Export-IOSHotUpdatePackage

    Write-Host "`n热更新包构建完成" -ForegroundColor Yellow
    Write-Host ("构建产物目录：{0}" -f $distDir)
    Write-Host ("Android：{0}\android-hot-update.zip" -f $distDir)
    Write-Host ("Windows：{0}\windows-hot-update.zip" -f $distDir)
    if ($IsMacOS) {
        Write-Host ("iOS：{0}\ios-hot-update.zip" -f $distDir)
    }
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}
