# Third-party notices

This project includes code and research derived from the following upstream
works. The full text of the GPL-3.0 license governing this combined work is in
`LICENSE`.

## RayNeo WebXR extension / IINA plugin (MIT)

Source: the RayNeo WebXR extension and its IINA plugin (sibling project)
Adapted from: https://github.com/bfvogel/viture-webxr-extension

Used for: RayNeo Air USB/HID protocol research, `rayneo-hid.swift`,
`imu.js` / Mahony sensor fusion, `video-modes.js` detection heuristics, and
`vr-shader.js` projection math (ported to Metal in `VRRenderer.swift`,
validated at 65.4 dB PSNR against ffmpeg `v360`).

```
MIT License

Copyright (c) 2026 bfvogel (original viture-webxr-extension) and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## XRLinuxDriver — multi-tap detector (GPL-3.0)

Source: https://github.com/wheaney/XRLinuxDriver
File ported: `src/multitap.c` → `Sources/RayNeoCore/MultiTapDetector.swift`

Copyright (C) 2025 wheaney. Licensed under the GNU General Public License,
version 3 or (at your option) any later version. The full GPLv3 text is in
`LICENSE`. Because this is a faithful port of a GPL-3.0 work, the combined
project and its distributed binary are licensed GPL-3.0.

## Other referenced projects (research only, no code copied)

- https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR — USB protocol research
- https://github.com/Fuut4/rayneo-pin — panel/controller protocol research
- https://github.com/informalTechCode/RayNeo-Air-Series-3DoF-Scaffold — 3DoF IMU research
- https://github.com/google/spatial-media — Spherical Video V2 metadata spec
