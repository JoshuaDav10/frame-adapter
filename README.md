# Frame Adapter

Enable or restart the Steam Frame USB adapter on Windows, with optional local diagnostics.

## Use

Extract the ZIP and open `Start.cmd`. Requires Windows PowerShell 5.1. Diagnostics also require Python 3.10+.

If downloaded scripts are blocked, review them, then unblock only these files:

```powershell
Get-ChildItem .\FrameAdapter.ps1, .\diagnostics\*.ps1 | Unblock-File
```

- **Check status:** read Windows adapter state.
- **Enable / Restart:** request administrator access and run one operation. Restart interrupts streaming.
- **Capture report:** read recent Windows and Steam events.
- **Guided trial:** record symptoms and compare before/after recovery, or observe without restarting.

Recovery requires exactly one matching Realtek Valve adapter (`USB VID_28DE/PID_2432`). Other devices and overlapping recoveries in the same Windows session are refused. Drivers, firewall rules, power settings and network profiles are unchanged.

## Privacy and limits

No telemetry, uploads or updater. Data stays in `%LOCALAPPDATA%\FrameAdapter\`. Reports include timestamps, states and product/driver versions; they omit SSIDs, addresses, serials and raw log text. Review files before sharing. Delete that folder to remove saved data.

Tested on Windows 10. Windows 11 and effectiveness need independent testing. Windows connected does not mean VR streaming works. This uses standard Windows commands and is not affiliated with Valve.

Steam's install path is detected from the current user's registry. Captures also accept `-SteamRoot D:\Steam`.

## Development

```powershell
python -B -m unittest discover -s tests
powershell.exe -NoProfile -File tests\Test-FrameAdapter.ps1
powershell.exe -NoProfile -STA -File tests\Test-FramePreparation.ps1
python -B build.py --output dist
```

Tests use synthetic data and mock adapter actions. MIT license.
