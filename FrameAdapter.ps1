[CmdletBinding()]
param(
    [ValidateSet('UI', 'Inspect', 'Recover')][string]$Action = 'UI',
    [string]$ResultPath,
    [string]$PreviewPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolPath = $PSCommandPath
$script:AdapterDescription = 'Realtek 8832CU Wireless LAN WiFi 6 USB NIC For Valve'
$script:StateDirectory = Join-Path $env:LOCALAPPDATA 'FrameAdapter\recovery'
$script:NewLine = [Environment]::NewLine
$script:RecoveryMutexName = 'Local\SteamFrameAdapterRecovery'

function Get-FrameAdapter {
    $matches = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop |
        Where-Object { $_.InterfaceDescription -eq $script:AdapterDescription })
    if ($matches.Count -ne 1) {
        throw "Found $($matches.Count) supported adapters; expected one. Check the USB connection."
    }
    $adapter = $matches[0]
    $devices = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop |
        Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex })
    if ($devices.Count -ne 1 -or $devices[0].PNPDeviceID -notlike 'USB\VID_28DE&PID_2432\*') {
        throw 'Adapter hardware ID does not match USB VID_28DE/PID_2432.'
    }
    return [pscustomobject]@{ Adapter = $adapter; Device = $devices[0] }
}
function Get-FrameStatus([string]$ExpectedGuid) {
    $frame = Get-FrameAdapter
    if ($ExpectedGuid -and ([guid]$frame.Adapter.InterfaceGuid).ToString('D') -ne $ExpectedGuid) { throw 'Adapter identity changed.' }
    return [pscustomobject]@{
        Timestamp = [DateTimeOffset]::Now.ToString('o')
        Status = [string]$frame.Adapter.Status
        AdminStatus = [string]$frame.Adapter.AdminStatus
        DeviceError = [int]$frame.Device.ConfigManagerErrorCode
    }
}
function Assert-PlainPath([string]$Path) {
    $entry = [IO.Path]::GetFullPath($Path)
    while ($entry) {
        if (Test-Path -LiteralPath $entry) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked journal paths are not supported.' }
        }
        $entry = [IO.Path]::GetDirectoryName($entry)
    }
}
function Write-RecoveryResult($Result) {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    $path = [IO.Path]::GetFullPath($ResultPath)
    $root = [IO.Path]::GetFullPath($script:StateDirectory)
    if (![string]::Equals([IO.Path]::GetDirectoryName($path),$root,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($path) -cnotmatch '^recovery-[a-f0-9]{32}\.json$') { throw 'Invalid recovery journal path.' }
    Assert-PlainPath $path
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Assert-PlainPath $root
    $temporary = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Result | ConvertTo-Json -Depth 5))
        $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Assert-PlainPath $path
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
function Test-FrameAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Enter-FrameRecovery {
    $mutex = New-Object Threading.Mutex($false,$script:RecoveryMutexName)
    $held = $false
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { $mutex.Dispose(); return $null }
    return $mutex
}
function Invoke-FrameRecovery {
    $result = [ordered]@{ Success=$false; CommandSucceeded=$false; ConnectionObserved=$false; Operation=''; RequestedOperation=''; ActionStarted=$null; ActionCompleted=$null; ActionElapsedMs=$null; Samples=@(); Before=$null; After=$null; ErrorCode=''; Message='' }
    $lock = $null
    $stage = 'inspect_failed'
    try {
        if (!(Test-FrameAdministrator)) { $stage='not_admin'; throw 'Administrator required' }
        $lock = Enter-FrameRecovery
        if ($null -eq $lock) { $stage='busy'; throw 'Recovery in progress' }
        $frame = Get-FrameAdapter
        $expected = ([guid]$frame.Adapter.InterfaceGuid).ToString('D')
        $result.Before = Get-FrameStatus -ExpectedGuid $expected
        $stage = 'journal_failed'
        Write-RecoveryResult $result
        $result.RequestedOperation = if ($result.Before.Status -eq 'Disabled' -or $result.Before.AdminStatus -eq 'Down') { 'enable' } else { 'restart' }
        $result.ActionStarted = [DateTimeOffset]::Now.ToString('o')
        Write-RecoveryResult $result
        $stage = 'command_failed'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($result.RequestedOperation -eq 'enable') {
            Enable-NetAdapter -InputObject $frame.Adapter -Confirm:$false -ErrorAction Stop
            $result.Operation = 'Adapter enabled.'
        } else {
            Restart-NetAdapter -InputObject $frame.Adapter -Confirm:$false -ErrorAction Stop
            $result.Operation = 'Adapter restarted.'
        }
        $clock.Stop()
        $result.CommandSucceeded = $true
        $result.ActionCompleted = [DateTimeOffset]::Now.ToString('o')
        $result.ActionElapsedMs = $clock.Elapsed.TotalMilliseconds
        $stage = 'journal_failed'
        Write-RecoveryResult $result
        $stage = 'observation_failed'
        for ($attempt=0; $attempt -lt 15; $attempt++) {
            Start-Sleep -Seconds 2
            $stage = 'observation_failed'
            $result.After = Get-FrameStatus -ExpectedGuid $expected
            $result.Samples += $result.After
            $stage = 'journal_failed'
            Write-RecoveryResult $result
            if ($result.After.Status -eq 'Up') { break }
        }
        $result.ConnectionObserved = ($result.After.Status -eq 'Up')
        $result.Success = $true
        $result.Message = if ($result.ConnectionObserved) { 'Windows connected. Check the stream in the headset.' }
            else { 'Windows is still disconnected. Check pairing in the headset.' }
    } catch {
        $result.Success = $false
        if ($result.ActionStarted -and !$result.ActionCompleted) { $result.ActionCompleted = [DateTimeOffset]::Now.ToString('o') }
        $result.ErrorCode = $stage
        $result.Message = switch ($stage) {
            'not_admin' { 'Administrator access is required.' }
            'busy' { 'Another recovery is running.' }
            'inspect_failed' { 'The adapter could not be verified. Check its USB connection.' }
            'journal_failed' { 'Could not save the recovery journal.' }
            'command_failed' { 'Windows could not complete the adapter operation.' }
            default { 'The operation ran, but the connection check failed.' }
        }
    } finally {
        if ($null -ne $lock) { $lock.ReleaseMutex(); $lock.Dispose() }
    }
    Write-RecoveryResult $result
    return $result
}
if ($PreviewPath -and $Action -ne 'UI') { throw 'PreviewPath is only valid in UI mode.' }
if ($Action -eq 'Inspect') { Get-FrameStatus | ConvertTo-Json; exit 0 }
if ($Action -eq 'Recover') {
    $result = Invoke-FrameRecovery
    $result | ConvertTo-Json -Depth 5
    if ($result.Success) { exit 0 } else { exit 1 }
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'Frame Adapter'
$form.ClientSize = New-Object Drawing.Size(640, 458)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$intro = New-Object Windows.Forms.Label
$intro.Location = New-Object Drawing.Point(18, 16)
$intro.Size = New-Object Drawing.Size(602, 52)
$intro.Text = 'Enable or restart the Steam Frame adapter. Restarting interrupts streaming. Local diagnostics; no uploads.'
$form.Controls.Add($intro)
$statusBox = New-Object Windows.Forms.TextBox
$statusBox.Location = New-Object Drawing.Point(18, 77)
$statusBox.Size = New-Object Drawing.Size(602, 185)
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.TabStop = $false
$statusBox.ScrollBars = 'Vertical'
$form.Controls.Add($statusBox)
$recoverButton = New-Object Windows.Forms.Button
$recoverButton.Text = 'Recover adapter'
$recoverButton.Location = New-Object Drawing.Point(18, 280)
$recoverButton.Size = New-Object Drawing.Size(220, 42)
$form.Controls.Add($recoverButton)
$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = 'Check status'
$refreshButton.Location = New-Object Drawing.Point(250, 280)
$refreshButton.Size = New-Object Drawing.Size(160, 42)
$form.Controls.Add($refreshButton)
$pairButton = New-Object Windows.Forms.Button
$pairButton.Text = 'Pairing steps'
$pairButton.Location = New-Object Drawing.Point(422, 280)
$pairButton.Size = New-Object Drawing.Size(198, 42)
$form.Controls.Add($pairButton)
$captureButton = New-Object Windows.Forms.Button
$captureButton.Text = 'Capture report'
$captureButton.Location = New-Object Drawing.Point(18, 336)
$captureButton.Size = New-Object Drawing.Size(220, 42)
$form.Controls.Add($captureButton)
$captureLabel = New-Object Windows.Forms.Label
$captureLabel.Location = New-Object Drawing.Point(250, 336)
$captureLabel.Size = New-Object Drawing.Size(370, 42)
$captureLabel.Text = 'Read-only capture of recent connection and streaming events.'
$form.Controls.Add($captureLabel)
$trialButton = New-Object Windows.Forms.Button
$trialButton.Text = 'Guided trial'
$trialButton.Location = New-Object Drawing.Point(18, 394)
$trialButton.Size = New-Object Drawing.Size(220, 42)
$form.Controls.Add($trialButton)
$trialLabel = New-Object Windows.Forms.Label
$trialLabel.Location = New-Object Drawing.Point(250, 394)
$trialLabel.Size = New-Object Drawing.Size(370, 42)
$trialLabel.Text = 'Capture a baseline, mark symptoms, then compare one action.'
$form.Controls.Add($trialLabel)
$trialButton.Add_Click({
    try {
        $trial = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'diagnostics\Start-FrameTrial.ps1'))
        if (!(Test-Path -LiteralPath $trial)) { throw 'Trial script is missing.' }
        $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $shell -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -STA -File "' + $trial + '"') -WindowStyle Hidden | Out-Null
    } catch { $statusBox.Text = 'Could not open guided trial: ' + $_.Exception.Message }
})
function Show-FrameStatus {
    try {
        $status = Get-FrameStatus
        $recoverButton.Text = if ($status.Status -eq 'Disabled' -or $status.AdminStatus -eq 'Down') { 'Enable adapter' } else { 'Restart adapter' }
        $meaning = if ($status.Status -eq 'Up') { 'Connected. Check streaming in the headset.' }
            elseif ($status.Status -eq 'Disabled' -or $status.AdminStatus -eq 'Down') { 'Disabled. Select Enable adapter to turn it on.' }
            else { 'Enabled, but disconnected. Try Restart adapter or check pairing.' }
        $statusBox.Text = @(
            "Adapter: $script:AdapterDescription"
            "Link: $($status.Status)    Enabled state: $($status.AdminStatus)"
            "Windows device error: $($status.DeviceError)"
            "Last checked: $($status.Timestamp)"
            ''
            $meaning
        ) -join $script:NewLine
    } catch { $statusBox.Text = $_.Exception.Message }
}
$refreshButton.Add_Click({ Show-FrameStatus })
$pairButton.Add_Click({
    [Windows.Forms.MessageBox]::Show(
        'On the headset: Steam Settings > Remote Play > Wireless Streaming Adapter. Follow the pairing prompts. If the PC shows no prompt, try another USB port.',
        'Pairing', 'OK', 'Information') | Out-Null
})
$script:Worker = $null
$script:WorkerResult = $null
$script:WorkerKind = 'recovery'
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($null -eq $script:Worker -or !$script:Worker.HasExited) { return }
    $timer.Stop()
    try {
        if ($script:WorkerKind -eq 'capture') {
            $reports = @(Get-ChildItem -LiteralPath $script:WorkerResult -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'report.md') -ErrorAction SilentlyContinue })
            if ($script:Worker.ExitCode -eq 0 -and $reports.Count -eq 1) { $statusBox.Text = 'Report saved: ' + $reports[0].FullName }
            else { $statusBox.Text = 'Capture did not return a report. Capture folder: ' + $script:WorkerResult }
        } elseif (Test-Path -LiteralPath $script:WorkerResult) {
            $result = Get-Content -LiteralPath $script:WorkerResult -Raw | ConvertFrom-Json
            $afterText = if ($null -ne $result.After) {
                "Link: $($result.After.Status)    Enabled state: $($result.After.AdminStatus)"
            } else { 'Adapter status unavailable.' }
            $statusBox.Text = @($result.Operation, $afterText, '', $result.Message, '', "Result: $script:WorkerResult") -join $script:NewLine
        } else { $statusBox.Text = 'No result returned. Select Check status before retrying.' }
    } catch { $statusBox.Text = $_.Exception.Message }
    finally {
        $script:Worker.Dispose()
        $script:Worker = $null
        $recoverButton.Enabled = $true
        $refreshButton.Enabled = $true
        $captureButton.Enabled = $true
        $trialButton.Enabled = $true
    }
})
$recoverButton.Add_Click({
    try {
        $script:WorkerKind = 'recovery'
        [IO.Directory]::CreateDirectory($script:StateDirectory) | Out-Null
        $script:WorkerResult = Join-Path $script:StateDirectory ("recovery-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        $powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -Action Recover -ResultPath "{1}"' -f $script:ToolPath, $script:WorkerResult
        $script:Worker = Start-Process -FilePath $powerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $recoverButton.Enabled = $false
        $refreshButton.Enabled = $false
        $captureButton.Enabled = $false
        $trialButton.Enabled = $false
        $statusBox.Text = 'Recovering adapter...'
        $timer.Start()
    } catch { $statusBox.Text = "Could not start recovery: $($_.Exception.Message)" }
})
$captureButton.Add_Click({
    try {
        $collector = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'diagnostics\Capture-FrameSession.ps1'))
        if (!(Test-Path -LiteralPath $collector)) { throw 'Capture-FrameSession.ps1 was not found.' }
        $script:WorkerKind = 'capture'
        $script:WorkerResult = Join-Path ([IO.Path]::GetDirectoryName($script:StateDirectory)) ('reports\ui-' + [Guid]::NewGuid().ToString('N'))
        $powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -DurationSeconds 30 -HistoryMinutes 90 -OutputRoot "{1}" -OpenReport' -f $collector, $script:WorkerResult
        $script:Worker = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        $recoverButton.Enabled = $false
        $refreshButton.Enabled = $false
        $captureButton.Enabled = $false
        $trialButton.Enabled = $false
        $statusBox.Text = 'Capturing connection and streaming events. This takes about 30 seconds.'
        $timer.Start()
    } catch { $statusBox.Text = 'Could not start capture: ' + $_.Exception.Message }
})
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if ($null -ne $script:Worker -and !$script:Worker.HasExited) {
        $eventArgs.Cancel=$true
        $statusBox.Text='Wait for the current operation to finish.'
    }
})
if ($PreviewPath) {
    $statusBox.Text = 'Preview only. No hardware inspection or recovery was run.'
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Dispose()
} else {
    Show-FrameStatus
    [void]$form.ShowDialog()
}
