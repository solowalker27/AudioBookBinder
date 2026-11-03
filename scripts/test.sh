#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
repo="$PWD"
configuration="${CONFIGURATION:-Release}"
products="$repo/build/DerivedData/Build/Products/$configuration"
mkdir -p build
for scheme in AudioBookBinder abbinder; do
  xcodebuild -project AudioBookBinder.xcodeproj -scheme "$scheme" \
    -configuration "$configuration" -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build > "build/$scheme-$configuration.log" 2>&1 || {
      tail -80 "build/$scheme-$configuration.log"; exit 1;
    }
done
fixture_dir="$(mktemp -d "$repo/build/tests.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir" <<'PY'
import base64, math, struct, sys, wave
from pathlib import Path
root = Path(sys.argv[1])
for name, rate, channels, seconds in [('mono', 22050, 1, 1.25), ('stereo', 48000, 2, 2)]:
    with wave.open(str(root / (name + '.wav')), 'wb') as output:
        output.setnchannels(channels); output.setsampwidth(2); output.setframerate(rate)
        output.writeframes(b''.join(struct.pack('<h', int(12000 * math.sin(2 * math.pi * 440 * i / rate))) * channels for i in range(int(rate * seconds))))
# Sparse long-source metadata fixture: reproduce millisecond validation after a
# 13-hour conversion without encoding hours of audio or allocating its payload.
frames = 390032393
size = frames * 2
with (root / 'import-duration.wav').open('wb') as output:
    output.write(struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', size + 36, b'WAVE', b'fmt ', 16, 1, 1, 8000, 16000, 2, 16, b'data', size))
    output.seek(44 + size - 1)
    output.write(b'\0')
(root / 'cover.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII='))
PY
afconvert -f m4af -d aac "$fixture_dir/mono.wav" "$fixture_dir/input.m4a"
xcrun clang -fobjc-arc -DNS_BLOCK_ASSERTIONS=1 -mmacosx-version-min=13.0 \
  -I. -Ithird_party/mp4v2/include -Ithird_party/mp4v2/xcode/include \
  Tests/CoreTests.m AudioBinder.m AudioFile.m AudioBookVolume.m Chapter.m ChapterList.m \
  MP4File.m MP4Atom.m CoverImageView.m ABBLog.m -x objective-c++ MetaEditor.mm \
  -x none "$products/libmp4v2.a" -framework Cocoa -framework AudioToolbox \
  -framework CoreServices -lc++ -o build/CoreTests
build/CoreTests "$fixture_dir"
"$products/abbinder" -q -a 'CLI Author' -t 'CLI Book' -E 'Chapter %N' \
  -C "$fixture_dir/cover.png" -o "$fixture_dir/cli.m4b" "$fixture_dir/mono.wav" "$fixture_dir/stereo.wav"
afinfo "$fixture_dir/cli.m4b" > build/cli-audio-info.txt
python3 Tests/cli_tests.py "$products/abbinder" "$fixture_dir"
printf 'All build and integration checks passed (%s).\n' "$configuration"
