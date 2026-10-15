"""Build a source ZIP from an explicit file list."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'diagnostics'))
from frame_diagnostics import VERSION

FILES = (
    'FrameAdapter.ps1', 'Start.cmd', 'README.md', 'LICENSE', 'build.py',
    'diagnostics/Capture-FrameSession.ps1', 'diagnostics/Start-FrameTrial.ps1',
    'diagnostics/frame_diagnostics.py', 'diagnostics/diagnosis.py',
    'tests/Test-FrameAdapter.ps1', 'tests/Test-FramePreparation.ps1',
    'tests/test_frame_diagnostics.py', 'tests/test_diagnosis.py',
    'examples/capture.json', 'examples/steam.txt', 'examples/recovery/action.json',
    'examples/trial/trial.json', 'examples/trial/baseline.json', 'examples/trial/after.json',
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    package = args.output / f'FrameAdapter-{VERSION}.zip'
    contents = {}
    for name in FILES:
        path = ROOT / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f'Invalid package input: {name}')
        data = path.read_bytes()
        if name.endswith('.cmd'):
            data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        contents[name] = data
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    contents['source-manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    with zipfile.ZipFile(package, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in contents.items():
            entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    with zipfile.ZipFile(package) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(contents):
            raise ValueError('Package verification failed')
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    package.with_suffix('.zip.sha256').write_text(digest + '  ' + package.name + '\n', encoding='utf-8')
    print(package)
    print('SHA256 ' + digest)


if __name__ == '__main__':
    main()
