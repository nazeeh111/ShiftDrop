# Verification

Release candidate 0.1.0, checked 2026-10-18 on Apple silicon, macOS26.6.2, Swift6.4. macOS13 is the deployment target, not local runtime coverage of every supported OS.

## Automated checks

The complete production package suite passed **73 tests with zero failures**:64 core and9 app/browser tests. It exercises native conversion, editing engines and app state. Final command: `swift test --scratch-path /private/tmp/shiftdrop-integrated-final`. The final run exercised optional engines with no skipped cases.

Fixtures decode or reopen generated files. Coverage includes:

- Image orientation/transparency/resizing, exact crop pixels, solid and multiple redaction regions, local detection, every annotation mode, ordered layers, frame shadows/backgrounds, collage geometry, byte targets, metadata and multi-image PDFs. SVG source/background/overlay rendering and encoded external-resource rejection are exercised.
- Multipage/rotated PDFs, selectable text and scan failure, page ranges/repeats/independent rotations, annotation flattening and raster compression.
- Native DOC/DOCX/ODT/RTFD, real Finder resource-fork clippings, Markdown/EPUB, PDF-derived OOXML reopened by LibreOffice, and LibreOffice-produced spreadsheet/presentation conversions. Fidelity limits remain in the format guide.
- FFmpeg output decoding, media speed/pitch, mixed silent joins, precise trim/split/snapshots, timed covers/blur, channel gains, bleeps, waveform/static backgrounds, and measured loudness reports.
- Archive traversal/link/duplicate/expansion rejection, extraction and repacking; no source-directory mutation when rejecting nested destinations; filename collision concurrency, source preservation, cancellation and bounded subprocess diagnostics.
- Queue scopes, automatic busy-drop continuation, cancelling pending work, current per-file formats, duplicate handling, quiet drops, file-browser navigation and fresh-drag state that rejects stale pasteboard data during ordinary modifier-clicks.

The full test run uses installed FFmpeg/ffprobe and LibreOffice, so optional-engine cases were exercised rather than merely counted as skipped. Specific fixture success does not establish arbitrary codec/document compatibility.

Independent file-move verification used a disposable HFS+ disk image as a second volume beside the host APFS filesystem. It checked file/folder bytes, empty directories, Unicode names, collision names, source removal only after verified copying, nested-link rejection, and accurate partial-error paths. The volume was detached after testing. Removable/exFAT/network volumes remain untested.

## Native app checks

A packaged release build was launched through the actual native UI. The earlier conversion-studio check selected three fixtures, changed the subtitle format, and completed PNG/TXT/VTT. Disk readback confirmed1024×1024 image dimensions and the1.200–3.400 second subtitle cue. Finder Open With and the command line accepted actual file URLs.

Expanded app checks opened File Tools, changed image maximum width to640, rendered an actual temporary preview, selected a custom destination with the native file browser, and saved a640×640 JPEG. The crop tool saved a320×240 PNG. Both dimensions were read from the generated files. The compact shelf opened through Command-Shift-D and showed all three workflow tabs and six file actions. Screenshots in assets are captures of running native windows.

The global Finder drag-plus-modifier trigger remains a manual acceptance item. Native automation rejected modifier-only key input, so its end-to-end behavior across Finder, Spaces and multiple displays was not established by automation. Public drag/modifier polling and queue/drop handlers are implemented; this is not a claim that every desktop interaction was observed. AirDrop delivery and launch-at-login registration were not activated during testing.

The host's system file panel stalled in iCloud File Provider, reproduced independently. ShiftDrop uses an in-process native file browser without changing global system settings.

## Package and release

The packaging script builds a release executable in disposable local storage, validates Info.plist, ad-hoc signs and verifies the app, then creates a ZIP. The locally built ZIP was extracted outside the cloud-synced workspace; its ad-hoc signature passed strict verification and its command-line subtitle conversion succeeded. The app copied into this iCloud-synced workspace subsequently acquired Finder metadata and failed the same signature check; the staged ZIP is the verified distributable. GitHub repository/tag/assets and the downloaded ZIP are checked separately after publication. Hosted CI status is reported separately from local checks.

The downloadable build targets Apple silicon and is not Apple notarized. Downloaded-app Gatekeeper acceptance, Intel runtime, older macOS runtime and universal binaries were not tested. Building from source is supported. No performance advantage or exact feature parity over another product is claimed.
