# Changelog

## 0.2.0 · 2026-10-22

- Rebuilt the normal interaction around Finder: quiet first launch/relaunch, no Dock icon, no dashboard.
- Replaced the rectangular shelf with a native radial wheel at the pointer. Format, tool and action sectors share drawing/hit-test geometry, with a safe center and two rings for longer lists.
- Converted copies save beside each original by default; custom output folders remain available.
- Added compact job progress/results and independent Settings/Guide windows; editors open only on demand.
- Preserved background queueing, cancellation and collision-safe new output.
- Verified real Finder gestures in both key orders, adjacent JPEG copies, tool-editor drops, cancellation and stale-drag rejection; added radial accessibility and mixed-folder placement coverage.


## 0.1.1 · 2026-10-18

- Fixed missed drag shortcuts when the modifier arrives before Finder publishes fresh drag data or before file URLs become readable.
- A modifier held before a fresh file drag now opens its shelf. Old drag contents still cannot trigger the shelf during an ordinary Shift-click.
- Verified the packaged build with real Finder input: repeated PNG drops in both key orders, Command/Control workflow selection, Escape cancellation, source preservation and decoded output checks.
- Added focused gesture regression coverage. The full local suite passed 76 tests; hosted checks are visible in GitHub Actions.
- Improved download/install guidance, README navigation and build/release badges; added a structured bug-report form.

## 0.1.0 · 2026-10-18

- Initial native menu bar app and optional conversion/editing studio.
- Batch conversion, 23 file-tool families, six file actions and configurable drag modifiers.
- Local native engines with optional installed FFmpeg/ffprobe and LibreOffice.
- Collision-safe new outputs, cancellation, rendered previews and format-specific limitations documented in the guides.

Prebuilt releases are for Apple silicon and use an ad-hoc signature. They are not Apple notarized.
