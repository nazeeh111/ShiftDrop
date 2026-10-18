# Format guide

The menu offers routes for the input's family and installed helpers. A listed route can still fail for damaged input, unavailable codecs, locked documents or a particular encoder build. This project does not claim the reference product's advertised conversion count.

| Family | Inputs | Outputs and behavior |
| --- | --- | --- |
| Images | PNG, JPEG, TIFF, HEIC/HEIF, BMP, GIF, WebP, AVIF, JPEG2000, ICO, ICNS, SVG | Native PNG/JPEG/TIFF/HEIC/BMP encoders when advertised by macOS; PDF. FFmpeg adds WebP/AVIF/GIF. Still exports use the first image frame. SVG is sanitized, rejects external resources/scripts/foreign objects, and rasterizes within bounds. |
| PDF | PDF | Every page to PNG/JPEG/TIFF; selectable text to TXT, DOCX, RTF, HTML, Markdown or EPUB. PPTX contains page images, not editable page elements. XLSX puts each selectable text line in a row, not reconstructed tables/formulas. Scans require existing text; no OCR reconstruction. |
| Documents | TXT, Markdown, RTF, HTML, DOC/DOCX, ODT, RTFD, Finder text clippings, EPUB | TXT, RTF, HTML, Markdown, PDF, EPUB; native macOS textutil adds DOC/DOCX/ODT/RTFD. Markdown is rendered for rich exports. Native PDF reflows text; LibreOffice can retain more Office layout. EPUB/text exports do not preserve embedded images or original page layout. RTFD attachments are not placed in native text PDFs. |
| Spreadsheets | XLSX, XLS, ODS, CSV, TSV | LibreOffice required: PDF, XLSX, XLS, ODS, CSV, TSV. CSV/TSV contain the first sheet's values and lose formulas, styles and extra sheets. |
| Presentations | PPTX, PPT, ODP | LibreOffice required: PDF, PPTX, PPT, ODP; PNG/JPEG via every PDF page. Fonts and complex effects depend on installed software. |
| Subtitles | SRT, VTT | SRT/VTT with millisecond timestamps; TXT without timing. VTT positioning/style/comments do not survive SRT. Invalid or reversed timestamps fail. |
| Video | MP4, MOV, MKV, WebM, AVI, WMV, M4V, MPEG, TS/MTS/M2TS, FLV, 3GP | FFmpeg required: MP4/MOV/MKV/WebM/AVI/WMV, GIF, or audio formats below. First video/audio stream. Even dimensions may be required. Audio export fails if no audio exists. |
| Audio | M4A, MP3, WAV, FLAC, AIFF, AAC, OGG, Opus, WMA | FFmpeg required: M4A/MP3/WAV/FLAC/OGG/Opus/AIFF/WMA. Encoding cannot recover detail already lost in a source. |
| Archives | ZIP, TAR, TAR.GZ/TGZ, GZIP and libarchive-readable inputs including RAR | Extract into a new folder, or repack ZIP/TAR/TAR.GZ. Local files/folders can create those archives; single files can create GZIP. No RAR encoder. Links, unsafe paths, duplicate entries and expansion beyond bounded limits are rejected. |

Apple Pages is not integrated. A `.pages` extension is not treated as a convertible document or silently renamed. Password-protected/encrypted formats and OCR layout reconstruction are not implemented.

JPEG/BMP flatten transparency against white. Native still exports remove source metadata and multipage/animation structure. Quality and maximum dimension are configurable; image tools provide separate detailed controls. GIF encoding changes timing/palettes and uses bounded resolution.

Native image decoding/rendering is bounded to 80 million pixels and dimensions up to 16,384. PDF jobs allow up to 1,000 pages. Text imports are bounded to 32 MiB; Office containers and archive expansion have additional bounds enforced before decoding. Large or complex files may be rejected. Archive extraction limits include 10,000 entries, 512 MiB total and 128 MiB per file.

Processing runs locally. FFmpeg receives a local protocol allowlist; Office/textutil subprocesses deny network access. ShiftDrop contains no telemetry or upload service. This does not prove universal network isolation of the OS or every installed external helper.

See [TOOLS.md](TOOLS.md) for editing, metadata, previews and actions, and [VERIFICATION.md](VERIFICATION.md) for checks actually performed.
