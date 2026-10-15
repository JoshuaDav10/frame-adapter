[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('frame-prep-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
function Assert-Frame($Condition, $Message) { if (!$Condition) { throw $Message } }
function Import-FrameFunction($Path, $Name) {
    $tokens = $null; $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-Frame ($errors.Count -eq 0) 'PowerShell syntax error'
    $node = $tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true) | Select-Object -First 1
    Assert-Frame ($null -ne $node) ('Missing function: ' + $Name)
    return $node.Extent.Text
}
try {
    # Exercise production configuration code against fake Windows results only.
    $collector = Join-Path $PSScriptRoot '..\diagnostics\Capture-FrameSession.ps1'
    Invoke-Expression (Import-FrameFunction $collector 'Convert-PowerSetting')
    Invoke-Expression (Import-FrameFunction $collector 'Get-Configuration')
    Assert-Frame ((Convert-PowerSetting 2) -eq 'Enabled' -and (Convert-PowerSetting 1) -eq 'Disabled' -and (Convert-PowerSetting 0) -eq 'Unsupported') 'Numeric power enums were not mapped'
    Assert-Frame ((Convert-PowerSetting $null) -eq 'unknown') 'Missing power setting acquired a value'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $script:FakePowerFails = $true
    $script:FakeProfileMissing = $false
    function Get-NetAdapter { [pscustomobject]@{InterfaceGuid='11111111-1111-1111-1111-111111111111';ifIndex=7;Name='Synthetic adapter'} }
    function Get-NetConnectionProfile {
        if (!$script:FakeProfileMissing) { [pscustomobject]@{NetworkCategory='Public'} }
    }
    function Get-NetAdapterAdvancedProperty {
        [pscustomobject]@{RegistryKeyword='WifiProtocol_6G';DisplayValue='IEEE 802.11ax'}
        [pscustomobject]@{RegistryKeyword='ForcedUsbMode';DisplayValue=$null}
    }
    function Get-NetAdapterPowerManagement {
        if ($script:FakePowerFails) { throw 'Synthetic provider failure' }
        [pscustomobject]@{AllowComputerToTurnOffDevice='Unsupported';SelectiveSuspend='Unsupported'}
    }
    $probe = [pscustomobject]@{probe='verified';guid='11111111-1111-1111-1111-111111111111'}
    $config = Get-Configuration $probe
    Assert-Frame ($config.profile -eq 'Public' -and $config.six_ghz -eq 'ax') 'Configuration mapping failed'
    Assert-Frame ($config.device_power_off -eq 'unknown' -and $config.usb_mode -eq 'unknown') 'Missing value became a setting'
    Assert-Frame ($config.power_query -eq 'unavailable') 'Failed power query was treated as readable'
    $script:FakePowerFails = $false
    $script:FakeProfileMissing = $true
    $config = Get-Configuration $probe
    Assert-Frame ($config.profile -eq 'no_active_profile' -and $config.device_power_off -eq 'Unsupported') 'Unsupported or absent profile state lost'
    $config = Get-Configuration ([pscustomobject]@{probe='query_failed'})
    Assert-Frame ($config.profile -eq 'unknown') 'Unverified identity queried as verified'

    # The UI uses fake child processes; no collector, UAC, recovery or network action runs.
    $script:FakeProcessCalls = 0
    $script:FakeEpoch = [DateTimeOffset]::Now
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,$Verb)
        $script:FakeProcessCalls++
        if ($Verb -eq 'RunAs') { throw 'Synthetic elevation cancellation' }
        $match = [regex]::Match($ArgumentList,'-OutputRoot "([^"]+)"')
        Assert-Frame $match.Success 'Unexpected child process in UI test'
        $root = Join-Path $match.Groups[1].Value 'synthetic'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $begin = if ($script:Phase -eq 'baseline') { $script:FakeEpoch } else { $script:FakeEpoch.AddSeconds(60) }
        $report = @{sampling_window=@{start=$begin.ToString('o');end=$begin.AddSeconds(16).ToString('o')};timeline=@();warnings=@();headset_state='unknown';actions=@();windows_state='Up'}
        [IO.File]::WriteAllText((Join-Path $root 'report.json'),($report | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $worker = [pscustomobject]@{HasExited=$true;ExitCode=0}
        $worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $worker
    }
    function Wait-FramePhase([string]$Expected) {
        $deadline = [DateTimeOffset]::Now.AddSeconds(10)
        while ($script:Phase -ne $Expected -and [DateTimeOffset]::Now -lt $deadline) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 25
        }
        Assert-Frame ($script:Phase -eq $Expected) ('UI phase failed: ' + $statusBox.Text)
    }
    . (Join-Path $PSScriptRoot '..\diagnostics\Start-FrameTrial.ps1') -LoadOnly -OutputRoot $testRoot
    $form.Opacity = 0; $form.ShowInTaskbar = $false; $form.Show()
    Assert-Frame (!$restartButton.Enabled -and !$controlButton.Enabled) 'Recovery available before baseline'
    [void]$durationChoice.Items.Add('15'); $durationChoice.SelectedItem = '15'
    $startButton.PerformClick()
    Wait-FramePhase 'ready'
    Assert-Frame ($script:FakeProcessCalls -eq 1) 'Baseline triggered an extra operation'
    Assert-Frame ($restartButton.Enabled -and $controlButton.Enabled) 'Baseline did not unlock user choices'
    $problemButton.PerformClick()
    $controlButton.PerformClick()
    Wait-FramePhase 'complete'
    Assert-Frame ($script:FakeProcessCalls -eq 2) 'Observation-only trial triggered an extra operation'
    $comparison = Get-Content -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($script:TrialPath)) 'comparison.json') -Raw | ConvertFrom-Json
    Assert-Frame (!$comparison.comparable -and $comparison.recovery_requests -eq 0) 'Unknown activity was treated as a controlled repair'
    Assert-Frame ($openButton.Enabled -and !$problemButton.Enabled) 'Final UI state incorrect'
    $form.Close(); $form.Dispose()

    . (Join-Path $PSScriptRoot '..\diagnostics\Start-FrameTrial.ps1') -LoadOnly -OutputRoot $testRoot
    $form.Opacity = 0; $form.ShowInTaskbar = $false; $form.Show()
    [void]$durationChoice.Items.Add('15'); $durationChoice.SelectedItem = '15'
    $startButton.PerformClick()
    Wait-FramePhase 'ready'
    $restartButton.PerformClick()
    Assert-Frame ($script:Trial.state -eq 'incomplete' -and !$controlButton.Enabled) 'Cancelled elevation started an after phase'
    $saved = Get-Content -LiteralPath $script:TrialPath -Raw | ConvertFrom-Json
    Assert-Frame ($saved.state -eq 'incomplete') 'Incomplete trial was not journaled'
    Assert-Frame (!(Test-Path -LiteralPath ($script:TrialPath + '.tmp'))) 'Atomic trial journal left a temporary file'
    $form.Close(); $form.Dispose()
    'Configuration fixtures, UI observation-only flow, cancellation and trial journal: PASS (no hardware actions)'
} finally {
    if ($null -ne (Get-Variable form -ErrorAction SilentlyContinue)) { $form.Dispose() }
    # Checked absolute path, one PowerShell operation, restricted to this temporary test directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'frame-prep-test-*') { throw 'Unsafe test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
