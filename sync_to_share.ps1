param(
    [switch]$NoCompress = $false
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$shareFolder = Join-Path $projectRoot "应用分享"
$archivePath = Join-Path $projectRoot "应用分享.zip"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  QNote Flutter 源代码归纳脚本" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (Test-Path $shareFolder) {
    Write-Host "[清理] 删除旧的分享文件夹..." -ForegroundColor Yellow
    Remove-Item -Path $shareFolder -Recurse -Force
}

Write-Host "[创建] 创建分享文件夹..." -ForegroundColor Green
New-Item -ItemType Directory -Path $shareFolder -Force | Out-Null

$includeItems = @(
    "lib",
    "assets", 
    "web",
    "pubspec.yaml",
    "pubspec.lock",
    "analysis_options.yaml",
    "README.md",
    "AGENTS.md",
    ".gitignore",
    ".metadata"
)

Write-Host ""
Write-Host "[复制] 复制源代码文件..." -ForegroundColor Green

foreach ($item in $includeItems) {
    $sourcePath = Join-Path $projectRoot $item
    $destPath = Join-Path $shareFolder $item
    
    if (Test-Path $sourcePath) {
        if (Test-Path $sourcePath -PathType Container) {
            Write-Host "  - 复制文件夹: $item" -ForegroundColor Gray
            Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
        } else {
            Write-Host "  - 复制文件: $item" -ForegroundColor Gray
            Copy-Item -Path $sourcePath -Destination $destPath -Force
        }
    } else {
        Write-Host "  - 跳过 (不存在): $item" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "[统计] 计算文件统计..." -ForegroundColor Green

$dartFiles = Get-ChildItem -Path (Join-Path $shareFolder "lib") -Filter "*.dart" -Recurse -ErrorAction SilentlyContinue
$totalFiles = Get-ChildItem -Path $shareFolder -Recurse -File -ErrorAction SilentlyContinue

$dartCount = if ($dartFiles) { $dartFiles.Count } else { 0 }
$fileCount = if ($totalFiles) { $totalFiles.Count } else { 0 }

$folderSize = (Get-ChildItem -Path $shareFolder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$sizeMB = [math]::Round($folderSize / 1MB, 2)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  归纳完成!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Dart 文件数: $dartCount" -ForegroundColor White
Write-Host "  总文件数:    $fileCount" -ForegroundColor White
Write-Host "  文件夹大小:  ${sizeMB} MB" -ForegroundColor White
Write-Host "  输出位置:    $shareFolder" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

if (-not $NoCompress) {
    Write-Host ""
    Write-Host "[压缩] 打包为 zip 压缩包..." -ForegroundColor Green
    
    if (Test-Path $archivePath) {
        Remove-Item -Path $archivePath -Force
    }
    
    Start-Sleep -Milliseconds 500
    
    Add-Type -AssemblyName "System.IO.Compression.FileSystem"
    
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($archivePath, "Create")
        
        Get-ChildItem -Path $shareFolder -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($shareFolder.Length + 1)
            $entry = $archive.CreateEntry($relativePath)
            $writer = $entry.Open()
            $reader = [System.IO.File]::OpenRead($_.FullName)
            $reader.CopyTo($writer)
            $reader.Close()
            $writer.Close()
        }
        
        $archive.Dispose()
        
        $archiveSize = (Get-Item $archivePath).Length
        $archiveMB = [math]::Round($archiveSize / 1MB, 2)
        Write-Host "  压缩包大小: ${archiveMB} MB" -ForegroundColor White
        Write-Host "  输出位置:    $archivePath" -ForegroundColor White
    } catch {
        Write-Host "  [错误] 压缩失败: $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "完成!" -ForegroundColor Green
