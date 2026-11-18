// PlayerController.swift — the session brain: playback, format detection,
// mode planning, VR orchestration (panel SBS switch → display settle →
// fullscreen on the glasses → IMU head tracking), HUD.

import AppKit
import AVFoundation
import MetalKit
import RayNeoCore
import IOKit.pwr_mgt

// MARK: - Window / view plumbing

/// Borderless windows don't accept key by default — needed for keyboard
/// control while fullscreen on the glasses display.
final class VRWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// MTKView that forwards key events to the session controller and reports
/// pointer movement (for the navbar's auto-hide).
final class VideoView: MTKView {
    var onKey: ((NSEvent) -> Bool)?
    var onMouseMoved: (() -> Void)?
    private var trackingAdded = false
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAdded {
            addTrackingArea(NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
            trackingAdded = true
        }
    }
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }
}

// MARK: - PlayerController

final class PlayerController: NSObject, MTKViewDelegate {
    /// Debug log (also mirrored to stderr when run from a terminal).
    static let logPath = "/tmp/rayneo-cinema.log"
    static func log(_ line: String) {
        let l = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        FileHandle.standardError.write(Data(l.utf8))
        // FileHandle(forWritingAtPath:) returns nil unless the file already
        // exists — create it up front.
        if !FileManager.default.fileExists(atPath: Self.logPath) {
            FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: Self.logPath) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(Data(l.utf8))
        }
    }

    let player = AVPlayer()
    /// Two pixel-buffer outputs are attached to every item: native YUV 4:2:0
    /// first (zero-copy — no host-side conversion, works for huge frames),
    /// BGRA as fallback. Whichever produces frames becomes active.
    private var outputYUV: AVPlayerItemVideoOutput?
    private var outputBGRA: AVPlayerItemVideoOutput?
    private var activeOutput: AVPlayerItemVideoOutput?
    private var usingYUV = false

    let metalDevice: MTLDevice
    private let renderer: VRRenderer

    let hid = RayNeoHID()
    let fuser = OrientationFuser { msg in
        PlayerController.log("[fuser] \(msg)")
    }

    // Session state
    private(set) var info: VideoInfo?
    private(set) var modes: [String] = ["flatmono"]
    private(set) var modeIdx = 0
    private(set) var vr = false
    var mirrored = false
    var tracking = true
    var fov360 = 60.0
    var fov180 = 60.0
    /// Extra pitch applied to the sampled view direction (degrees). The fused
    /// orientation is gravity-locked, so the video horizon is the real
    /// horizon; this offset decouples it (lying down, reclined, etc.).
    var horizonOffset = 0.0
    private var powerAssertion: IOPMAssertionID = 0

    var mode: String { modes[min(modeIdx, modes.count - 1)] }

    private(set) var window: VRWindow?
    private(set) var videoView: VideoView?
    private var contentView: NSView?
    private var welcomeView: NSView?
    private let multiTap = MultiTapDetector()
    // Playback overlay bars: one full-width in windowed mode, two half-width
    // (one per eye) in VR mode. The HUD status line lives inside the bars.
    private var windowedBar: PlaybackBar?
    private var vrBars: [PlaybackBar] = []
    private var bars: [PlaybackBar] { vrBars.isEmpty ? (windowedBar.map { [$0] }) ?? [] : vrBars }
    private lazy var transcoder = TranscodeController()
    private var volumeBeforeMute: Float = 1.0
    private var uiTimer: DispatchSourceTimer?
    private var scrubbingUntil = Date()
    private var lastPointerActivity = Date()
    private var barsHidden = false
    private var cursorHidden = false
    // Frame diagnostics (draw loop ↔ HUD)
    private var lastFrameSize: (Int, Int)?
    private var missingFrames = 0
    // IMU diagnostics
    private var imuSamples = 0
    private var lastLoggedSamples = 0

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
        do {
            self.renderer = try VRRenderer(device: metalDevice)
        } catch {
            fatalError("Metal renderer init failed: \(error)")
        }
        super.init()
        try? FileManager.default.removeItem(atPath: Self.logPath)
        Self.log("app init (metal: \(metalDevice.name))")
        // Wire the IMU stream into the fusion filter (the CLI does this in its
        // `track` command; without this the fuser never sees a sample and
        // tracking stays "calibrating" forever).
        hid.onSample = { [weak self] sample in
            guard let self else { return }
            self.fuser.feed(sample.accel, sample.gyro, sample.tick)
            self.lastGyroTempC = sample.temperature
            // Multi-tap on the temple (port of the XR Linux driver): 2 taps
            // recenter, 3 taps fully recalibrate the gyro bias.
            self.multiTap.feed(sample.gyro, sample.tick)
            self.imuSamples += 1
        }
        multiTap.onTaps = { [weak self] taps in
            guard let self, self.vr else { return }
            Self.log("multi-tap detected: \(taps)")
            if taps >= 3 {
                self.fuser.recalibrate()
                self.updateHUD("recalibrating — hold still ~1.5 s")
            } else {
                self.recenter()
            }
        }
        hid.onError = { msg in Self.log("[hid] \(msg)") }
        // Persist the gyro bias across launches: adopt the saved value at
        // startup (warm start), refresh it whenever calibration completes and
        // on clean exits. Triple-tap recalibration rewrites it too.
        fuser.onCalibrated = { [weak self] in self?.saveGyroBias() }
        loadGyroBias()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil,
            queue: .main) { [weak self] _ in
                self?.saveGyroBias()
                if self?.cursorHidden == true { NSCursor.unhide() }
            }
    }

    // MARK: Gyro-bias persistence

    private var lastGyroTempC = 0.0

    private var gyroBiasURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RayNeoCinema", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gyro-bias.json")
    }

    private func saveGyroBias() {
        guard fuser.calibrated else { return }
        let payload: [String: Any] = [
            "bias": fuser.currentBiasDegPerSec,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "tempC": lastGyroTempC,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: gyroBiasURL, options: .atomic)
        }
    }

    private func loadGyroBias() {
        guard let data = try? Data(contentsOf: gyroBiasURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bias = obj["bias"] as? [Double], bias.count == 3 else {
            Self.log("no persisted gyro bias — first launch will calibrate on start")
            return
        }
        fuser.warmStart(biasDegPerSec: bias)
    }

    // MARK: UI bootstrap

    func makeUI() {
        let window = VRWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Rayneo VR Player"
        window.center()
        window.acceptsMouseMovedEvents = true // navbar auto-hide

        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                             device: metalDevice)
        view.delegate = self
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.onKey = { [weak self] event in (self?.handleKey(event)) ?? false }
        view.onMouseMoved = { [weak self] in self?.pointerActivity() }
        // Empty-state clear color must be set BEFORE the window is ordered
        // front: the MTKView render loop starts presenting as soon as the
        // window is visible, and a late sync presents one default-black
        // frame first — the "black flash" at launch.
        syncClearColor(view)

        // Empty state: app icon + name + version on the left,
        // plain rounded actions on the right (no big button icons). Hidden
        // once a video is loaded.
        let welcome = NSView(frame: NSRect(x: 0, y: 720 - 150, width: 1280, height: 150))
        welcome.autoresizingMask = [.width, .minYMargin] // stays pinned to the top

        let iconView = NSImageView(frame: NSRect(x: 24, y: 35, width: 80, height: 80))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        welcome.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Rayneo VR Player")
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.frame = NSRect(x: 122, y: 80, width: 460, height: 32)
        welcome.addSubview(titleLabel)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let versionLabel = NSTextField(labelWithString: version)
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 124, y: 54, width: 300, height: 18)
        welcome.addSubview(versionLabel)

        func roundedButton(_ title: String, _ sel: Selector, width: CGFloat) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: 0, y: 58, width: width, height: 34)
            b.autoresizingMask = [.minXMargin] // hugs the right edge
            return b
        }
        let openButton = roundedButton("Open…", #selector(openAction(_:)), width: 92)
        let urlButton = roundedButton("Open URL…", #selector(openURLAction(_:)), width: 110)
        let transcodeButton = roundedButton("Transcode…", #selector(transcodeAction(_:)), width: 118)
        // Right-aligned row: Open… · Open URL… · Transcode…
        var bx = 1280.0 - 24.0
        for b in [transcodeButton, urlButton, openButton] {
            bx -= b.frame.width
            b.frame.origin.x = bx
            bx -= 12
        }
        welcome.addSubview(openButton)
        welcome.addSubview(urlButton)
        welcome.addSubview(transcodeButton)

        let content = NSView(frame: view.bounds)
        content.addSubview(view)
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(welcome)

        // Windowed playback bar (a second per-eye pair is created in VR).
        // Hidden until a video is actually opened.
        let bar = PlaybackBar(frame: NSRect(x: 0, y: 0, width: 1280, height: 52))
        bar.autoresizingMask = [.width]
        bar.isHidden = true
        wireBar(bar)
        content.addSubview(bar)

        transcoder.onOpenInPlayer = { [weak self] url in self?.load(url: url) }

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view) // keyboard (⌘O, space, arrows) works without clicking first
        NSApp.activate(ignoringOtherApps: true)
        // Re-assert whenever the window becomes key (after dialogs, app switches).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self, weak window] _ in
            if let v = self?.videoView, window?.firstResponder !== v {
                window?.makeFirstResponder(v)
            }
        }

        self.window = window
        self.videoView = view
        self.contentView = content
        self.welcomeView = welcome
        self.windowedBar = bar

        // UI refresh at 4 Hz: HUD status, navbar state, auto-hide. Must be
        // retained — a released DispatchSource timer never fires.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.updateHUD()
            self?.updatePlaybackUI()
        }
        timer.resume()
        uiTimer = timer
    }

    /// Empty state = window background; with a video loaded = black screen.
    /// Accepts an explicit view so makeUI can color the view before the
    /// window is shown (the videoView property isn't assigned yet).
    private func syncClearColor(_ target: VideoView? = nil) {
        guard let view = target ?? videoView else { return }
        if player.currentItem == nil {
            let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            view.clearColor = MTLClearColor(
                red: Double(c.redComponent), green: Double(c.greenComponent),
                blue: Double(c.blueComponent), alpha: 1)
        } else {
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    // MARK: File loading

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    @objc private func openAction(_ sender: Any?) {
        openPanel()
    }

    /// "Open URL…": stream a remote video directly.
    @objc private func openURLAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Stream a video from a network address (http/https)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com/video.mp4"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            let bad = NSAlert()
            bad.messageText = "Not a usable URL"
            bad.informativeText = "Enter a full http(s) address."
            bad.runModal()
            return
        }
        load(url: url)
    }

    @objc private func transcodeAction(_ sender: Any?) {
        transcoder.present()
    }

    func load(url: URL) {
        Self.log("load \(url.path)")
        let item = AVPlayerItem(url: url)
        let yuv = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ])
        let bgra = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_32BGRA),
        ])
        item.add(yuv)
        item.add(bgra)
        outputYUV = yuv
        outputBGRA = bgra
        activeOutput = yuv
        usingYUV = false
        player.replaceCurrentItem(with: item)
        player.play()
        info = nil
        modes = ["flatmono"]
        modeIdx = 0
        welcomeView?.isHidden = true
        windowedBar?.isHidden = false // controls become relevant once a video opens
        barsHidden = false
        lastPointerActivity = Date()
        syncClearColor() // loaded → black screen (not window color)
        updateHUD("loading \(url.lastPathComponent)…")

        Task { [weak self] in
            await self?.detect(url: url)
        }
    }

    private func detect(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else {
            updateHUD("could not read video track — \(url.lastPathComponent)")
            return
        }
        let detected = VideoFormat.detect(width: Int(abs(size.width)), height: Int(abs(size.height)),
                                          filename: url.lastPathComponent)
        // Codec identification — tells us whether AVFoundation even supports
        // the video track when frames don't arrive.
        if let descs = try? await track.load(.formatDescriptions), let d = descs.first {
            let code = CMFormatDescriptionGetMediaSubType(d)
            let fourCC = String(bytes: [
                UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code),
            ], encoding: .ascii) ?? "?"
            Self.log("codec: \(fourCC)")
        }
        let plannedModes = VideoFormat.modesFor(detected)
        Self.log("detect: \(detected.modeName) hint=\(detected.hint ?? "none") modes=\(plannedModes.joined(separator: ","))")
        self.info = detected
        self.modes = plannedModes
        self.modeIdx = 0
        updateHUD("detected \(VideoFormat.modeLabel(mode)) — \(detected.modeName)\(detected.hint.map { " — \($0)" } ?? "")")

        // Auto-VR (plugin's autoVR default): with glasses present, stereo or
        // spherical content goes straight to the panel.
        let glassesPresent = !hid.findDevices().isEmpty
        if glassesPresent, detected.spherical || detected.format != .mono {
            enterVR()
        }
    }

    // MARK: Modes / controls

    func cycleMode() {
        guard modes.count > 1 else { return }
        modeIdx = (modeIdx + 1) % modes.count
        updateHUD("mode: \(VideoFormat.modeLabel(mode))")
    }

    func toggleMirror() {
        mirrored.toggle()
        updateHUD(mirrored ? "eyes mirrored" : "eyes normal")
    }

    func recenter() {
        fuser.recenter()
        updateHUD("view recentered")
    }

    func toggleTracking() {
        tracking.toggle()
        updateHUD("head tracking \(tracking ? "on" : "off")")
    }

    private func togglePlay() {
        (player.rate == 0) ? player.play() : player.pause()
    }

    // MARK: Playback overlay bars

    private func wireBar(_ bar: PlaybackBar) {
        bar.onTogglePlay = { [weak self] in self?.togglePlay() }
        bar.onScrubStart = { [weak self] in
            self?.scrubbingUntil = Date().addingTimeInterval(0.6)
            self?.lastPointerActivity = Date()
        }
        bar.onScrub = { [weak self] frac in
            guard let self else { return }
            let duration = self.player.currentItem?.duration.seconds ?? 0
            guard duration.isFinite, duration > 0 else { return }
            self.player.seek(to: CMTime(seconds: frac * duration, preferredTimescale: 600))
        }
        bar.onVolume = { [weak self] v in
            guard let self else { return }
            self.player.volume = Float(v)
            if self.player.volume > 0 { self.volumeBeforeMute = self.player.volume }
            self.updatePlaybackUI()
        }
        bar.onMuteToggle = { [weak self] in self?.toggleMute() }
        bar.onPointerActivity = { [weak self] in self?.pointerActivity() }
    }

    private func toggleMute() {
        if player.volume > 0 {
            volumeBeforeMute = player.volume
            player.volume = 0
        } else {
            player.volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1.0
        }
        updatePlaybackUI()
    }

    /// Any pointer movement over the video or a bar: reveal the overlay.
    private func pointerActivity() {
        lastPointerActivity = Date()
        if barsHidden { setBarsOverlayHidden(false) }
    }

    private func setBarsOverlayHidden(_ hidden: Bool) {
        barsHidden = hidden
        // The cursor hides with the overlay and reappears with it — a
        // floating arrow over a clean video is just noise.
        if hidden != cursorHidden {
            if hidden { NSCursor.hide() } else { NSCursor.unhide() }
            cursorHidden = hidden
        }
        for bar in bars {
            if hidden {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    bar.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak bar] in
                    if let bar, bar.alphaValue == 0 { bar.isHidden = true }
                }
            } else {
                bar.isHidden = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    bar.animator().alphaValue = 1
                }
            }
        }
    }

    /// Sync the overlay bars (4 Hz) and auto-hide while playing idle.
    private func updatePlaybackUI() {
        let duration = player.currentItem?.duration.seconds ?? 0
        let t = player.currentTime().seconds
        let playing = player.rate > 0
        let volume = Double(player.volume)
        for bar in bars {
            bar.setProgress(current: t, duration: duration)
            bar.setPlaying(playing)
            bar.setVolume(volume)
        }
        // Hide only while playing, after 3 s of pointer idleness — and keep
        // the overlay up during calibration (status feedback matters then).
        let idle = Date().timeIntervalSince(lastPointerActivity) > 3
        let shouldHide = playing && idle && Date() > scrubbingUntil && fuser.calibrated
        if shouldHide != barsHidden { setBarsOverlayHidden(shouldHide) }
    }

    // MARK: Key handling

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 49: togglePlay(); return true           // space
        case 3: toggleVR(); return true              // f — enter/exit VR
        case 15:                                     // r — recenter (⇧R: horizon reset)
            if shift {
                horizonOffset = 0
                updateHUD("horizon offset reset (0°)")
            } else {
                recenter()
            }
            return true
        case 46: toggleMirror(); return true         // m
        case 8: cycleMode(); return true             // c
        case 12: toggleTracking(); return true       // t — toggle head tracking
        case 53:                                     // esc
            if vr { exitVR() }
            return true
        case 125, 126:                               // ⇧↑/⇧↓ — horizon offset
            if shift {
                horizonOffset = min(45, max(-45, horizonOffset + (event.keyCode == 126 ? 1 : -1)))
                updateHUD("horizon offset \(horizonOffset >= 0 ? "+" : "")\(Int(horizonOffset))°")
            } else {
                seek(event.keyCode == 126 ? 10 : -10)
            }
            return true
        case 123: seek(-10); return true             // ←
        case 124: seek(10); return true              // →
        default: return false
        }
    }

    private func seek(_ seconds: Double) {
        let target = player.currentTime().seconds + seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: min(max(0, target), duration), preferredTimescale: 600))
    }

    // MARK: VR session (auto SBS switch orchestration)

    private func glassesScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.width > 3000 }
    }

    func toggleVR() { vr ? exitVR() : enterVR() }

    /// enterVR: panel → SBS, wait for the glasses to re-enumerate at
    /// 3840×1080, fullscreen the window there, start the IMU.
    func enterVR() {
        guard !vr else { return }
        guard !hid.findDevices().isEmpty else {
            updateHUD("no RayNeo glasses found — connect them and try again")
            return
        }
        Self.log("enterVR: begin");        updateHUD("switching glasses panel to SBS 3D…")
        do {
            try hid.sendPanelCommand(.sbs3d)
        } catch {
            updateHUD("panel command failed: \(error)")
            return
        }

        // Wait up to 3 s for the glasses to re-enumerate as a super-wide
        // display (port of settleDisplayAfterModeChange()).
        func poll(_ attempt: Int) {
            if let target = glassesScreen() {
                Self.log("enterVR: settled on \(target.frame.width)x\(target.frame.height)")
                beginVR(on: target)
            } else if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(attempt + 1) }
            } else {
                updateHUD("WARNING: panel did not switch to SBS (no 3840×1080 display appeared)")
                try? hid.sendPanelCommand(.twod)
            }
        }
        poll(0)
    }

    private func beginVR(on screen: NSScreen) {
        Self.log("beginVR: screen \(screen.frame.width)x\(screen.frame.height)")
        // Borderless frame on the glasses screen avoids the native-fullscreen
        // Space trap the IINA plugin documented (a fullscreen Space keeps the
        // backing size it was created with, showing each eye as a magnified
        // crop after the panel re-enumerates).
        window?.styleMask = [.borderless]
        window?.setFrame(screen.frame, display: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(videoView)

        // Per-eye overlay: swap the full-width bar for two half-width bars,
        // one over each eye's half of the 3840-wide panel — the HUD reads as
        // a single 3D bar through the glasses instead of being torn apart.
        windowedBar?.isHidden = true
        for bar in vrBars { bar.removeFromSuperview() }
        vrBars = []
        let half = screen.frame.width / 2
        for i in 0...1 {
            let bar = PlaybackBar(frame: NSRect(x: CGFloat(i) * half, y: 0, width: half, height: 52))
            wireBar(bar)
            contentView?.addSubview(bar)
            vrBars.append(bar)
        }
        welcomeView?.isHidden = true

        do {
            try hid.startIMU()
        } catch {
            updateHUD("IMU start failed: \(error) — tracking off")
        }
        // Keep the Mac awake during VR sessions.
        if powerAssertion == 0 {
            IOPMAssertionCreateWithName("NoDisplaySleepAssertion" as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Rayneo VR Player VR session" as CFString,
                                        &powerAssertion)
        }
        vr = true
        // The borderless window doesn't remove the system chrome — on the
        // glasses display the menu bar strip would sit at the top of the
        // picture. Hide it (and the dock) for the VR session.
        NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        updateHUD("VR mode on — \(VideoFormat.modeLabel(mode))\(tracking ? ", head tracking on — hold still ~1.5 s" : "") (esc exits)")
    }

    func exitVR() {
        Self.log("exitVR")
        guard vr else { return }
        vr = false
        hid.stopIMU()
        saveGyroBias() // session's refined bias persists for next launch
        try? hid.sendPanelCommand(.twod)
        if powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
        // Restore a normal window on the laptop screen.
        window?.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window?.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 720), display: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(videoView)
        // Back to the single windowed bar.
        for bar in vrBars { bar.removeFromSuperview() }
        vrBars = []
        windowedBar?.isHidden = player.currentItem == nil
        barsHidden = false
        lastPointerActivity = Date()
        welcomeView?.isHidden = player.currentItem != nil
        NSApp.presentationOptions = [] // restore menu bar + dock
        updateHUD("VR mode off — panel restored to 2D")
    }

    // MARK: HUD

    private func updateHUD(_ text: String? = nil) {
        syncClearColor() // keep the empty-state background matching the window
        guard !bars.isEmpty else { return }
        if let text {
            bars.forEach { $0.setStatus(text) }
            return
        }
        var parts: [String] = []
        if let info {
            parts.append(VideoFormat.modeLabel(mode))
            parts.append(info.modeName)
        } else {
            parts.append("no video")
        }
        let devices = hid.findDevices()
        parts.append(devices.isEmpty ? "no glasses" : "\(devices.count) glasses")
        if vr {
            parts.append(hid.isIMURunning ? (fuser.calibrated ? "tracking" : "calibrating — hold still") : "IMU off")
        }
        // Playback/frame diagnostics.
        if let item = player.currentItem {
            switch item.status {
            case .failed:
                parts.append("PLAYER FAILED: \(item.error?.localizedDescription ?? "unknown error")")
            case .readyToPlay:
                parts.append(player.rate > 0 ? "playing" : "paused")
            case .unknown:
                parts.append("loading…")
            @unknown default:
                break
            }
        }
        if let size = lastFrameSize {
            parts.append("frame \(size.0)×\(size.1)")
        } else if activeOutput != nil, player.rate > 0, let item = player.currentItem,
                  item.status == .readyToPlay {
            parts.append("WAITING for frames (\(missingFrames)) — codec/dimensions may exceed AVFoundation")
        }
        let status = parts.joined(separator: " · ")
        bars.forEach { $0.setStatus(status) }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Pull the latest frame. A nil buffer (before the first frame, while
        // paused, or if AVFoundation cannot convert the codec) must still
        // present the cleared drawable — an unpresented CAMetalLayer shows
        // white, which masked "no frames are arriving" as "white canvas".
        // Pull the latest frame from the active pixel-buffer output.
        var gotFrame = false
        if activeOutput != nil {
            var pb = activeOutput!.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            // No frames from the active output while the item is playing?
            // After 2.5 s, try the other pixel format and switch if it works.
            if pb == nil, missingFrames > 150, let other = (activeOutput === outputYUV) ? outputBGRA : outputYUV {
                if let p2 = other.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                    pb = p2
                    activeOutput = other
                    Self.log("pixel-buffer switch: falling back to \(other === outputBGRA ? "BGRA" : "YUV")")
                }
            }
            if let pb {
                let fmt = CVPixelBufferGetPixelFormatType(pb)
                usingYUV = (fmt != kCVPixelFormatType_32BGRA)
                renderer.setPixelBuffer(pb)
                lastFrameSize = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
                missingFrames = 0
                gotFrame = true
                if logTick % 60 == 0 {
                    Self.log("frame \(lastFrameSize!.0)×\(lastFrameSize!.1) fmt=\(fmt) input=\(usingYUV ? "yuv" : "bgra") tex=\(renderer.currentTexture() != nil)")
                }
            }
        }
        if !gotFrame, player.rate > 0, activeOutput != nil {
            missingFrames += 1
            if missingFrames == 301 {
                // ~5 s with zero frames while playing: AVFoundation has no
                // decoder for this track (e.g. 8K HEVC — the M1's hardware
                // decoder caps near 4K60, and macOS ships no software HEVC
                // decoder). Surface it once instead of silently playing audio.
                Self.log("DECODE FAILED: no video frames after 5 s while playing — AVFoundation cannot decode this track (likely resolution/codec beyond this Mac's hardware decoder). Audio-only playback continues.")
            }
        }
        // Once-per-second state dump — this is what diagnoses "black canvas".
        logTick += 1
        if logTick % 60 == 0 {
            let item = player.currentItem
            Self.log("draw rate=\(player.rate) time=\(player.currentTime().seconds) status=\(item?.status.rawValue ?? -1) err=\(item?.error?.localizedDescription ?? "none") missing=\(missingFrames) lastFrame=\(lastFrameSize.map { "\($0.0)×\($0.1)" } ?? "none")")
            if vr {
                // IMU diagnostics: sample flow + fused angles + calibration.
                let a = fuser.viewAngles()
                Self.log("imu running=\(hid.isIMURunning) samples=\(imuSamples) Δ\(imuSamples - lastLoggedSamples)/s calibrated=\(fuser.calibrated) yaw=\(String(format: "%.1f", a.yaw)) pitch=\(String(format: "%.1f", a.pitch)) roll=\(String(format: "%.1f", a.roll))")
                lastLoggedSamples = imuSamples
            }
        }
        renderer.params = currentParams()
        renderer.draw(in: view, clearOnly: !gotFrame && renderer.currentTexture() == nil)
        if !gotFrame && missingFrames % 60 == 1 {
            updateHUD(nil) // refresh "waiting for frames" diagnostics ~1×/s
        }
    }
    private var logTick = 0

    private func currentParams() -> VRParams {
        var p = VRParams()
        let srcFormat: UInt32
        switch info?.format {
        case .sbs: srcFormat = 0
        case .ou: srcFormat = 1
        default: srcFormat = 2
        }
        p.inputFormat = srcFormat
        p.mirror = mirrored ? 1 : 0
        p.inputLayout = usingYUV ? 1 : 0
        // Flat modes behave differently on the glasses panel (fill) vs a
        // window (letterbox) — see VRParams.panelMode.
        p.panelMode = vr ? 1 : 0

        switch mode {
        case "flatsbs": p.outputMode = 0 // passthrough is the SBS layout on both window and panel
        case "flatou": p.outputMode = vr ? 5 : 1
        case "flatmono":
            if info?.format == .mono {
                // A mono frame stretched across the full panel puts the left
                // half of the picture in the left eye and the right half in
                // the right — the "split in the middle" view. On the panel,
                // letterbox the frame into each eye's half instead.
                p.outputMode = vr ? 6 : 0
            } else if vr {
                // Stereo source, flat mode, on the panel: passthrough IS the
                // correct per-eye layout (collapse is a windowed-only mode).
                p.outputMode = 0
            } else {
                p.outputMode = 2
            }
        case "360sbs", "180sbs":
            p.outputMode = 3
            p.projection = (mode == "180sbs") ? 1 : 0
        case "360mono", "180mono":
            p.outputMode = 4
            p.projection = (mode == "180mono") ? 1 : 0
        default: p.outputMode = 0
        }

        if p.outputMode == 3 || p.outputMode == 4 {
            p.vfov = Float(VideoFormat.fovFor(info, mode: mode, fov360: fov360, fov180: fov180))
            if tracking, hid.isIMURunning {
                let a = fuser.viewAngles()
                // Sign check on hardware: yaw negated, pitch as-is, roll
                // negated (tilt was reversed; the extension's YouTube
                // renderer negated yaw for the same shader convention).
                p.yaw = Float(-a.yaw)
                p.pitch = Float(a.pitch + horizonOffset)
                p.roll = Float(-a.roll)
            }
        }
        return p
    }
}

extension Array {
    /// nil-safe emptiness helpers kept minimal
}
