# Hydroneer Co-op uninstaller: removes what install.ps1 added (dwmapi.dll and the ue4ss folder it
# created). Works from any copy of this package: it finds the game through Steam when this folder
# has no installed.json. Your save backups stay in this package's backups\ folder.
param(
    [string]$GameDir,     # Hydroneer install folder; found through Steam when empty
    [string]$SaveRoot,    # accepted for symmetry with install.ps1; not used
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
$pkg = $PSScriptRoot
$marker = "HydroneerCoop-installed.txt"
$mf = Join-Path $pkg "installed.json"

# where is the game? this folder's record first, else the same search install.ps1 uses
$w64 = $null
if (Test-Path $mf) { $w64 = (Get-Content $mf -Raw | ConvertFrom-Json).win64 }
if (-not $w64 -or -not (Test-Path (Join-Path $w64 "ue4ss\$marker"))) {
    $da = @{ Detect = $true }; if ($GameDir) { $da.GameDir = $GameDir }
    $g = (& (Join-Path $pkg "install.ps1") @da | Where-Object { $_ -match '^GAME=' }) -replace '^GAME=', ''
    if ($g) { $w64 = Join-Path $g "Mining\Binaries\Win64" }
}
if (-not $w64) { "Could not find Hydroneer through Steam. Run: powershell -File uninstall.ps1 -GameDir `"<your Hydroneer folder>`""; exit 1 }
$ue = Join-Path $w64 "ue4ss"
if (-not (Test-Path (Join-Path $ue $marker))) {
    if (Test-Path $ue) { "The ue4ss folder in $w64 was not installed by Hydroneer Co-op. Not touching it." }
    else { "Hydroneer Co-op is not installed in $w64. Nothing to remove." }
    if (Test-Path $mf) { Remove-Item $mf }
    exit 1
}

# what did we install? this folder's record, else the copy kept in the game's ue4ss folder,
# else (installs from before that copy existed) the dwmapi.dll this package ships
$want = $null
foreach ($m in $mf, (Join-Path $ue "HydroneerCoop-installed.json")) {
    if (Test-Path $m) { $want = ((Get-Content $m -Raw | ConvertFrom-Json).files | Where-Object { $_.path -eq "dwmapi.dll" }).sha256; break }
}
if (-not $want) { $want = (Get-FileHash (Join-Path $pkg "files\dwmapi.dll")).Hash }

# dwmapi.dll: only if it is still the file we installed
$dw = Join-Path $w64 "dwmapi.dll"
if (Test-Path $dw) {
    if ((Get-FileHash $dw).Hash -eq $want) { Remove-Item $dw; "removed dwmapi.dll" }
    else { "dwmapi.dll was changed since install (another mod?). Left in place." }
}
# the ue4ss folder is ours (marker): it also holds logs and caches written while playing
Remove-Item $ue -Recurse -Force
"removed $ue"
if (Test-Path $mf) { Remove-Item $mf }
"Uninstalled. Save backups are still in $(Join-Path $pkg 'backups')."
