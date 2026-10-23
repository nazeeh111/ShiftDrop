# Verification

Release 0.2.0, checked 2026-10-22 on Apple silicon, macOS 26.6.2 and Swift 6.4. macOS 13 is the deployment target; older systems were not exercised locally.

## Automated checks

The production suite passed **88 tests with zero failures**: 71 core and 17 utility tests. An additional accessibility activation/geometry test then passed, for **89 distinct passing tests** in the final source. Commands used a disposable local scratch directory, `swift test --disable-sandbox --jobs 2 --scratch-path /private/tmp/shiftdrop-utility-final`, followed by a scoped `WheelAccessibilityTests` run. Installed FFmpeg/ffprobe and LibreOffice exercised the optional-engine cases with no skips. Hosted CI runs the complete final suite separately.

Fixtures decode or reopen actual results. Coverage includes image orientation/transparency/resizing, exact crop pixels, layered annotations/redaction, SVG resource rejection, multipage/rotated PDFs, document/archive conversions, FFmpeg media operations, filename collisions, source preservation, cancellation, queue state and fresh-drag timing. Exact format and fidelity limits are in [FORMATS.md](FORMATS.md) and [TOOLS.md](TOOLS.md).

New utility-specific checks cover:

- All radial choices remain reachable for lists of 1 through 24; the safe center and exterior perform no operation.
- Accessibility operations activate their corresponding choice and expose frames aligned with the drawn sectors.
- Beside-source defaults, custom destinations, per-file destination snapshots and quiet error reporting.
- Tools spanning different parent folders, combined-result placement, collision preservation, cancellation and rollback when a later preparation/publication fails. Folder compression stages outside selected sources.
- Six gesture-state regressions: late pasteboard publication, delayed readable URLs, held modifiers, mode changes, cancellation and stale drag data.

Specific fixture success does not establish arbitrary codec/document compatibility, universal reliability or performance superiority.

## Real Finder acceptance

The final packaged release was extracted into local temporary storage and its signature verified. For isolated UI testing, only the copied bundle's identifier was changed and it was re-signed; production source/executable bytes were unchanged. The existing production instance was left running.

The user authorized a native system-input driver using a disposable image. It used already available event-posting/accessibility permissions without requesting or changing them. ShiftDrop's own modifier/drag observation does not require those permissions.

Observed on the stated host:

- First launch and reopening stay in accessory/menu-bar mode with zero dashboard windows.
- Repeated actual Finder drags in both key orders, drag then Shift and Shift before drag, open the radial wheel. Releasing Shift leaves it available until the drop.
- Dropping on JPEG creates a newly decoded **1024 × 1024 JPEG beside the original**. The source SHA-256 remains unchanged. Repeat drops preserve existing outputs through numbered filenames.
- Command opens the correct tools wheel; a real Compress drop opens its editor with the source and beside-original destination.
- Control exposes all six actions. No AirDrop transfer or Terminal command was executed by the test.
- Escape cancels Finder's drag and dismisses the wheel. A subsequent ordinary Shift-click does not reopen it from old pasteboard data.
- A compact job panel shows completed results. Screenshots used in the presentation are from running native windows; the presentation adds explanatory motion between captures.

macOS displayed a Documents access prompt during an earlier protected-folder check. That prompt was left unanswered; a worker waiting for protected file access did not establish conversion failure or success. Acceptance used an expressly disposable local temporary fixture. Protected-folder access and cloud-only file availability remain subject to macOS permissions and downloading. No privacy settings were changed.

These are single-display Finder checks. Multiple displays, Spaces/fullscreen, third-party drag sources, AirDrop delivery and launch-at-login registration were not exercised. Repeat manually with a nonprivate local image: drag then hold Shift, release Shift and drop on JPEG; repeat with Shift already held, check the adjacent copies, try Command/Control and cancel another drag with Escape.

## Earlier engine checks

The 0.1.1 validation additionally exercised native tool previews and saved 640 × 640 compression and 320 × 240 crop outputs. Independent file-move checks used a disposable HFS+ disk image beside APFS: byte preservation, empty directories, Unicode/collision names, verified-copy-before-removal, nested-link rejection and partial-error reporting. Those historical checks are not new 0.2.0 runtime coverage. Removable/exFAT/network volumes remain untested.

## Package and release

Packaging builds in disposable local storage, validates Info.plist, sets `LSUIElement=true`, ad-hoc signs and strictly verifies the bundle, then creates a ZIP. Build concurrency defaults to two jobs (`SHIFTDROP_BUILD_JOBS` can select 1–64). The ZIP, rather than a cloud-synced extracted bundle, is the distributable: Finder metadata added by cloud storage can invalidate an extracted signature.

GitHub CI, public release metadata and a downloaded release ZIP are checked separately at publication: matching SHA-256, strict extracted signature verification, version readback and a real command-line subtitle conversion. CI status is visible through the repository badge; release asset checksums accompany the download.

The prebuilt binary targets Apple silicon and is **not Apple notarized**. Downloaded-app Gatekeeper acceptance, Intel runtime and older macOS runtime were not tested. Pages documents remain unsupported. No exact feature parity with another utility is claimed.
