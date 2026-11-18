# Rayneo VR Player

A native macOS player for 360°, 180°, side-by-side (SBS) and half-SBS VR video on
**RayNeo Air 3S Pro / Air 4 Pro** glasses, with 3DoF head tracking, automatic
SBS panel switching, with a clean native macOS interface. Built entirely with Apple's
AVFoundation + Metal stack — no embedded media player, no libmpv.

## What it does

- **Plays VR video on the glasses**: switches the 3840×1080 glasses panel into
  SBS mode (two 1920×1080 eye halves) and fullscreens the window on it.
- **Head tracking**: the glasses' IMU drives a per-eye reprojection shader at
  display refresh rate, with Mahony sensor fusion, gyro-bias calibration and
  persistent warm start.
- **Automatic format detection**: filename tokens plus canonical frame shapes
  identify 360/180 × mono/SBS/OU layouts; the detected layout is embedded in
  transcoded filenames so re-opens stay correct.
- **Transcoder for hardware-undecodable files**: a base M1 only reliably
  decodes video up to around 4K60, so 8K HEVC cannot play directly. The in-app
  ffmpeg flow downscales to 3840×1920 with hardware H.264 encoding and reports
  real progress/ETA.
- **Works without glasses too**: `F` keeps playback in a window; `C` cycles
  flat passthrough / single-eye 2D / spherical modes, with aspect-correct
  letterboxing in windows and correct per-eye fill on the panel.

## How it works

```
AVPlayer (audio + AVPlayerItemVideoOutput)
   ↓  CVPixelBuffer — native YUV 4:2:0, zero-copy to Metal textures
Metal renderer (MTKView, 3840×1080 panel)
   ↓  VRParams uniform (yaw/pitch/roll, projection, FOV, layout, mode)
   └─ per-eye fragment shader: equirect/hequirect reprojection,
      BT.709 YUV→RGB, head tracking, letterbox/fill flat modes
RayNeoHID (IOHIDManager, in-process)
   ├─ panel commands: SBS 0x06 / 2D 0x07 / 60–120 Hz 0x20/0x21
   └─ IMU stream (~500 Hz) → OrientationFuser (Mahony) → gyro bias,
      horizon, recenter; MultiTapDetector (double/triple temple tap)
```

- **Video path** — `AVPlayerItemVideoOutput` hands `CVPixelBuffer`s to Metal as
  `YCbCr` textures; the shader converts BT.709 video-range YUV to RGB. BGRA is
  the fallback after repeated copy failures. `AVPlayer` handles A/V sync, seek
  and audio.
- **Projection** — spherical modes apply the PSNR-validated geometry from the
  IINA plugin's `vr-shader.js` (65.4 dB against ffmpeg `v360`): per-eye image
  plane → sphere ray → equirectangular or hemi-equirectangular source lookup.
  Flat modes either letterbox the source in a window or fill the panel's eye
  halves (the stretch is what unsqueezes half-SBS).
- **Detection** — `VideoFormat.detect()` reads filename tokens and frame shape.
  VR180 on a 2:1 frame implies SBS (mono VR180 is 1:1); 360 on 4:1 implies
  SBS; explicit `sbs` / `3dtb` tokens win. `C` cycles manually if needed.
- **Tracking** — a Mahony complementary filter integrates gyro rotation at
  ~500 Hz and uses accelerometer gravity to correct pitch/roll. Yaw has no
  absolute reference, so it is recentered by `R` or a double temple tap;
  `⇧↑`/`⇧↓` shifts the horizon. Gyro bias is measured while still and saved to
  `~/Library/Application Support/RayNeoCinema/gyro-bias.json`.
- **Session** — on load, if glasses are present the app switches the panel to
  SBS, waits for the display to settle, fullscreens on it, hides the menu bar
  and dock, and starts the IMU. Exiting VR restores all of it.
- **Transcode** — the app locates ffmpeg (Homebrew/MacPorts/system), probes the
  source, and runs `scale=3840:-2` + `h264_videotoolbox` (bitrate scaled by
  target width) by default. The M1's hardware decoder only handles about 4K60
  reliably; anything above that (e.g. 8K HEVC) needs this step. Hardware decode
  of 8K is *not* usable on a base M1:
  measured throughput was ~4× worse than software decode, and the all-GPU
  (`scale_vt`) path fails, so software decode + hardware encode is used.
  On a fanless MacBook Air M1 the sustained rate is ~0.3–0.4× realtime.

## Build and run

Requires macOS 13+, Xcode/Swift 5.9+, and (for the transcode feature) ffmpeg.

```sh
./build.sh                                       # builds build/Rayneo VR Player.app
open "build/Rayneo VR Player.app"                # then ⌘O to open a video
open "build/Rayneo VR Player.app" /path/to/video             # or pass a file directly
```

The release download is **ad-hoc signed**, not notarized. If macOS blocks it,
remove the quarantine attribute once:

```sh
xattr -dr com.apple.quarantine "Rayneo VR Player.app"
```

Developer diagnostics: `.build/release/rayneo-cli detect <w> <h> <filename>`
tests format detection; `.build/debug/decode-test <path>` probes whether a
file's codec is decodable on this Mac. Logs go to `/tmp/rayneo-cinema.log`.

## Controls

| Key | Action |
|---|---|
| `F` | enter/exit VR (auto: panel → SBS, fullscreen on glasses, head tracking) |
| `Space` | play/pause |
| `C` | cycle render mode |
| `M` | mirror eyes (swap left/right) |
| `T` | toggle head tracking |
| `R` | recenter view (yaw) |
| `⇧↑` / `⇧↓` | shift video horizon ±1° (±45° max) |
| `⇧R` | reset horizon offset to 0° |
| `←` / `→` | seek ±10 s |
| `Esc` | exit VR |

Glasses gestures: **double-tap** the temple to recenter; **triple-tap** to
recalibrate the gyro bias. The navbar (and mouse cursor) auto-hide after ~3 s
of inactivity during playback and return on pointer movement.

## Limitations

- A base M1 reliably decodes only up to ~4K60; 8K sources must be transcoded
  first (the app has a built-in flow for this).
- **MKV is a no-go for direct playback**: AVPlayer has no Matroska demuxer, so
  `.mkv` files cannot be opened in the player. Convert them to MP4 (ffmpeg,
  including the in-app transcoder) first.
- No 6DoF/positional tracking — the glasses expose a 3DoF IMU only.
- Displayed in VR by filling a 3840×1080 SBS panel; very unusual aspect ratios
  need a manual `C` cycle.
- M4 hardening (keepalive watcher, EOF restore, 120 Hz panel rate) and M5
  polish (library, preferences, notarization) are still on the roadmap.

## Provenance / whose code this uses

| Component | Source | License |
|---|---|---|
| HID protocol research, IMU fusion, format detection, VR shader math, IINA plugin behavior | The RayNeo WebXR extension and its IINA plugin (sibling project), itself adapted from [bfvogel/viture-webxr-extension](https://github.com/bfvogel/viture-webxr-extension) | MIT |
| Additional RayNeo Air protocol research | [verncat/RayNeo-Air-3S-Pro-OpenVR](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR), [Fuut4/rayneo-pin](https://github.com/Fuut4/rayneo-pin), [informalTechCode/RayNeo-Air-Series-3DoF-Scaffold](https://github.com/informalTechCode/RayNeo-Air-Series-3DoF-Scaffold) | See upstream projects |
| Multi-tap gesture detector (`Sources/RayNeoCore/MultiTapDetector.swift`, faithful port of `src/multitap.c`) | [wheaney/XRLinuxDriver](https://github.com/wheaney/XRLinuxDriver) (Steam Deck XR Gaming plugin) | **GPL-3.0** |
| Spherical Video V2 projection reference | [google/spatial-media](https://github.com/google/spatial-media) | See upstream project |
| Playback, decode, display, HID | Apple AVFoundation, Metal, IOHIDKit (system frameworks, not redistributed) | Apple SDK terms |
| Transcoding | ffmpeg, invoked as an external tool the user installs (not bundled) | Depends on the user's ffmpeg build |

The multi-tap detector is a faithful port of GPL-3.0 code, so this combined
work is distributed under the **GNU GPL v3** to comply with that upstream
license. Upstream MIT notices are preserved in `THIRD_PARTY_NOTICES.md`.

## License

**GNU General Public License v3.0** — see `LICENSE`. See
`THIRD_PARTY_NOTICES.md` for upstream MIT notices.
