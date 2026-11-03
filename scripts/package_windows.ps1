$ErrorActionPreference = "Stop"

$AppName = "Oh-Mini-Mineral"
$Version = if ($args.Count -ge 1) { $args[0] } else { "0.1.0" }
$RootDir = Split-Path -Parent $PSScriptRoot
$BinDir  = Join-Path $RootDir "bin"
$DistDir = Join-Path $RootDir "dist"
$StageDir = Join-Path $DistDir "win_stage\$AppName"
$ZipPath  = Join-Path $DistDir "$AppName-$Version-win64.zip"

Write-Host "=== Packaging $AppName v$Version for Windows x64 ==="

if (Test-Path (Join-Path $DistDir "win_stage")) {
    Remove-Item -Recurse -Force (Join-Path $DistDir "win_stage")
}
if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}

New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $StageDir "codecs") | Out-Null
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

Copy-Item -Force (Join-Path $BinDir "omm_gui.exe") (Join-Path $StageDir "omm_gui.exe")
Copy-Item -Force (Join-Path $BinDir "omm_gui.exe") (Join-Path $StageDir "Oh-Mini-Mineral.exe")
Copy-Item -Force (Join-Path $BinDir "omm_daemon.exe") (Join-Path $StageDir "omm_daemon.exe")
Copy-Item -Force (Join-Path $BinDir "omm_tui.exe") (Join-Path $StageDir "omm_tui.exe")

if (Test-Path (Join-Path $BinDir "libomm_mineral.dll")) {
    Copy-Item -Force (Join-Path $BinDir "libomm_mineral.dll") (Join-Path $StageDir "libomm_mineral.dll")
}
if (Test-Path (Join-Path $BinDir "omm_mineral.dll")) {
    Copy-Item -Force (Join-Path $BinDir "omm_mineral.dll") (Join-Path $StageDir "omm_mineral.dll")
}

Get-ChildItem -Path (Join-Path $BinDir "codecs") -Filter "libcodec_*.dll" | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $StageDir "codecs\$($_.Name)")
}

$ReadmeMini = Join-Path $RootDir "README_MINI.md"
$ReadmeStd  = Join-Path $RootDir "README.md"
if (Test-Path $ReadmeMini) {
    Copy-Item -Force $ReadmeMini (Join-Path $StageDir "README.md")
} elseif (Test-Path $ReadmeStd) {
    Copy-Item -Force $ReadmeStd (Join-Path $StageDir "README.md")
}

Compress-Archive -Path $StageDir -DestinationPath $ZipPath -Force
Remove-Item -Recurse -Force (Join-Path $DistDir "win_stage")

Get-Item $ZipPath | Format-Table Name, Length, FullName
Write-Host "=== Windows Zip created at $ZipPath ==="
