# Hydroneer Co-op launcher window: install, uninstall, host, join, stop, logs. Started by
# "Start Hydroneer Co-op.bat". The separate .bat files still work on their own.
param(
    [string]$GameDir, [string]$SaveRoot,          # passed to install.ps1 (tests; normally found through Steam)
    [string]$Transport = "steam",                 # tests: mocksteam
    [string]$RelayExtra = "",                     # tests: "--mock-id 1 --mock-dir C:\..." (split on spaces)
    [ValidateSet("", "host", "join")][string]$SelfTest = "",   # tests: click through by itself
    [string]$ShotDir                              # tests: save pictures of the window here
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$pkg = $PSScriptRoot
$run = Join-Path $pkg "run"
$logs = Join-Path $pkg "logs"
$stopFile = Join-Path $run "stop.txt"
New-Item -ItemType Directory -Force $run, $logs | Out-Null
$script:relay = $null
$script:relayLog = $null
$script:logPos = 0
$script:selfLog = Join-Path $logs "launcher-selftest.txt"

# ---------------------------------------------------------------- window
$form = New-Object Windows.Forms.Form
$form.Text = "Hydroneer Co-op 0.2"
$form.Size = New-Object Drawing.Size(720, 560)
$form.MinimumSize = New-Object Drawing.Size(640, 480)
$form.StartPosition = "CenterScreen"
$font = New-Object Drawing.Font("Segoe UI", 10)
$form.Font = $font

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(12, 10)
$status.Size = New-Object Drawing.Size(680, 66)
$status.Anchor = "Top,Left,Right"
$form.Controls.Add($status)

function New-Button($text, $x, $y, $w = 120) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, 34)
    $form.Controls.Add($b)
    $b
}
$bInstall = New-Button "Install" 12 82
$bUninstall = New-Button "Uninstall" 138 82
$bReadme = New-Button "Read me" 444 82 120
$bLogs = New-Button "Open logs" 570 82 120
$bHost = New-Button "Host" 12 124
$bJoin = New-Button "Join" 138 124
$bStop = New-Button "Stop" 264 124
$lobbyLabel = New-Object Windows.Forms.Label
$lobbyLabel.Text = "Lobby (optional):"
$lobbyLabel.Location = New-Object Drawing.Point(396, 132)
$lobbyLabel.AutoSize = $true
$form.Controls.Add($lobbyLabel)
$lobbyBox = New-Object Windows.Forms.TextBox
$lobbyBox.Location = New-Object Drawing.Point(520, 128)
$lobbyBox.Size = New-Object Drawing.Size(170, 26)
$form.Controls.Add($lobbyBox)

$out = New-Object Windows.Forms.TextBox
$out.Multiline = $true
$out.ReadOnly = $true
$out.ScrollBars = "Vertical"
$out.Font = New-Object Drawing.Font("Consolas", 9)
$out.Location = New-Object Drawing.Point(12, 170)
$out.Size = New-Object Drawing.Size(680, 340)
$out.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($out)

function Say($text) {
    foreach ($l in ($text -split "`r?`n")) { if ($l -ne "") { $out.AppendText($l + [Environment]::NewLine) } }
}

# ---------------------------------------------------------------- state
function Installed { $script:detect -and $script:detect["INSTALLED"] -eq "yes" }   # the game folder decides
function RelayRunning { $script:relay -and -not $script:relay.HasExited }

function Run-Ps($file, [string[]]$extra) {
    # run install.ps1 / uninstall.ps1 and return @(exitcode, output)
    $pa = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $pkg $file)`"") + $extra
    $psi = New-Object Diagnostics.ProcessStartInfo("powershell.exe", ($pa -join " "))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @($p.ExitCode, $o)
}

function Test-Args {
    $a = @()
    if ($GameDir) { $a += @("-GameDir", "`"$GameDir`"") }
    if ($SaveRoot) { $a += @("-SaveRoot", "`"$SaveRoot`"") }
    $a
}

$script:detect = $null
function Refresh {
    if (-not $script:detect) {
        $r = Run-Ps "install.ps1" (@("-Detect") + (Test-Args))
        $script:detect = @{}
        foreach ($l in ($r[1] -split "`r?`n")) { if ($l -match '^(GAME|VERSION|INSTALLED)=(.*)$') { $script:detect[$Matches[1]] = $Matches[2] } }
    }
    $g = $script:detect["GAME"]; $v = $script:detect["VERSION"]
    $gameLine = if ($g) { "Hydroneer: $g" } else { "Hydroneer: not found through Steam" }
    $verLine = switch ($v) { "match" { "Game version: the tested one (Steam build 23218978)" }
                             "mismatch" { "Game version: DIFFERENT from the tested one (may not work; both players need the same)" }
                             default { "Game version: unknown" } }
    $inst = if (Installed) { "Co-op: installed" } else { "Co-op: not installed" }
    $rel = if (RelayRunning) { " | connection running: keep this window open while you play" } else { "" }
    $status.Text = "$gameLine`n$verLine`n$inst$rel"
    $i = Installed; $r = RelayRunning
    $bInstall.Enabled = (-not $i) -and $g
    $bUninstall.Enabled = $i -and -not $r
    $bHost.Enabled = $i -and -not $r
    $bJoin.Enabled = $i -and -not $r
    $bStop.Enabled = $r
    $lobbyBox.Enabled = -not $r
}

# ---------------------------------------------------------------- actions
function Do-Install {
    Say "Installing ..."
    $form.Cursor = "WaitCursor"
    $r = Run-Ps "install.ps1" (@("-NonInteractive") + (Test-Args))
    if ($r[0] -eq 3) {
        Say $r[1]
        $ans = if ($SelfTest) { "Yes" } else {
            [Windows.Forms.MessageBox]::Show("Your Hydroneer version is not the one this was tested with. It may crash at start, and both players need the same version.`n`nInstall anyway?", "Different game version", "YesNo", "Warning") }
        if ("$ans" -ne "Yes") { $form.Cursor = "Default"; Say "Nothing changed."; Refresh; return }
        $r = Run-Ps "install.ps1" (@("-NonInteractive", "-Yes") + (Test-Args))
    }
    $form.Cursor = "Default"
    Say $r[1]
    if ($r[0] -eq 0) { Say "Installed. Next: Host (one of you) or Join (the other)." } else { Say "Install did not complete (code $($r[0]))." }
    $script:detect = $null; Refresh
}

function Do-Uninstall {
    if (-not $SelfTest) {
        $ans = [Windows.Forms.MessageBox]::Show("Remove Hydroneer Co-op from the game folder? Your save backups stay in the backups folder.", "Uninstall", "YesNo", "Question")
        if ("$ans" -ne "Yes") { return }
    }
    $r = Run-Ps "uninstall.ps1" (@("-Yes") + (Test-Args))
    Say $r[1]
    $script:detect = $null; Refresh
}

function Start-Relay($role) {
    $script:relayLog = Join-Path $logs "relay-$role.log"
    if (Test-Path $script:relayLog) { $script:logPos = (Get-Item $script:relayLog).Length } else { $script:logPos = 0 }
    if (Test-Path $stopFile) { Remove-Item $stopFile }
    $r = if ($role -eq "host") { "host" } else { "client" }
    $a = @("-I", "-u", "coopnet_relay.py", "--role", $r, "--transport", $Transport, "--run-dir", "`"$run`"",
           "--log", "`"$($script:relayLog)`"", "--stop-file", "`"$stopFile`"")
    if ($RelayExtra.Trim()) { $a += ($RelayExtra.Trim() -split '\s+') }
    if ($role -eq "join" -and $lobbyBox.Text.Trim() -match '^\d+$') { $a += @("--lobby", $lobbyBox.Text.Trim()) }
    $psi = New-Object Diagnostics.ProcessStartInfo((Join-Path $pkg "python\python.exe"), ($a -join " "))
    $psi.WorkingDirectory = Join-Path $pkg "relay"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    # errors before the relay opens its log (bad arguments, Python itself) only reach stderr
    $psi.RedirectStandardError = $true
    $script:relay = [Diagnostics.Process]::Start($psi)
    Say "Starting the connection as $role ..."
    if ($role -eq "host") { Say "When it says the lobby is ready: start Hydroneer, start a NEW game, press F7 in the world." }
    else { Say "When it says connected: start Hydroneer, start a NEW game, press F7 in the world." }
    Refresh
}

function Stop-Relay {
    if (-not (RelayRunning)) { return }
    Say "Stopping the connection ..."
    Set-Content $stopFile "stop"
    if (-not $script:relay.WaitForExit(4000)) { $script:relay.Kill(); Say "(it did not stop by itself; closed it)" }
    Tail
    $script:wasRunning = $false
    Say "The connection stopped (exit code $($script:relay.ExitCode))."
    Refresh
}

function Tail {
    if (-not $script:relayLog -or -not (Test-Path $script:relayLog)) { return }
    $fs = [IO.File]::Open($script:relayLog, "Open", "Read", "ReadWrite")
    try {
        if ($fs.Length -lt $script:logPos) { $script:logPos = 0 }
        $fs.Seek($script:logPos, "Begin") | Out-Null
        $rd = New-Object IO.StreamReader($fs)
        $new = $rd.ReadToEnd()
        $script:logPos = $fs.Length
        if ($new) { Say $new }
    } finally { $fs.Close() }
}

$bInstall.Add_Click({ Do-Install })
$bUninstall.Add_Click({ Do-Uninstall })
$bHost.Add_Click({ Start-Relay "host" })
$bJoin.Add_Click({ Start-Relay "join" })
$bStop.Add_Click({ Stop-Relay })
$bLogs.Add_Click({ Start-Process explorer.exe $logs })
$bReadme.Add_Click({ Start-Process notepad.exe (Join-Path $pkg "README.txt") })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$script:wasRunning = $false
$timer.Add_Tick({
    Tail
    $r = RelayRunning
    if ($script:wasRunning -and -not $r) {
        Tail
        $err = $script:relay.StandardError.ReadToEnd().Trim()
        if ($err) { Say "Error output:"; Say $err }
        Say "The connection stopped (exit code $($script:relay.ExitCode))."
        Refresh
    }
    $script:wasRunning = $r
})
$form.Add_Shown({ Refresh; $timer.Start(); if ($SelfTest) { Start-SelfTest } })
$form.Add_FormClosing({ Stop-Relay })

# ---------------------------------------------------------------- self-test (scripted clicks)
function Shot($name) {
    if (-not $ShotDir) { return }
    New-Item -ItemType Directory -Force $ShotDir | Out-Null
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save((Join-Path $ShotDir "$SelfTest-$name.png"))
    $bmp.Dispose()
}
function ST($msg) { Add-Content $script:selfLog "$(Get-Date -Format HH:mm:ss) [$SelfTest] $msg" }
$script:steps = $null
$script:stepAt = $null
function Start-SelfTest {
    Remove-Item $script:selfLog -ErrorAction SilentlyContinue
    $role = $SelfTest
    $script:steps = [Collections.Generic.Queue[object]]::new()
    $script:steps.Enqueue(@{ name = "start"; act = { Shot "1-start"; ST "status: $($status.Text -replace "`n", ' / ')"; ST "buttons: install=$($bInstall.Enabled) host=$($bHost.Enabled)" } })
    $script:steps.Enqueue(@{ name = "install"; act = { $bInstall.PerformClick(); ST "installed: $(Installed)" } })
    # step blocks run later from a timer: use the script parameter $SelfTest, not a local variable
    $script:steps.Enqueue(@{ name = "connect"; act = { if ($SelfTest -eq "host") { $bHost.PerformClick() } else { $bJoin.PerformClick() }; ST "clicked $(if ($SelfTest -eq 'host') { 'Host' } else { 'Join' }); relay running: $(RelayRunning)" } })
    $script:steps.Enqueue(@{ name = "wait-connected"; wait = { $out.Text -match 'STATUS: connected' }; timeout = 60 })
    $script:steps.Enqueue(@{ name = "connected"; act = { Shot "2-connected"; ST "log shows connected: $($out.Text -match 'STATUS: connected'); stop enabled=$($bStop.Enabled) uninstall enabled=$($bUninstall.Enabled)" } })
    $script:steps.Enqueue(@{ name = "hold"; wait = { $false }; timeout = 6 })
    $script:steps.Enqueue(@{ name = "stop"; act = { $bStop.PerformClick(); ST "relay running after stop: $(RelayRunning); exit code $($script:relay.ExitCode); log has 'stop requested': $($out.Text -match 'stop requested'); 'relay stopped': $($out.Text -match 'relay stopped')" } })
    $script:steps.Enqueue(@{ name = "uninstall"; act = { $bUninstall.PerformClick(); ST "installed after uninstall: $(Installed)"; Shot "3-uninstalled" } })
    $script:steps.Enqueue(@{ name = "close"; act = { ST "done"; $form.Close() } })
    $st = New-Object Windows.Forms.Timer
    $st.Interval = 500
    $st.Add_Tick({
        if ($script:steps.Count -eq 0) { return }
        $s = $script:steps.Peek()
        if ($s.wait) {
            if (-not $script:stepAt) { $script:stepAt = Get-Date }
            $waited = ((Get-Date) - $script:stepAt).TotalSeconds
            if (-not (& $s.wait) -and $waited -lt $s.timeout) { return }
            if ($s.name -ne "hold") { ST "$($s.name): $(if ($waited -lt $s.timeout) { 'ok' } else { 'TIMEOUT' }) after $([int]$waited) s" }
            $script:stepAt = $null
            $script:steps.Dequeue() | Out-Null
            return
        }
        $script:steps.Dequeue() | Out-Null
        try { & $s.act } catch { ST "$($s.name) FAILED: $_" }
    })
    $st.Start()
}

[void]$form.ShowDialog()
