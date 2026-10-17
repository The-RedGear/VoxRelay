"""Create an updater-compatible ZIP from an already verified portable build.

This only creates a local artifact; publishing a GitHub Release is explicit.
"""
import argparse
import json
from pathlib import Path
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from voice_studio_speaker_bridge.updates import safe_relative, version_key


def package_update(source: Path, output: Path, version: str, channel: str):
    key = version_key(version)
    if (key[3] != 4) != (channel == 'preview'):
        raise ValueError('Release version must match its channel')
    executable = 'YapLoq-preview.exe' if channel == 'preview' else 'YapLoq.exe'
    for name in (executable, '_internal/YapLoq.ps1', '_internal/YapLoq.xaml', '_internal/assets/ApplyUpdate.ps1', '_internal/assets/Updates.xaml'):
        if not (source / name).is_file():
            raise ValueError(f'Missing packaged resource: {name}')
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest=dict(schema=1, version=version.lstrip('v'), channel=channel, platform='windows-x64', executable=executable)
    (source/'update-manifest.json').write_text(json.dumps(manifest),encoding='utf-8')
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source.rglob('*')):
            if not path.is_file():
                continue
            relative = path.relative_to(source).as_posix()
            if relative == 'update-manifest.json':
                continue
            # Never ship the build machine's data, credentials, or caches.
            if relative.split('/')[0].casefold() in {'data', 'data-preview', 'updates', 'backups', '.git', 'src'}:
                continue
            safe_relative(relative)
            if path.is_symlink():
                raise ValueError('Linked files are not supported')
            archive.write(path, relative)
        archive.writestr('update-manifest.json', json.dumps(manifest))
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--channel', choices=['stable', 'preview'], required=True)
    args = parser.parse_args()
    print(package_update(args.source, args.output, args.version, args.channel))
