# Validation record

Validated October 25, 2026 on Apple silicon running macOS 27.0.1 (26A434),
using Xcode 27.1 and the macOS 27.0 SDK. The deployment target is macOS 13.

## Automated checks

Both `./scripts/test.sh` and `CONFIGURATION=Debug ./scripts/test.sh` passed:

- Universal arm64 and x86_64 builds of the app, CLI, and MP4 library.
- 75 core integration assertions in each configuration.
- WAV and AAC inputs with different sample rates and channel counts, real AAC
  encoding, and independent Core Audio decoding with nonzero audio samples.
- Stereo-to-mono conversion, mono-to-stereo conversion, output durations, and
  bitrate discovery.
- Unicode title/author metadata, audiobook media type, narrator/composer,
  track numbers, PNG artwork, and repeated metadata updates.
- QuickTime chapter count, Unicode names, timing, and playable audio after
  metadata and chapter editing.
- Cancellation and early/later-volume failures preserve pre-existing outputs.
  Input paths and hard-link aliases are rejected as output destinations.
- Binder reuse resets duration; cancellation leaves input duration intact.
- Extensionless artwork and truncated atom headers are handled safely.
- CLI validation rejects invalid rates/channels/bitrates/volume lengths,
  conflicting chapter options, malformed UTF-8, and empty input lists.
- Two actual 1,801-second sources split at the one-hour limit, producing
  correctly named files and preserving the chapter boundary. `ffprobe`
  independently verified durations and chapter titles on this machine.

An additional MP3 generated with FFmpeg was converted using the Release CLI.
FFprobe verified its AAC output, title and chapter. FFmpeg decoded the output
and the signal RMS was checked. MP3 decoding requires access to macOS audio
codec services; Codex's restricted command sandbox blocks those services, so
this check was run with normal host access.

The suite uses generated fixtures in a temporary folder under `build/` and
removes them on exit. No personal audio is used. `ffprobe` is optional; the core
encoding/decoding and metadata tests use only system frameworks and the
repository's pinned MP4 library.

## GUI checks

The Release app was locally ad-hoc signed with its App Sandbox entitlements
and hardened runtime, then launched and operated through native UI automation.
These checks passed on this Mac:

- Startup, metadata entry, native Open/Save panels, and audio import.
- AAC audiobook export outside Music, using sandbox-compatible replacement
  directories; the resulting M4B was inspected independently with FFprobe.
- Export with empty title/author still writes chapter markers.
- Repeated export, native overwrite confirmation, and successful replacement.
- Chapter expansion, preview, playback completion, row selection, removal,
  disabled toolbar actions, and return to the empty state.
- Files/artwork navigation, native Liquid Glass controls, and window zoom.
- Follow-up: removed the extra glass wrapper around the section picker;
  rebuilt the universal Release app and visually verified both native segments.
- No obsolete destination-folder migration prompt in the standard build.

GUI exports and inspection results are retained under `build/ui-fixtures/`
and `build/gui-export-validation.json`. MP3 inspection is recorded in
`build/mp3-validation.json`. Build/test logs are in `build/`.

## Limits

Intel binaries compile but were not run on Intel hardware. macOS 13–26 runtime
behavior, light appearance, Reduce Transparency, the App Store configuration,
and cloud/removable export locations have not been separately exercised.
Native AppKit materials and availability checks provide the compatibility
paths; these are not substitutes for testing on those systems.

Audio encoding is staged before outputs are installed. Metadata/chapter
processing follows installation; a metadata error is reported, but does not
restore the previous version of an already installed audiobook.

The local app is ad-hoc signed for testing on this Mac. Developer ID signing,
notarization, and App Store submission were not performed. The new GitHub
Actions workflow has been added but has not run remotely in this session.

## Existing audiobook metadata editing — November 1, 2026

`./scripts/test.sh` passed with universal arm64/x86_64 Release builds, 708 core
integration assertions, CLI validation, and real hour-long volume splitting.
The expanded core checks cover loading current tags, Unicode text editing,
clearing fields, adding/replacing/removing artwork, narrator replacement,
unrelated standard/custom tags, and preservation of media flags and volume
numbers. Compressed audio sample payloads and chapter names/durations are
compared before and after edits. Invalid artwork and stale editors fail
without modifying the original file.

The ad-hoc signed Release app was exercised with App Sandbox entitlements:
File > Edit Audiobook Metadata, its native file/cover pickers, Command-S,
save and reopen, and unsaved-change prompts for close and quit all passed.
Discarding edits preserved the file’s SHA-256 hash. FFprobe independently
confirmed saved tags/artwork and identical audio packet hashes/timing and
chapter metadata. Only copies of generated fixtures were edited.

UI fixtures and inspection results are in `build/metadata-ui-fixtures/` and
`build/metadata-ui-{before,after}.json`; the automated run is recorded in
`build/metadata-tests.log`. This workflow stages metadata edits before
replacing the original; the conversion workflow’s limitation above is unchanged.

## Existing audiobook chapter editing — November 1, 2026

`./scripts/test.sh` passed with universal Release app/CLI builds, 1,569 core
integration assertions, CLI validation, and real hour-long volume splitting.
Chapter tests cover loading QuickTime/Nero markers; Unicode renaming without
altering timings; insertion, retiming, deletion, and clearing all markers;
adding chapters to an unchaptered book; and keeping dual-format markers in
sync. Invalid, duplicate, unordered, and out-of-range times, embedded nulls,
UTF-8 title limits, and timestamp overflow are rejected before replacement.
Audio presentation duration excludes AAC priming/padding. Chapter-only saves
preserve unrelated metadata atoms, including explicitly empty tags. Compressed
audio payloads remain byte-for-byte identical after all chapter operations.

The sandboxed, ad-hoc signed Release app was used to double-click/edit chapter
titles and start times, split a chapter with Add Chapter, save, reopen, and
remove a marker. Invalid time entry displayed an error and left the original
file unchanged. FFprobe independently verified the saved names and boundaries,
unchanged book duration and all metadata tags, and identical audio packet
hashes/timestamps after both insertion and removal. Only generated fixture
copies were edited. Results are in `build/chapter-ui-{before,after,removed}.json`,
the fixture is in `build/chapter-ui-fixtures/`, and the suite log is
`build/chapter-tests.log`.

## Chapter-list import validation (November 2, 2026)

`./scripts/test.sh` passed with universal Release app/CLI builds and 1,709 core
integration assertions, plus CLI integration checks. New coverage includes:

- Standard Audacity point/region labels, six-decimal timestamps, UTF-8 BOM,
  CRLF, Unicode titles, and millisecond rounding.
- FFmpeg metadata with explicit rational and default nanosecond timebases,
  global/stream tags, escaped punctuation, and continued title lines.
- Empty/malformed lists, duplicate or out-of-order starts, nonzero first starts,
  timestamps outside the audio, invalid timebases/overflow, and invalid UTF-8.
- Embedded file-relative chapters within one continuous source and grouped
  sources, including byte-for-byte compressed-audio preservation.
- CLI imports in both formats, independently inspected with ffprobe for exact
  start times and Unicode titles; conflicting options and failed imports
  preserve existing output bytes.

An isolated copy of the Release app was operated through native UI automation:
added a generated four-second WAV, imported two Audacity labels through
Chapters > Import Chapters…, reviewed the preview, checked the expanded chapter
list visually, and exported an M4B. ffprobe verified titles and starts at zero
and 1.5 seconds, with the final chapter ending at four seconds. The exported
book was reopened in the metadata editor and its Chapters tab displayed both
markers and the new Import Chapters… control. Fixtures are under
`build/chapter-import-ui/`. The user's existing app process and audio were not
modified. Existing macOS/Intel runtime limitations above still apply.

### Long-source reimport regression

The follow-up Release suite passed 1,716 core assertions and all CLI checks.
A sparse 13-hour WAV fixture reproduces a stored output duration one millisecond
shorter than the source; import now validates against the preserved original
source duration. Actual encoding also checks nearest-millisecond duration
rounding. The conversion calculation now uses double precision rather than
promoting the entire expression to float through the sample-rate property.
A read-only check of the reported source and matching FFmpeg list reproduced
45 valid chapters before conversion, rejection with the old 48,754,048 ms
value, and successful import with the corrected 48,754,049 ms value. No source
audio or chapter-list files were modified. Timing errors now identify the
chapter and its timestamps alongside the audio duration.
