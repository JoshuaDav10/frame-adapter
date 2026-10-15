[CmdletBinding()]
param(
    [ValidateRange(0, 600)][int]$DurationSeconds = 30,
    [ValidateRange(1, 240)][int]$HistoryMinutes = 90,
    [ValidateSet('unknown','awake_streaming','idle')][string]$HeadsetState = 'unknown',
    [ValidateSet('unknown','inactive','cleared')][string]$HeadsetWarning = 'unknown',
    [ValidateSet('unknown','adapter','home_wifi','multilink')][string]$StreamPath = 'unknown',
    [string]$SteamRoot,
    [string]$OutputRoot = (Join-Path $env:LOCALAPPDATA 'FrameAdapter\reports'),
    [switch]$OpenReport
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$description = 'Realtek 8832CU Wireless LAN WiFi 6 USB NIC For Valve'
$warnings = New-Object 'System.Collections.Generic.List[string]'
if (!$SteamRoot) {
    try { $SteamRoot = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if (!$SteamRoot) { $SteamRoot = Join-Path ${env:ProgramFiles(x86)} 'Steam' }
}
function Get-Snapshot {
    $now = [DateTimeOffset]::Now.ToString('o')
    try {
        $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object InterfaceDescription -eq $description)
        if ($adapters.Count -eq 0) { return [pscustomobject]@{timestamp=$now;status='unknown';guid='';device_id='';probe='not_found'} }
        if ($adapters.Count -ne 1) { return [pscustomobject]@{timestamp=$now;status='unknown';guid='';device_id='';probe='ambiguous'} }
        $adapter = $adapters[0]
        $devices = @(Get-CimInstance Win32_NetworkAdapter | Where-Object InterfaceIndex -eq $adapter.ifIndex)
        if ($devices.Count -ne 1 -or $devices[0].PNPDeviceID -notlike 'USB\VID_28DE&PID_2432\*') {
            return [pscustomobject]@{timestamp=$now;status='unknown';guid='';device_id='';probe='identity_mismatch'}
        }
        return [pscustomobject]@{
            timestamp=$now; status=[string]$adapter.Status; guid=([guid]$adapter.InterfaceGuid).ToString('D')
            device_id=[string]$devices[0].PNPDeviceID; probe='verified'
        }
    } catch {
        $warnings.Add('adapter_snapshot_unavailable')
        return [pscustomobject]@{timestamp=$now;status='unknown';guid='';device_id='';probe='query_failed'}
    }
}
function Convert-PowerSetting($Value) {
    if ($null -eq $Value) { return 'unknown' }
    switch ($Value.ToString()) {
        '0' { return 'Unsupported' }
        '1' { return 'Disabled' }
        '2' { return 'Enabled' }
        'Unsupported' { return 'Unsupported' }
        'Disabled' { return 'Disabled' }
        'Enabled' { return 'Enabled' }
        default { return 'unknown' }
    }
}
function Get-Configuration($Snapshot) {
    $config = [ordered]@{profile='unknown';six_ghz='unknown';usb_mode='unknown';device_power_off='unknown';selective_suspend='unknown';power_query='unavailable'}
    if ($Snapshot.probe -ne 'verified') { return $config }
    try {
        $adapter = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { ([guid]$_.InterfaceGuid).ToString('D') -eq $Snapshot.guid }
        $profiles = @(Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction Stop)
        if ($profiles.Count -eq 0) { $config.profile = 'no_active_profile' }
        elseif ($profiles.Count -eq 1) { $config.profile = $profiles[0].NetworkCategory.ToString() }
    } catch { $warnings.Add('profile_query_unavailable') }
    try {
        $properties = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop)
        $six = @($properties | Where-Object RegistryKeyword -eq 'WifiProtocol_6G')
        if ($six.Count -eq 1 -and $six[0].DisplayValue) {
            $config.six_ghz = if ($six[0].DisplayValue -eq 'IEEE 802.11ax') { 'ax' } else { 'other' }
        }
        $usb = @($properties | Where-Object RegistryKeyword -eq 'ForcedUsbMode')
        if ($usb.Count -eq 1 -and $usb[0].DisplayValue -in @('Auto','USB 2.0','USB 3.0')) { $config.usb_mode = $usb[0].DisplayValue }
    } catch { $warnings.Add('advanced_properties_unavailable') }
    try {
        $power = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop
        $config.device_power_off = Convert-PowerSetting $power.AllowComputerToTurnOffDevice
        if ($config.device_power_off -eq 'Enabled') {
            $config.selective_suspend = Convert-PowerSetting $power.SelectiveSuspend
        }
        $config.power_query = 'readable'
    } catch { $warnings.Add('power_query_unavailable') }
    return $config
}
$began = [DateTimeOffset]::Now
$historyStart = $began.AddMinutes(-$HistoryMinutes)
$sessionId = $began.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$output = Join-Path $OutputRoot $sessionId
[IO.Directory]::CreateDirectory($output) | Out-Null
$clock = [Diagnostics.Stopwatch]::StartNew()
$samples = New-Object 'System.Collections.Generic.List[object]'
$target = Get-Snapshot
$config = Get-Configuration $target
$samples.Add([pscustomobject]@{timestamp=$target.timestamp;status=$target.status})
$system = @{}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $system.os = $os.Caption
    $system.os_version = $os.Version
    $system.os_build = $os.BuildNumber
    $gpu = Get-CimInstance Win32_VideoController | Where-Object PNPDeviceID -Like 'PCI\*' | Select-Object -First 1
    if ($null -ne $gpu) { $system.gpu = $gpu.Name; $system.gpu_driver = $gpu.DriverVersion }
    if ($target.device_id) {
        $driver = Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceID -eq $target.device_id | Select-Object -First 1
        if ($null -ne $driver) { $system.adapter_driver = $driver.DriverVersion }
    }
    $manifest = Join-Path $SteamRoot 'steamapps\appmanifest_250820.acf'
    if (Test-Path -LiteralPath $manifest) {
        $build = [regex]::Match([IO.File]::ReadAllText($manifest),'"buildid"\s+"(\d+)"')
        if ($build.Success) { $system.steamvr_build = $build.Groups[1].Value }
    }
    $serverLog = Join-Path $SteamRoot 'logs\vrserver.txt'
    if (Test-Path -LiteralPath $serverLog) {
        $startupLines = @(Get-Content -LiteralPath $serverLog -TotalCount 80) + @(Get-Content -LiteralPath $serverLog -Tail 1000)
        $startup = $startupLines | Select-String -Pattern 'vrserver (\d+\.\d+\.\d+) startup' | Select-Object -Last 1
        if ($null -ne $startup) { $system.steamvr_version = $startup.Matches[0].Groups[1].Value }
    }
} catch { $warnings.Add('system_metadata_incomplete') }
while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
    Start-Sleep -Seconds 3
    $sample = Get-Snapshot
    $samples.Add([pscustomobject]@{timestamp=$sample.timestamp;status=$sample.status})
}
$finalSnapshot = Get-Snapshot
$samples.Add([pscustomobject]@{timestamp=$finalSnapshot.timestamp;status=$finalSnapshot.status})
$samplingFinished = [DateTimeOffset]::Now
$wlan = New-Object 'System.Collections.Generic.List[object]'
if ($target.guid) {
    try {
        $wlanLog = Get-WinEvent -ListLog 'Microsoft-Windows-WLAN-AutoConfig/Operational' -ErrorAction Stop
        if (!$wlanLog.IsEnabled) { throw 'WLAN event log is disabled' }
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'
            StartTime=$historyStart.LocalDateTime; Id=8001,8002,8003
        } -MaxEvents 5000 -ErrorAction Stop)
        if ($events.Count -ge 5000) { $warnings.Add('wlan_event_limit') }
        foreach ($event in $events) {
            [xml]$xml = $event.ToXml()
            $fields = @{}
            foreach ($field in $xml.Event.EventData.Data) { $fields[[string]$field.Name] = [string]$field.'#text' }
            if (!$fields['InterfaceGuid'] -or ([guid]$fields['InterfaceGuid']).ToString('D') -ne $target.guid) { continue }
            $reason = if ($event.Message -match 'specific network is not available') { 'target_unavailable' }
                elseif ($event.Message -match 'disconnected by the driver') { 'driver_reported' }
                elseif ($event.Message -match 'disconnected by the user') { 'user_request' }
                else { 'other' }
            $wlan.Add([pscustomobject]@{
                timestamp=([DateTimeOffset]$event.TimeCreated).ToString('o')
                event_id=$event.Id; reason=$reason; frame_network=($fields['SSID'] -like 'frame_*')
            })
        }
    } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $warnings.Add('wlan_events_unavailable') } }
} else { $warnings.Add('wlan_interface_unknown') }
$finished = [DateTimeOffset]::Now
$capture = [ordered]@{
    schema_version=1; history_started=$historyStart.ToString('o')
    capture_started=$began.ToString('o'); capture_finished=$finished.ToString('o')
    sampling_finished=$samplingFinished.ToString('o')
    utc_offset=$began.ToString('zzz'); headset_state=$HeadsetState
    headset_warning=$HeadsetWarning; stream_path=$StreamPath
    adapter_probe=$finalSnapshot.probe; configuration=$config
    system=$system; adapter_samples=@($samples.ToArray()); wlan_events=@($wlan.ToArray())
    warnings=@($warnings.ToArray())
}
$capturePath = Join-Path $output 'capture.json'
[IO.File]::WriteAllText($capturePath,($capture | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$analyzer = Join-Path $PSScriptRoot 'frame_diagnostics.py'
& $python -B $analyzer --capture $capturePath --steam-log (Join-Path $SteamRoot 'logs\driver_vrlink.txt') --recovery-dir (Join-Path $env:LOCALAPPDATA 'FrameAdapter\recovery') --output $output
if ($LASTEXITCODE -ne 0) { throw 'Report generation failed; capture.json is preserved.' }
if ($OpenReport) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + (Join-Path $output 'report.md') + '"') -WindowStyle Normal | Out-Null }
