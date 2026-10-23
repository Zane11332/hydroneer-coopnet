# Builds dist\HydroneerCoop-<version> (+ .zip) for players. The three third-party inputs are the
# exact official downloads below; each is checked against its pinned hash before use.
#
#   powershell -ExecutionPolicy Bypass -File build\build-package.ps1 `
#       -Ue4ssZip <UE4SS_v3.0.1-1181-g83330635.zip> `
#       -SteamworksZip <Steamworks.NET-Standalone_2025.164.1.zip> `
#       -PythonNupkg <python.3.12.10.nupkg>
#
# Downloads (official sources):
#   UE4SS experimental-latest:  https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest
#   Steamworks.NET 2025.164.1:  https://github.com/rlabrecque/Steamworks.NET/releases/tag/2025.164.1
#   Python 3.12.10 (NuGet):     https://www.nuget.org/packages/python/3.12.10
param(
    [Parameter(Mandatory = $true)][string]$Ue4ssZip,
    [Parameter(Mandatory = $true)][string]$SteamworksZip,
    [Parameter(Mandatory = $true)][string]$PythonNupkg,
    [string]$Version,
    [string]$OutDir
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $Version) { $Version = (Get-Content (Join-Path $root "VERSION") -Raw).Trim() }
if (-not $OutDir) { $OutDir = Join-Path $root "dist" }
$out = Join-Path $OutDir "HydroneerCoop-$Version"

# inputs must be the files we verified
$pins = @(
    @{ f = $Ue4ssZip;      alg = "SHA256"; h = "B9A166A756605B21058A64CDE93BCAAB1A855DBA3553E5C7E6CE0FA8FDFAD7B9" },
    @{ f = $SteamworksZip; alg = "SHA256"; h = "9412348CC404563BE5A43A28347CFEDA3C679EE044A14D87A507ED2D796A537D" },
    @{ f = $PythonNupkg;   alg = "SHA512"; h = "BBDA4DCF688A94211B62D50968A91B38F305D0B8D1ECD90269F74A86F8A0A4FCEBB7CA162A0753A47691EB3DF0C964009BD3D8194C6FD19AFAE8D5FD01E1CC0F" }
)
foreach ($p in $pins) {
    if ((Get-FileHash $p.f -Algorithm $p.alg).Hash -ne $p.h) { throw "pin mismatch ($($p.alg)): $($p.f)" }
}

# unpack into a fresh work folder next to the output
$work = Join-Path $OutDir "work"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory $work | Out-Null
$ue = Join-Path $work "ue4ss"; $sw = Join-Path $work "steamworks"; $pyx = Join-Path $work "python"
Expand-Archive -LiteralPath $Ue4ssZip -DestinationPath $ue
Expand-Archive -LiteralPath $SteamworksZip -DestinationPath $sw
Copy-Item $PythonNupkg (Join-Path $work "python.zip")
Expand-Archive -LiteralPath (Join-Path $work "python.zip") -DestinationPath $pyx
$py = Join-Path $pyx "tools"
$steamDll = Join-Path $sw "Windows-x64\steam_api64.dll"
if ((Get-FileHash $steamDll).Hash -ne "EB17909A76668CF9AE0B92A618A34A50F6C73D3A6787CB4DD8CE36A8B10BFB75") { throw "unexpected steam_api64.dll" }

# never wipe a folder someone installed from (its backups\ and records would be lost)
foreach ($f in "installed.json", "installed-linux.txt", "backups") {
    if (Test-Path (Join-Path $out $f)) { throw "$out\$f exists: someone installed from this build. Uninstall first or move it." }
}
# empty the folder rather than delete it (an open launcher window keeps the folder itself in use)
New-Item -ItemType Directory $out -Force | Out-Null
Get-ChildItem $out -Force | Remove-Item -Recurse -Force

$pkg = Join-Path $root "package"
foreach ($f in "README.txt", "Start Hydroneer Co-op.bat", "launcher.ps1", "hydroneer-coop.sh",
               "Install.bat", "Uninstall.bat", "Host.bat", "Join.bat", "install.ps1", "uninstall.ps1",
               "install.sh", "uninstall.sh", "host.sh", "join.sh") {
    Copy-Item -LiteralPath (Join-Path $pkg $f) (Join-Path $out $f)
}
# Linux scripts must keep LF line endings
foreach ($f in "install.sh", "uninstall.sh", "host.sh", "join.sh", "hydroneer-coop.sh") {
    if ((Get-Content (Join-Path $out $f) -Raw) -match "`r") { throw "$f has CRLF line endings" }
}

# files\ = what goes into the game's Win64 folder: dwmapi.dll + ue4ss\ with only the CoopNet mod
New-Item -ItemType Directory "$out\files\ue4ss\Mods" -Force | Out-Null
Copy-Item "$ue\dwmapi.dll" "$out\files\"
foreach ($f in "UE4SS.dll", "UE4SS-settings.ini") { Copy-Item "$ue\ue4ss\$f" "$out\files\ue4ss\" }
Copy-Item (Join-Path $root "mod\CoopNet") "$out\files\ue4ss\Mods\CoopNet" -Recurse
Set-Content "$out\files\ue4ss\Mods\mods.txt" "CoopNet : 1" -Encoding ascii
Set-Content "$out\files\ue4ss\Mods\mods.json" '[ { "mod_name": "CoopNet", "mod_enabled": true } ]' -Encoding ascii

# relay\ = relay script + Steamworks.NET's steam_api64.dll (the game's own 1.47 copy lacks the flat API)
New-Item -ItemType Directory "$out\relay" | Out-Null
Copy-Item (Join-Path $root "relay\coopnet_relay.py") "$out\relay\"
Copy-Item $steamDll "$out\relay\"
Copy-Item "$sw\OSX-Linux-x64\libsteam_api.so" "$out\relay\"      # Linux (same verified release zip)

# python\ = Python 3.12.10 from NuGet, without parts the relay never uses
Copy-Item $py "$out\python" -Recurse
foreach ($d in "Lib\test", "Lib\idlelib", "Lib\tkinter", "Lib\turtledemo", "Lib\ensurepip", "Lib\lib2to3",
               "Lib\pydoc_data", "Lib\site-packages", "include", "libs", "DLLs\tcl86t.dll", "DLLs\tk86t.dll", "DLLs\_tkinter.pyd") {
    if (Test-Path "$out\python\$d") { Remove-Item "$out\python\$d" -Recurse -Force }
}
Get-ChildItem "$out\python" -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force

# licenses
New-Item -ItemType Directory "$out\licenses" | Out-Null
Copy-Item (Join-Path $root "LICENSE") "$out\licenses\HydroneerCoop-LICENSE.txt"
Copy-Item "$ue\ue4ss\LICENSE" "$out\licenses\UE4SS-LICENSE.txt"
Copy-Item "$sw\LICENSE.txt" "$out\licenses\Steamworks.NET-LICENSE.txt"
Copy-Item "$py\LICENSE.txt" "$out\licenses\Python-LICENSE.txt"
Remove-Item $work -Recurse -Force

# zip
$zip = "$out.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$out\*" -DestinationPath $zip
"built $out"
"{0:N1} MB unpacked, zip {1:N1} MB" -f ((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), ((Get-Item $zip).Length / 1MB)
"zip SHA-256 " + (Get-FileHash $zip).Hash
