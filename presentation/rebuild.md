# Rebuild the ShiftDrop film

This editable 20-second HyperFrames composition uses actual native app captures. Cursor/drag motion connects the captured states; the edit is not a conversion benchmark. No remote images, narration services or API credentials are used.

Requirements: Node 22+, FFmpeg/ffprobe, Chrome, and HyperFrames 0.8.33 or a compatible newer release. The original render used macOS Helvetica Neue with native system monospace; fonts may differ on other systems. GSAP 3.14.2 is bundled in assets with its license header.

Run from this folder with an installed HyperFrames CLI:

```sh
hyperframes lint .
hyperframes check . --samples 9
hyperframes render . --output ../brag.render.mp4 --fps 30 --quality high --workers 1
```

If the installed version names layout validation `inspect`/`validate`, run those documented equivalents. Review native UI crops and transitions after changing source. Read audio-attribution.txt before reusing or publishing. Keep all asset paths relative.

After rendering, select a settled product frame at 8.8 seconds as brag.jpg, then replace only video frame zero with that image (same frame count/duration, audio copied). A finite 960px-wide GIF at 12fps is derived from the final MP4 for README use. The MP4 is distributed as a release asset rather than committed to the repository.
