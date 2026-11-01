#!/bin/bash
# Personal-use package. This does not claim Developer ID signing or notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIGURATION=Release scripts/build.sh
app="build/Build/Products/Release/Mochlet.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/Mochlet")
test "$archs" = arm64
mkdir -p dist
output=$(mktemp -d "dist/Mochlet-${version}-arm64-XXXXXX")
complete=0
trap 'if [[ "$complete" = 0 ]]; then rm -rf -- "$output"; fi' EXIT
ditto -c -k --keepParent "$app" "$output/Mochlet.zip"
python3 - "$output" "$version" "$minimum" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
output, version, minimum = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
archive = output / 'Mochlet.zip'
hasher = hashlib.sha256()
with archive.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        hasher.update(chunk)
digest = hasher.hexdigest()
manifest = {
    'product': 'Mochlet', 'version': version, 'architecture': 'arm64',
    'minimumOSBuildSetting': minimum, 'configuration': 'Release',
    'signing': 'local ad-hoc; not notarized', 'archive': archive.name, 'sha256': digest,
    'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'workingTreeDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
    'validationLimits': 'macOS 15 compatibility, live audio/provider matrix, two-hour mixed soak and public distribution signing remain unverified.'
}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(output / 'SHA256SUMS').write_text(digest + '  Mochlet.zip\n')
print('Local package:', archive.resolve())
PY
complete=1
