# Changelog

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
