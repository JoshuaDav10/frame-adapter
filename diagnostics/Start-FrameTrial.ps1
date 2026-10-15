[CmdletBinding()]
param([string]$PreviewPath, [switch]$LoadOnly,
    [string]$OutputRoot = (Join-Path $env:LOCALAPPDATA 'FrameAdapter\trials'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:Trial = $null
$script:TrialPath = $null
$script:Worker = $null
$script:Phase = 'setup'
$script:BaselineReport = $null
$script:AfterReport = $null

function Write-TrialState {
    if ($null -eq $script:Trial -or !$script:TrialPath) { return }
    $text = $script:Trial | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($script:TrialPath + '.tmp', $text, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($script:TrialPath)) {
        [IO.File]::Replace($script:TrialPath + '.tmp', $script:TrialPath, [System.Management.Automation.Language.NullString]::Value)
    } else { [IO.File]::Move($script:TrialPath + '.tmp', $script:TrialPath) }
}
function Add-TrialMarker([string]$Kind) {
    if ($Kind -notin @('problem','stutter','warning_cleared','other_change','recovery_requested','observation_only')) {
        throw 'Unsupported marker'
    }
    if ($null -eq $script:Trial) { throw 'Start a baseline first' }
    $script:Trial.markers += [pscustomobject]@{timestamp=[DateTimeOffset]::Now.ToString('o');kind=$Kind}
    Write-TrialState
}
function New-TrialLabel($Text, $X, $Y, $Width, $Height) {
    $control = New-Object Windows.Forms.Label
    $control.Text = $Text
    $control.Location = New-Object Drawing.Point($X,$Y)
    $control.Size = New-Object Drawing.Size($Width,$Height)
    $form.Controls.Add($control)
    return $control
}
function New-TrialChoice($Items, $X, $Y, $Width) {
    $control = New-Object Windows.Forms.ComboBox
    $control.DropDownStyle = 'DropDownList'
    $control.Location = New-Object Drawing.Point($X,$Y)
    $control.Size = New-Object Drawing.Size($Width,24)
    $control.Items.AddRange([object[]]$Items)
    $control.SelectedIndex = 0
    $form.Controls.Add($control)
    return $control
}
function New-TrialButton($Text, $X, $Y, $Width) {
    $control = New-Object Windows.Forms.Button
    $control.Text = $Text
    $control.Location = New-Object Drawing.Point($X,$Y)
    $control.Size = New-Object Drawing.Size($Width,38)
    $form.Controls.Add($control)
    return $control
}
$form = New-Object Windows.Forms.Form
$form.Text = 'Frame Diagnostics - guided trial'
$form.ClientSize = New-Object Drawing.Size(760,610)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$null = New-TrialLabel 'Keep the same game, scene and settings in both phases. Record the failing state first. Recovery runs only when you choose Restart adapter and approve Windows elevation.' 18 15 720 45
$null = New-TrialLabel 'Headset activity (your observation)' 18 68 340 20
$headsetChoice = New-TrialChoice @('unknown','awake_streaming','idle') 18 90 340
$null = New-TrialLabel 'Streaming path shown in the headset' 388 68 340 20
$pathChoice = New-TrialChoice @('unknown','adapter','home_wifi','multilink') 388 90 340
$null = New-TrialLabel 'Warning before baseline' 18 128 340 20
$warningChoice = New-TrialChoice @('unknown','inactive','cleared') 18 150 340
$null = New-TrialLabel 'Seconds in each observation phase' 388 128 340 20
$durationChoice = New-TrialChoice @('60','30','120') 388 150 340
$sameWorkload = New-Object Windows.Forms.CheckBox
$sameWorkload.Text = 'I will keep the headset awake and use the same workload in both phases.'
$sameWorkload.Location = New-Object Drawing.Point(18,190)
$sameWorkload.Size = New-Object Drawing.Size(710,25)
$form.Controls.Add($sameWorkload)
$startButton = New-TrialButton '1. Capture baseline' 18 228 224
$restartButton = New-TrialButton '2. Restart adapter' 260 228 224
$controlButton = New-TrialButton '2. Observe without restart' 502 228 224
$restartButton.Enabled = $false
$controlButton.Enabled = $false
$null = New-TrialLabel 'Timestamp an observation while the trial is running:' 18 284 710 22
$problemButton = New-TrialButton 'Problem now' 18 311 166
$stutterButton = New-TrialButton 'Stutter now' 198 311 166
$clearButton = New-TrialButton 'Warning cleared' 378 311 166
$otherButton = New-TrialButton 'Other change made' 558 311 168
$script:MarkerButtons = @($problemButton,$stutterButton,$clearButton,$otherButton)
foreach ($button in $script:MarkerButtons) { $button.Enabled = $false }
$statusBox = New-Object Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = 'Vertical'
$statusBox.Location = New-Object Drawing.Point(18,365)
$statusBox.Size = New-Object Drawing.Size(710,178)
$statusBox.Text = 'No trial started. Captures read logs and settings. Only Restart adapter changes hardware state. No protocol, power or network-profile settings are changed.'
$form.Controls.Add($statusBox)
$openButton = New-TrialButton 'Open comparison' 18 558 224
$openButton.Enabled = $false
$null = New-TrialLabel 'Local reports. No uploads.' 260 566 468 28

function Start-TrialCapture([string]$PhaseName) {
    $script:Phase = $PhaseName
    $phaseRoot = Join-Path ([IO.Path]::GetDirectoryName($script:TrialPath)) $PhaseName
    $script:PhaseRoot = $phaseRoot
    $phaseWarning = if ($PhaseName -eq 'baseline') { $script:Trial.headset_warning } else { 'unknown' }
    $argsText = '-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -DurationSeconds {1} -HistoryMinutes 15 -HeadsetState {2} -HeadsetWarning {3} -StreamPath {4} -OutputRoot "{5}"' -f `
        (Join-Path $PSScriptRoot 'Capture-FrameSession.ps1'),$script:Trial.phase_seconds,$script:Trial.headset_state,$phaseWarning,$script:Trial.stream_path,$phaseRoot
    $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Worker = Start-Process -FilePath $shell -ArgumentList $argsText -WindowStyle Hidden -PassThru
    $script:Trial.state = $PhaseName
    Write-TrialState
    $statusBox.Text = "Capturing $PhaseName for $($script:Trial.phase_seconds) seconds. Keep the workload unchanged. Use the observation buttons when a symptom occurs."
    $timer.Start()
}
function Stop-TrialWithError([string]$Message) {
    $timer.Stop()
    if ($null -ne $script:Trial) { $script:Trial.state = 'incomplete'; Write-TrialState }
    $restartButton.Enabled = $false
    $controlButton.Enabled = $false
    foreach ($button in $script:MarkerButtons) { $button.Enabled = $false }
    $statusBox.Text = $Message + [Environment]::NewLine + 'The partial trial is preserved. Close this window and start a new trial when ready.'
}
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($null -eq $script:Worker -or !$script:Worker.HasExited) { return }
    $timer.Stop()
    try {
        $workerExit = $script:Worker.ExitCode
        $script:Worker.Dispose()
        $script:Worker = $null
        if ($script:Phase -eq 'recovery') {
            $result = Get-Content -LiteralPath $script:RecoveryPath -Raw | ConvertFrom-Json
            if ($workerExit -ne 0 -or !$result.Success) { throw 'Recovery did not complete successfully. No after phase was started.' }
            $script:Trial.recovery_operation_succeeded = $result.Success
            $script:Trial.connection_observed = $result.ConnectionObserved
            Write-TrialState
            Start-TrialCapture 'after'
            return
        }
        if ($workerExit -ne 0) { throw 'Capture failed. Check Python 3.10+ and the preserved capture folder.' }
        $reports = @(Get-ChildItem -LiteralPath $script:PhaseRoot -Directory | ForEach-Object {
            Get-Item -LiteralPath (Join-Path $_.FullName 'report.json') -ErrorAction SilentlyContinue
        })
        if ($reports.Count -ne 1) { throw 'Capture did not return exactly one report.' }
        if ($script:Phase -eq 'baseline') {
            $script:BaselineReport = $reports[0].FullName
            $script:Phase = 'ready'
            $script:Trial.state = 'baseline_saved'
            Write-TrialState
            $restartButton.Enabled = $true
            $controlButton.Enabled = $true
            $statusBox.Text = 'Baseline saved. Choose one adapter restart, or observe without restarting as a comparison. Any other changes should be marked. No action happens automatically.'
        } else {
            $script:AfterReport = $reports[0].FullName
            $trialRoot = [IO.Path]::GetDirectoryName($script:TrialPath)
            & $script:Python -B (Join-Path $PSScriptRoot 'diagnosis.py') --trial $script:TrialPath --baseline $script:BaselineReport --after $script:AfterReport --output $trialRoot
            if ($LASTEXITCODE -ne 0) { throw 'Comparison failed; both phase reports are preserved.' }
            $script:Trial.state = 'complete'
            Write-TrialState
            $script:Phase = 'complete'
            foreach ($button in $script:MarkerButtons) { $button.Enabled = $false }
            $openButton.Enabled = $true
            $statusBox.Text = 'Trial saved: ' + $trialRoot + [Environment]::NewLine + 'Open the comparison. Reconnection, warning clearance and stable gameplay are separate outcomes; this trial does not establish a root cause.'
        }
    } catch { Stop-TrialWithError $_.Exception.Message }
})
$startButton.Add_Click({
    try {
        $script:Python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        & $script:Python -B -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)'
        if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 or newer is required.' }
        $trialRoot = Join-Path $OutputRoot ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        [IO.Directory]::CreateDirectory($trialRoot) | Out-Null
        $script:TrialPath = Join-Path $trialRoot 'trial.json'
        $script:Trial = [ordered]@{schema_version=1;state='setup';phase_seconds=[int]$durationChoice.SelectedItem;headset_state=[string]$headsetChoice.SelectedItem;headset_warning=[string]$warningChoice.SelectedItem;stream_path=[string]$pathChoice.SelectedItem;same_workload=$sameWorkload.Checked;markers=@();recovery_operation_succeeded=$false;connection_observed=$false}
        Write-TrialState
        foreach ($control in @($headsetChoice,$pathChoice,$warningChoice,$durationChoice,$sameWorkload,$startButton)) { $control.Enabled = $false }
        foreach ($button in $script:MarkerButtons) { $button.Enabled = $true }
        Start-TrialCapture 'baseline'
    } catch { Stop-TrialWithError $_.Exception.Message }
})
$restartButton.Add_Click({
    try {
        Add-TrialMarker 'recovery_requested'
        $restartButton.Enabled = $false
        $controlButton.Enabled = $false
        $script:Phase = 'recovery'
        $recoveryRoot = Join-Path $env:LOCALAPPDATA 'FrameAdapter\recovery'
        [IO.Directory]::CreateDirectory($recoveryRoot) | Out-Null
        $script:RecoveryPath = Join-Path $recoveryRoot ('recovery-' + [Guid]::NewGuid().ToString('N') + '.json')
        $helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\FrameAdapter.ps1'))
        $argsText = '-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -Action Recover -ResultPath "{1}"' -f $helper,$script:RecoveryPath
        $script:Worker = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argsText -Verb RunAs -WindowStyle Hidden -PassThru
        $script:Trial.state = 'recovery'
        Write-TrialState
        $statusBox.Text = 'One recovery requested. The after phase begins when the operation and its connection observations finish.'
        $timer.Start()
    } catch { Stop-TrialWithError ('Recovery cancelled or could not start. ' + $_.Exception.Message) }
})
$controlButton.Add_Click({
    try {
        Add-TrialMarker 'observation_only'
        $restartButton.Enabled = $false
        $controlButton.Enabled = $false
        Start-TrialCapture 'after'
    } catch { Stop-TrialWithError $_.Exception.Message }
})
$problemButton.Add_Click({ Add-TrialMarker 'problem'; $statusBox.AppendText([Environment]::NewLine + 'Problem marked.') })
$stutterButton.Add_Click({ Add-TrialMarker 'stutter'; $statusBox.AppendText([Environment]::NewLine + 'Stutter marked.') })
$clearButton.Add_Click({ Add-TrialMarker 'warning_cleared'; $statusBox.AppendText([Environment]::NewLine + 'Warning clearance marked (your observation).') })
$otherButton.Add_Click({ Add-TrialMarker 'other_change'; $statusBox.AppendText([Environment]::NewLine + 'Other change marked; the comparison will be labelled confounded.') })
$openButton.Add_Click({
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + (Join-Path ([IO.Path]::GetDirectoryName($script:TrialPath)) 'comparison.md') + '"') | Out-Null
})
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if ($null -ne $script:Worker -and !$script:Worker.HasExited) {
        $eventArgs.Cancel = $true
        $statusBox.AppendText([Environment]::NewLine + 'Wait for the current operation to finish before closing.')
    } elseif ($null -ne $script:Trial -and $script:Trial.state -ne 'complete') {
        $script:Trial.state = 'incomplete'
        Write-TrialState
    }
})
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
if ($LoadOnly) { return }
if ($PreviewPath) {
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Dispose()
} else { [void]$form.ShowDialog() }
