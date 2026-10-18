# ShiftDrop tool guide

Tools produce new copies. Open File Tools from the menu bar, the File menu, or a Tools shelf drop. Add files, choose a compatible tool, arrange input order when combining, then render a preview before saving a copy.

A rendered preview is actual output in a temporary directory, not a drawing of a proposed result. Saving runs the same operation in the destination folder. Changing settings clears the displayed result. Use Show original/Show result, media playback, or the text report to inspect it. Preview work can take as long as an export; Cancel stops the active task and cleans up unfinished output.

## Coordinates, order, and output

Image and video rectangles use integer pixels measured from the **top-left** of the displayed, orientation-corrected image or video. `x` and `y` locate the left/top corner; `width` and `height` describe its extent. A crop or manual cover must fit wholly within the source. On the original image preview, drag to create a rectangle, or draw a path for freehand/highlight annotations. Numeric fields give exact control.

Time values are seconds. `start` is inclusive and `end` must be later and within the media duration. Page numbers are 1-based. Inputs combine in the order shown at the left, not alphabetical filename order.

Most image edits produce PNG. Image compression produces JPEG and flattens transparency against white. Images to PDF produces one page per image at the image's pixel dimensions in PDF points. Edited video is H.264/AAC MP4; edited audio is float PCM WAV, except compressed audio is AAC in M4A. Metadata edits preserve a media container when the installed FFmpeg build can remux it. A tool can produce a file plus a JSON report, or multiple image/clip outputs.

## Image tools

Image tools use native Core Graphics, ImageIO, Core Image, Core Text, and Vision. They do not require FFmpeg. They accept still-image inputs; animated and multipage sources are rejected instead of silently losing frames. Convert or extract an individual frame/page first. Image decodes and output canvases are limited to 16,384 pixels per side and 80 million pixels total. A request accepts at most 1,000 images; a large source or canvas can still require substantial memory.

| Tool | Settings and result |
| --- | --- |
| Adjust photo | Exposure changes stops of light. Brightness adds a tonal offset. Saturation and contrast default to 1. Sharpness uses luminance sharpening; noise reduction smooths small variations. Dehaze tone applies a contrast-oriented tone curve, clarity applies local contrast with an unsharp mask, and grain blends generated luminance noise. These are bounded photographic adjustments, not scene reconstruction. Output dimensions stay the same. |
| Crop image | Exact `x`, `y`, `width`, `height`. Aspect-ratio presets change the draft rectangle; they do not add padding. Output dimensions equal the rectangle. |
| Add background | `width`/`height` are the final canvas. Padding reserves space around an aspect-fitted foreground. Choose a solid six-digit RGB color or a local background image. Background images fill the canvas with cropping. Background blur blurs that fill; with no chosen background image it uses an enlarged copy of the foreground. Corner radius rounds the foreground, and Shadow adds an alpha-aware drop shadow. |
| Annotate photo | Text, arrow, rectangle, ellipse, numbered marker, magnifier, image overlay, freehand, and highlight. Coordinates, color, font size, and line width belong to each mark. Text wraps inside its rectangle and rejects overflow. An overlay fits the chosen image proportionally in its rectangle. The magnifier is a circular 2× view of the selected source rectangle with an outline. |
| Redact photo | A solid color cover is the default. Stored manual rectangles and locally detected face/text rectangles are combined. With no stored rectangles and no detection, the current draft rectangle is used. A new PNG contains the rendered pixels rather than editable cover objects. Blur is a visual effect and can leave identifying information. Detection can miss content; inspect the result. |
| Make collage | `width`/`height` describe **each cell**. Columns determine the grid; padding applies between cells and around the outside. Images fit their cells in input order, left to right then top to bottom. Background color fills unused space; corner radius rounds each picture. |
| Images to PDF | Combines images in input order, with one page per input and source proportions preserved. It creates an image PDF, without selectable text or OCR. |

Supported engine adjustment ranges are exposure −10…10, brightness −1…1, saturation 0…3, contrast 0…4, sharpness 0…2, and noise reduction/dehaze/clarity/grain 0…1. The UI offers narrower ranges for some controls. Blur and shadow use 0…100 pixels; zero disables them. Padding is 0…4,096 pixels, corner radius 0…8,192, and collage columns 1…100. The resulting canvas must still fit the pixel limits.

### Annotation layers and paths

Without stored layers, the draft mark is rendered directly. **Add layer** stores it. Select a layer to load its controls, change them, and choose **Update selected**. Reorder or remove layers using the list. When layers exist, only stored layers are exported, in array order; add or update the draft before rendering.

Arrow direction uses four quarter turns: 0° points down-right, 90° down-left, 180° up-left, and 270° up-right. Numbered markers accept a short label of 1–8 characters. Their label contrast adjusts to the cover color. Freehand and highlight paths need at least two points inside the source. Highlights use a translucent multiply blend. Layer image overlays use the chosen local image and preserve its supported alpha channel.

The API represents a layer with `ImageMark(kind:region:text:colorHex:fontSize:lineWidth:rotation:points:imageURL:)`. `ToolPoint` coordinates are doubles in top-left source pixels. `ToolRegion` uses integer `x`, `y`, `width`, and `height`. `ToolSettings.marks` holds layers, `points` holds the draft path, and `regions` holds stored manual redaction rectangles. Up to 256 layers, 4,096 cover regions, and 100,000 points per path are accepted, with at most one million stored layer points total.

### Image compression and metadata

Compression first fits the source into the maximum width and height without enlarging it. Quality controls the JPEG encoder. A zero byte target means quality-only encoding. A positive target applies to **each image**: the engine searches JPEG quality and, when necessary, reduces dimensions further. It returns an output that fits or a clear error for an impossible target. A quality-only result can be larger than the original.

SVG inspection reports validated file information and raster dimensions, not embedded vector metadata. For raster-image metadata, turn removal off and leave the title empty to export a JSON report, including frame count and ImageIO properties. Removal creates a fresh PNG without copying the source metadata. A nonempty title writes supported PNG/TIFF title information; with removal off it also carries metadata supported by the PNG encoder. This is a re-encode, not a lossless rewrite of the original container. It does not promise preservation of every original metadata field or certification that every identifier has been removed.

## Video tools

These tools require an installed FFmpeg build and accept 1–32 media inputs. They validate stream availability and use new outputs. Lossy re-encoding can change quality, pixel values, frame timing, and metadata.

| Tool | Settings and result |
| --- | --- |
| Trim video | `start`/`end` choose a precise re-encoded interval. |
| Crop video | A top-left pixel rectangle inside the frame. Width and height must be even for H.264 output. |
| Change speed | `speed` supports 0.125×–8× in the engine. Video timestamps and audio tempo change together; audio pitch is preserved. Silent video is supported. |
| Join videos | Inputs combine in list order. Frames are normalized to the first clip's dimensions, preserving proportions with padding. Clips without audio receive silence when another clip has audio. |
| Save frames | `start`/`end` bound the sample interval. `parts` is the number of evenly spaced PNG snapshots, starting at `start` and excluding the endpoint. Accepts 1–120 frames per source, up to 240 per request. |
| Split video | `splitPoints` is an increasing comma-separated list of seconds, such as `2.5,8`. Empty uses `parts` equal segments, from 2 to 32. Every segment must last at least 0.05 seconds. Up to 128 output clips per request. |
| Redact video | A fixed pixel rectangle is covered with the selected color or a blur. `limitTimeRange` applies it only between `start` and `end`; otherwise it covers the entire clip. This does not track a moving subject. Video redaction is manual, not face detection. |

Media compression targets a smaller MP4 or M4A. A positive byte target is a per-file ceiling; zero asks the engine to produce something smaller than its source. Duration and stream layout constrain achievable sizes. Up to three bitrate attempts run before a failure is reported. A source/target below 16 KiB is rejected. Resizing, quality, and target settings should be inspected in the generated preview rather than treated as a guarantee of visual fidelity.

## Audio tools

| Tool | Settings and result |
| --- | --- |
| Trim audio | `start`/`end` select the interval. Remove edge silence detects audio below −50 dB for at least 0.1 seconds at the edges, preserving internal pauses. |
| Normalize volume | `loudness` is the target integrated loudness in LUFS, a measure of perceived loudness. `truePeak` limits reconstructed playback peaks in dBTP. `loudnessRange` sets the target variation. Defaults are −16 LUFS, −1.5 dBTP, and 11 LU. A JSON report contains measured input/output levels alongside the WAV. Remove silence trims edges when enabled. |
| Audio channels | `channels` is 1 or 2. Source layouts are normalized to stereo; independent `leftGain` and `rightGain` values are then applied. Mono uses their equally weighted sum. Gains of 0 mute a channel; 1 preserves its level. The engine accepts gains up to 4. Solo previews alter actual output gains: restore both channels before saving if you want both. |
| Bleep audio | Replaces the selected `start`…`end` samples with a 1 kHz tone. It does not mix the original speech under the tone. Material outside the interval stays audible. |
| Audio visualizer | Creates a video for the full audio duration at the selected width/height. Choose a background color or local still image and waveform color. With waveform disabled, it creates a still-background audio video. |

Normalization engine limits are −70…−5 LUFS, −9…0 dBTP, and 1…50 LU. Measurement can fail for recordings too short for a complete loudness report. An installed FFmpeg build and its codecs determine available media support.

## PDF tools

PDF tools use PDFKit and Core Graphics, accepting 1–32 readable, unlocked PDFs and at most 1,000 source pages per request.

| Tool | Settings and result |
| --- | --- |
| Merge PDFs | Copies pages in input-file order. Requires at least two PDFs. Metadata removal/title settings apply to the combined document. |
| Organize pages | `pageOrder` accepts 1-based numbers and ranges, for example `3,1-2,2` or `5-1`. Repeats duplicate pages; omitted numbers remove pages from the new copy. Empty keeps every page. `rotation` adds a quarter turn to every selected page. `pageRotations`, such as `1:90,3:180`, adds rotation by **output position**, so repeated copies can rotate independently. The thumbnail organizer offers a visual route to the same settings. |
| Compress | Renders pages to JPEG-backed PDF pages. `width` is the maximum raster dimension, 64–8,192 pixels; quality is 0.05–1. Visible annotations are flattened. The new PDF loses selectable text, forms, links, and vector detail. `height` and the byte target do not control this PDF operation. At most 32 million pixels per page and 500 million per file are rendered. |
| Metadata | Removal off plus an empty title exports document-info attributes and page geometry to JSON. Otherwise a new PDF clears document-info attributes when requested and sets the optional title. This does not inspect or remove every embedded object, attachment, XMP field, or hidden identifier. |

## Other files, actions, and safety

General Compress creates ZIP output. General Metadata writes filesystem information such as name, bytes, dates, and type; it does not edit or sanitize arbitrary file contents. Converting archive formats and extracting them belong to the main conversion queue; see the format guide for supported readers and bounded extraction.

AirDrop, Float, Copy files, Move, Copy paths, and Terminal are file actions rather than converters. Move relocates originals only after its confirmation dialog. The others use references, clipboard data, system sharing, or containing folders. Removing an item from the queue or floating shelf does not remove its source file.

Converters and editing tools preserve originals, allocate unique output names, and stage unfinished work beside the output destination. They reject symbolic-link inputs where following them would violate the selected file scope. Errors are reported without treating a partial, unavailable, or failed codec path as a completed conversion. Preview files are temporary and are replaced or removed when preview work is cleaned up; save a copy to keep a result.
