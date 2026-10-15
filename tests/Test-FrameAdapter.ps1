[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\FrameAdapter.ps1'))
$tokens=$null; $errors=$null
$tree = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Source syntax failed' }
foreach ($name in @('Get-FrameAdapter','Get-FrameStatus','Assert-PlainPath','Write-RecoveryResult','Test-FrameAdministrator','Enter-FrameRecovery','Invoke-FrameRecovery')) {
    $node = $tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
    if ($null -eq $node) { throw ('Missing function: ' + $name) }
    Invoke-Expression $node.Extent.Text
}
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('frame-recovery-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:StateDirectory = Join-Path $testRoot 'journals'
$ResultPath = Join-Path $script:StateDirectory ('recovery-' + ('a'*32) + '.json')
try {
    Write-RecoveryResult @{value=1}
    Write-RecoveryResult @{value=2}
    Assert ((Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json).value -eq 2) 'Atomic replacement failed'
    Assert (@(Get-ChildItem -LiteralPath $script:StateDirectory -Filter '*.tmp').Count -eq 0) 'Temporary journal left behind'
    foreach ($bad in @((Join-Path $testRoot 'outside.json'),(Join-Path $script:StateDirectory 'arbitrary.json'))) {
        $ResultPath = $bad; $refused=$false
        try { Write-RecoveryResult @{value=3} } catch { $refused=$true }
        Assert $refused 'Invalid journal path accepted'
        Assert (!(Test-Path -LiteralPath $bad)) 'Invalid path was written'
    }
    $linked = Join-Path $testRoot 'linked'
    $target = Join-Path $testRoot 'target'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    New-Item -ItemType Junction -Path $linked -Target $target | Out-Null
    try {
        $script:StateDirectory=$linked
        $ResultPath=Join-Path $linked ('recovery-' + ('b'*32) + '.json')
        $refused=$false
        try { Write-RecoveryResult @{value=4} } catch { $refused=$true }
        Assert $refused 'Linked journal directory accepted'
        Assert (@(Get-ChildItem -LiteralPath $target).Count -eq 0) 'Linked target was written'
    } finally { [IO.Directory]::Delete($linked) }
    $script:RecoveryMutexName='Local\FrameAdapterTest-' + [Guid]::NewGuid().ToString('N')
    $lock=Enter-FrameRecovery
    Assert ($null -ne $lock) 'Could not acquire test mutex'
    $child=Join-Path $testRoot 'mutex.ps1'
    [IO.File]::WriteAllText($child,'param($Name); $m=New-Object Threading.Mutex($false,$Name); if ($m.WaitOne(0)) { $m.ReleaseMutex(); $m.Dispose(); exit 1 }; $m.Dispose(); exit 0')
    try {
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -File $child -Name $script:RecoveryMutexName
        Assert ($LASTEXITCODE -eq 0) 'Recovery mutex did not exclude a second process'
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }

    # Adapter commands below are fixtures; no hardware is read or changed.
    $ResultPath=$null
    $script:AdapterDescription='Realtek 8832CU Wireless LAN WiFi 6 USB NIC For Valve'
    function Reset-Fixture {
        $script:Admin=$true; $script:Busy=$false; $script:Count=1; $script:WrongId=$false
        $script:Status='Up'; $script:AdminStatus='Up'; $script:Guid='11111111-1111-1111-1111-111111111111'
        $script:MutationCount=0; $script:CommandFails=$false; $script:ObservationFails=$false; $script:StayDisconnected=$false
    }
    function Test-FrameAdministrator { return $script:Admin }
    function Enter-FrameRecovery {
        if ($script:Busy) { return $null }
        $m=[pscustomobject]@{}
        $m | Add-Member ScriptMethod ReleaseMutex {}
        $m | Add-Member ScriptMethod Dispose {}
        return $m
    }
    function Get-NetAdapter {
        for ($i=0; $i -lt $script:Count; $i++) {
            [pscustomobject]@{InterfaceDescription=$script:AdapterDescription;ifIndex=7;InterfaceGuid=$script:Guid;Status=$script:Status;AdminStatus=$script:AdminStatus}
        }
    }
    function Get-CimInstance {
        [pscustomobject]@{InterfaceIndex=7;PNPDeviceID=$(if ($script:WrongId) {'USB\VID_0000&PID_0000\synthetic'} else {'USB\VID_28DE&PID_2432\synthetic'});ConfigManagerErrorCode=0}
    }
    function Start-Sleep {}
    function Invoke-FakeCommand {
        $script:MutationCount++
        if ($script:CommandFails) { throw 'private_error_text' }
        if ($script:ObservationFails) { $script:Guid='22222222-2222-2222-2222-222222222222' }
        $script:Status=if ($script:StayDisconnected) {'Disconnected'} else {'Up'}
        $script:AdminStatus='Up'
    }
    function Enable-NetAdapter { Invoke-FakeCommand }
    function Restart-NetAdapter { Invoke-FakeCommand }
    foreach ($scenario in @('not_admin','busy','missing','ambiguous','wrong_hardware')) {
        Reset-Fixture
        switch ($scenario) {
            'not_admin' { $script:Admin=$false }
            'busy' { $script:Busy=$true }
            'missing' { $script:Count=0 }
            'ambiguous' { $script:Count=2 }
            'wrong_hardware' { $script:WrongId=$true }
        }
        $r=Invoke-FrameRecovery
        Assert (!$r.Success -and !$r.CommandSucceeded -and $script:MutationCount -eq 0) ('Unsafe preflight: ' + $scenario)
        Assert ($null -eq $r.ActionStarted) 'Preflight failure counted as an action'
    }
    Reset-Fixture
    $r=Invoke-FrameRecovery
    Assert ($r.Success -and $r.CommandSucceeded -and $r.ConnectionObserved -and $r.RequestedOperation -eq 'restart' -and $script:MutationCount -eq 1) 'Restart result incorrect'
    Assert (!$r.Before.PSObject.Properties['Name'] -and !$r.Before.PSObject.Properties['Description']) 'Adapter aliases leaked into the journal'
    Reset-Fixture; $script:Status='Disabled'; $script:AdminStatus='Down'
    $r=Invoke-FrameRecovery
    Assert ($r.RequestedOperation -eq 'enable' -and $r.Success -and $script:MutationCount -eq 1) 'Disabled path incorrect'
    Reset-Fixture; $script:CommandFails=$true
    $r=Invoke-FrameRecovery
    Assert (!$r.Success -and !$r.CommandSucceeded -and $r.ErrorCode -eq 'command_failed') 'Failed command looked successful'
    Assert (($r | ConvertTo-Json -Depth 5) -notmatch 'private_error_text') 'Raw error text leaked'
    Reset-Fixture; $script:ObservationFails=$true
    $r=Invoke-FrameRecovery
    Assert (!$r.Success -and $r.CommandSucceeded -and !$r.ConnectionObserved -and $r.ErrorCode -eq 'observation_failed') 'Changed target looked connected'
    Reset-Fixture; $script:StayDisconnected=$true
    $r=Invoke-FrameRecovery
    Assert ($r.Success -and $r.CommandSucceeded -and !$r.ConnectionObserved -and $r.Samples.Count -eq 15) 'Disconnected outcome was misreported'
    'Recovery guards, command outcomes, mutex and journal checks: PASS (fixtures only)'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'frame-recovery-test-*') { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
