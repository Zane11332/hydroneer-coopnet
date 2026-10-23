# Hydroneer Co-op (CoopNet) installer. Adds UE4SS (experimental build) and the CoopNet mod to
# Hydroneer's Win64 folder, after backing up your saves. Undo with Uninstall.bat.
param(
    [string]$GameDir,     # Hydroneer install folder; found through Steam when empty
    [string]$SaveRoot,    # folder with SaveGames\ and Config\ (default %LOCALAPPDATA%\Mining\Saved)
    [switch]$Yes,         # do not ask questions (for scripted tests)
    [switch]$Detect,      # only report: GAME=<dir> and VERSION=match|mismatch, change nothing
    [switch]$NonInteractive   # never ask: on a version mismatch exit with code 3 (the launcher asks)
)
$ErrorActionPreference = "Stop"
$pkg = $PSScriptRoot
$testedExe = "DF27B86E4564100FA792464EA625F64C96C4D155C6C911486FE3769C8D5570B1"   # Steam build 23218978
$marker = "HydroneerCoop-installed.txt"

function Ask($q) {
    if ($Yes) { return $true }
    $a = Read-Host "$q (y/N)"
    return $a -match '^(y|yes)$'
}

function Find-GameDir {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $libs = @((Join-Path $steam "steamapps"))
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"(.+)"').Matches) {
            $libs += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps")
        }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $acf = Join-Path $lib "appmanifest_1106840.acf"
        if (Test-Path $acf) {
            $dir = (Select-String -Path $acf -Pattern '"installdir"\s+"(.+)"').Matches[0].Groups[1].Value
            return (Join-Path $lib "common\$dir")
        }
    }
    return $null
}

if (-not $GameDir) { $GameDir = Find-GameDir }
if (-not $GameDir) {
    if ($Detect) { "GAME="; "VERSION=missing"; "INSTALLED=no"; exit 0 }
    "Could not find Hydroneer through Steam. Run: powershell -File install.ps1 -GameDir `"<your Hydroneer folder>`""
    exit 1
}
$w64 = Join-Path $GameDir "Mining\Binaries\Win64"
$exe = Join-Path $w64 "Mining-Win64-Shipping.exe"
if (-not (Test-Path $exe)) {
    if ($Detect) { "GAME=$GameDir"; "VERSION=missing"; "INSTALLED=no"; exit 0 }
    "This does not look like a Hydroneer install (no $exe)."
    exit 1
}
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash
if ($Detect) {
    "GAME=$GameDir"; "VERSION=" + $(if ($hash -eq $testedExe) { "match" } else { "mismatch" })
    "INSTALLED=" + $(if (Test-Path (Join-Path $w64 "ue4ss\$marker")) { "yes" } else { "no" }); exit 0
}
"Hydroneer found: $GameDir"

if ($hash -ne $testedExe) {
    "WARNING: your Hydroneer version is not the one this was tested with (Steam build 23218978)."
    "It may still work, or it may crash at start. Both players need the same game version."
    if ($NonInteractive -and -not $Yes) { "VERSION_MISMATCH: nothing changed."; exit 3 }
    if (-not (Ask "Install anyway?")) { "Nothing changed."; exit 1 }
}

if (Test-Path (Join-Path $w64 "ue4ss\$marker")) { "Hydroneer Co-op is already installed in $w64. Nothing changed (use Uninstall first to reinstall)."; exit 1 }
foreach ($n in "dwmapi.dll", "ue4ss", "UE4SS.dll", "xinput1_3.dll") {
    if (Test-Path (Join-Path $w64 $n)) {
        "Another mod is already using $n in $w64."
        "This installer does not touch other mods. Remove that mod first, then run Install.bat again."
        "Nothing changed."
        exit 1
    }
}

# 1. back up saves and settings
if (-not $SaveRoot) { $SaveRoot = Join-Path $env:LOCALAPPDATA "Mining\Saved" }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $pkg "backups\Saved-$stamp"
New-Item -ItemType Directory -Force $bak | Out-Null
$copied = 0
foreach ($sub in "SaveGames", "Config") {
    $src = Join-Path $SaveRoot $sub
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $bak $sub) -Recurse
        $copied += (Get-ChildItem (Join-Path $bak $sub) -Recurse -File).Count
    }
}
"Backed up $copied save/settings files to $bak"

# 2. copy UE4SS and the mod
$files = Join-Path $pkg "files"
Copy-Item (Join-Path $files "dwmapi.dll") $w64
Copy-Item (Join-Path $files "ue4ss") (Join-Path $w64 "ue4ss") -Recurse

# 3. tell the mod where this package's run folder is (shared with Host.bat / Join.bat)
$run = Join-Path $pkg "run"
New-Item -ItemType Directory -Force $run | Out-Null
$cfg = Join-Path $w64 "ue4ss\Mods\CoopNet\Scripts\coopnet_config.lua"
Set-Content $cfg ("return { run_dir = `"" + ($run -replace '\\', '/') + "`" }") -Encoding ascii

# 4. record what we added, so Uninstall.bat removes exactly that
$added = @()
$added += [ordered]@{ path = "dwmapi.dll"; sha256 = (Get-FileHash (Join-Path $w64 "dwmapi.dll")).Hash }
Get-ChildItem (Join-Path $w64 "ue4ss") -Recurse -File | ForEach-Object {
    $added += [ordered]@{ path = $_.FullName.Substring($w64.Length + 1); sha256 = (Get-FileHash $_.FullName).Hash }
}
$manifest = [ordered]@{ game_dir = $GameDir; win64 = $w64; installed = $stamp; backup = $bak; files = $added }
$json = $manifest | ConvertTo-Json -Depth 4
$json | Set-Content (Join-Path $pkg "installed.json") -Encoding utf8
$json | Set-Content (Join-Path $w64 "ue4ss\HydroneerCoop-installed.json") -Encoding utf8   # so any package copy can uninstall
Set-Content (Join-Path $w64 "ue4ss\$marker") "Installed by Hydroneer Co-op from $pkg on $stamp" -Encoding utf8
"Installed $($added.Count) files into $w64"
""
"Done. Next: run Host.bat (the host) or Join.bat (the friend). See README.txt."
