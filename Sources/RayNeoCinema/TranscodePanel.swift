// TranscodePanel.swift — the "Transcode" flow: ffmpeg probe, one-click
// install via Homebrew when missing, and a downscale-transcode dialog
// (file picker + target width + progress) that writes next to the source.
//
// The transcoder exists because Apple's hardware HEVC decoder caps near
// 4K60 on M1 — an 8K source can be re-encoded to 4K with ffmpeg's software
// decoder/encoder so it plays on the glasses panel.

import AppKit
import AVFoundation
import RayNeoCore

enum FFmpeg {
    /// Locate the ffmpeg binary (Homebrew / MacPorts / system / PATH).
    static func locate() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",   // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",      // Intel Homebrew
            "/opt/local/bin/ffmpeg",      // MacPorts
            "/usr/bin/ffmpeg",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Fall back to the user's login PATH (custom installs).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "which ffmpeg"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, s.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: s) {
                return s
            }
        } catch {}
        return nil
    }

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

final class TranscodeController: NSObject, NSWindowDelegate {
    /// Invoked when the user clicks "Open in player" after a finished run.
    var onOpenInPlayer: ((URL) -> Void)?

    private var window: NSWindow?
    private var ffmpegPath: String?

    // Setup controls
    private var setupGroup: NSView!
    private var filePathLabel: NSTextField!
    private var widthPopup: NSPopUpButton!
    private var codecPopup: NSPopUpButton!
    private var presetPopup: NSPopUpButton!
    private var presetDesc: NSTextField!
    private var outputLabel: NSTextField!
    private var startButton: NSButton!
    private var fileURL: URL?
    /// Layout token detected from the source ("sbs" / "3dtb"), embedded in
    /// the output filename so transcoded files auto-detect forever after —
    /// even when the original name carried no stereo hints.
    private var sourceToken: String?

    // Progress UI — structured rows: title+% · processed/total · time
    // projection · throughput, plus a scrolling ffmpeg log.
    private var progressGroup: NSView!
    private var progressTitle: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var processedLabel: NSTextField!
    private var etaLabel: NSTextField!
    private var speedLabel: NSTextField!
    private var logView: NSTextView!
    private var cancelButton: NSButton!

    // Done UI
    private var doneGroup: NSView!
    private var doneLabel: NSTextField!
    private var openInPlayerButton: NSButton!

    // Install UI
    private var installGroup: NSView!
    private var installLog: NSTextView!
    private var installSpinner: NSProgressIndicator!

    private var process: Process?
    private var triedH264Fallback = false
    private var startedAt: Date?
    private var lastErrorLines: [String] = []
    private var outputURL: URL?

    // MARK: presentation

    func present() {
        if ffmpegPath == nil { ffmpegPath = FFmpeg.locate() }
        if window == nil { buildWindow() }
        if ffmpegPath == nil {
            offerInstall()
            return
        }
        showSetup()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window cancels a running job gracefully.
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    // MARK: window construction

    private func buildWindow() {
        // 520×380 gives every label its full row height — nothing truncates.
        let W = 520.0, H = 380.0
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Rayneo Transcoder"
        w.delegate = self

        // ---- setup group ----
        let setup = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let fileCaption = NSTextField(labelWithString: "Video file")
        fileCaption.font = NSFont.systemFont(ofSize: 11)
        fileCaption.textColor = .secondaryLabelColor
        fileCaption.frame = NSRect(x: 20, y: 350, width: 240, height: 16)

        filePathLabel = NSTextField(labelWithString: "choose a file…")
        filePathLabel.textColor = .secondaryLabelColor
        filePathLabel.lineBreakMode = .byTruncatingMiddle
        filePathLabel.frame = NSRect(x: 20, y: 324, width: 388, height: 18)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFile))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 416, y: 318, width: 84, height: 28)

        let widthCaption = NSTextField(labelWithString: "Output width")
        widthCaption.font = NSFont.systemFont(ofSize: 11)
        widthCaption.textColor = .secondaryLabelColor
        widthCaption.frame = NSRect(x: 20, y: 292, width: 246, height: 14)

        widthPopup = NSPopUpButton(frame: NSRect(x: 20, y: 258, width: 246, height: 26))
        widthPopup.addItems(withTitles: [
            "3840 — glasses panel max", "2560", "1920", "1280", "keep source size",
        ])
        widthPopup.selectItem(at: 0)
        widthPopup.target = self
        widthPopup.action = #selector(setupChanged)

        let codecCaption = NSTextField(labelWithString: "Video codec")
        codecCaption.font = NSFont.systemFont(ofSize: 11)
        codecCaption.textColor = .secondaryLabelColor
        codecCaption.frame = NSRect(x: 286, y: 292, width: 214, height: 14)

        codecPopup = NSPopUpButton(frame: NSRect(x: 286, y: 258, width: 214, height: 26))
        codecPopup.addItems(withTitles: [
            "H.264 (VideoToolbox, HW) — fastest",
            "H.264 (software) — quality",
            "H.265 (HEVC) — smaller files",
        ])
        codecPopup.selectItem(at: 0) // default: hardware encode (measured 4× faster)
        codecPopup.target = self
        codecPopup.action = #selector(setupChanged)

        // Preset row: the popup plus a live one-line explanation of what the
        // selected preset actually means for encode time / file size.
        presetPopup = NSPopUpButton(frame: NSRect(x: 20, y: 214, width: 150, height: 26))
        presetPopup.addItems(withTitles: ["medium", "fast", "slow"])
        presetPopup.selectItem(at: 1) // default: fast
        presetPopup.target = self
        presetPopup.action = #selector(setupChanged)

        presetDesc = NSTextField(labelWithString: "")
        presetDesc.font = NSFont.systemFont(ofSize: 10)
        presetDesc.textColor = .secondaryLabelColor
        presetDesc.lineBreakMode = .byTruncatingTail
        presetDesc.frame = NSRect(x: 180, y: 220, width: 320, height: 16)

        outputLabel = NSTextField(labelWithString: "")
        outputLabel.textColor = .secondaryLabelColor
        outputLabel.font = NSFont.systemFont(ofSize: 11)
        outputLabel.lineBreakMode = .byTruncatingMiddle
        outputLabel.frame = NSRect(x: 20, y: 182, width: 480, height: 16)

        let hint = NSTextField(labelWithString: String(
            "H.264 encodes several times faster than H.265 on the M1 — start there for 8K\n" +
            "sources. Both write 8-bit 4:2:0 with +faststart, which the glasses' hardware\n" +
            "decoder accepts natively."))
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 20, y: 122, width: 480, height: 44)

        startButton = NSButton(title: "Start Transcode", target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.frame = NSRect(x: 360, y: 64, width: 140, height: 32)
        startButton.isEnabled = false

        setupGroup = setup
        for v in [fileCaption, filePathLabel, choose, widthCaption, widthPopup,
                  codecCaption, codecPopup, presetPopup, presetDesc, outputLabel,
                  hint, startButton] as [NSView] {
            setup.addSubview(v)
        }

        // ---- progress group ----
        let progress = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        progressTitle = NSTextField(labelWithString: "Transcoding…")
        progressTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        progressTitle.frame = NSRect(x: 20, y: 344, width: 480, height: 18)
        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 318, width: 480, height: 10))
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)

        // Structured key-value rows (monospaced digits so numbers align).
        let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        processedLabel = NSTextField(labelWithString: "processed — of —")
        processedLabel.font = rowFont
        processedLabel.textColor = .labelColor
        processedLabel.lineBreakMode = .byTruncatingTail
        processedLabel.frame = NSRect(x: 20, y: 286, width: 480, height: 16)

        etaLabel = NSTextField(labelWithString: "estimating total length…")
        etaLabel.font = rowFont
        etaLabel.textColor = .secondaryLabelColor
        etaLabel.lineBreakMode = .byTruncatingTail
        etaLabel.frame = NSRect(x: 20, y: 262, width: 480, height: 16)

        speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = rowFont
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.lineBreakMode = .byTruncatingTail
        speedLabel.frame = NSRect(x: 20, y: 238, width: 480, height: 16)

        // Raw ffmpeg output in a small scrollable log — full detail, readable.
        let logScroll = NSScrollView(frame: NSRect(x: 20, y: 96, width: 480, height: 128))
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 128))
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        logScroll.documentView = logView

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 404, y: 48, width: 96, height: 32)

        progressGroup = progress
        for v in [progressTitle, progressBar, processedLabel, etaLabel, speedLabel,
                  logScroll, cancelButton] as [NSView] {
            progress.addSubview(v)
        }

        // ---- done group ----
        let done = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        doneLabel = NSTextField(labelWithString: "Transcode finished.")
        doneLabel.frame = NSRect(x: 20, y: 290, width: 480, height: 18)
        openInPlayerButton = NSButton(title: "Open in Rayneo VR Player", target: self,
                                      action: #selector(openInPlayerClicked))
        openInPlayerButton.bezelStyle = .rounded
        openInPlayerButton.keyEquivalent = "\r"
        openInPlayerButton.frame = NSRect(x: 20, y: 240, width: 220, height: 32)
        let showInFinder = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinderClicked))
        showInFinder.bezelStyle = .rounded
        showInFinder.frame = NSRect(x: 250, y: 240, width: 140, height: 32)

        doneGroup = done
        for v in [doneLabel, openInPlayerButton, showInFinder] as [NSView] {
            done.addSubview(v)
        }

        // ---- install group ----
        let install = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        installSpinner = NSProgressIndicator(frame: NSRect(x: 20, y: 338, width: 22, height: 22))
        installSpinner.style = .spinning
        installSpinner.isIndeterminate = true
        installSpinner.startAnimation(nil)
        let installCaption = NSTextField(labelWithString: "Installing ffmpeg via Homebrew — this can take a few minutes…")
        installCaption.font = NSFont.systemFont(ofSize: 11)
        installCaption.frame = NSRect(x: 50, y: 342, width: 450, height: 16)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: 480, height: 250))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        installLog = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 250))
        installLog.isEditable = false
        installLog.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        scroll.documentView = installLog

        installGroup = install
        for v in [installSpinner, installCaption, scroll] as [NSView] {
            install.addSubview(v)
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        content.addSubview(setupGroup)
        content.addSubview(progressGroup)
        content.addSubview(doneGroup)
        content.addSubview(installGroup)
        w.contentView = content
        window = w
        showSetup()
    }

    private func showOnly(_ group: NSView?) {
        for g in [setupGroup, progressGroup, doneGroup, installGroup] as [NSView] {
            g.isHidden = (g !== group)
        }
    }

    // MARK: setup mode

    private func showSetup() {
        showOnly(setupGroup)
        refreshOutputLabel()
        updatePresetDesc()
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        filePathLabel.stringValue = url.path
        sourceToken = nil
        refreshOutputLabel()
        probeSourceFormat(url)
    }

    /// Read the source's dimensions and detect its stereo layout so the
    /// output filename can carry the layout token before the width suffix).
    private func probeSourceFormat(_ url: URL) {
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  size.width > 0, size.height > 0 else { return }
            let info = VideoFormat.detect(width: Int(abs(size.width)),
                                          height: Int(abs(size.height)),
                                          filename: url.lastPathComponent)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch info.format {
                case .sbs: self.sourceToken = "sbs"
                case .ou: self.sourceToken = "3dtb"
                case .mono: self.sourceToken = nil
                }
                self.refreshOutputLabel()
            }
        }
    }

    /// Output file name: layout token (when detected) + target width.
    private func outputName() -> String {
        guard let fileURL else { return "" }
        var stem = fileURL.deletingPathExtension().lastPathComponent + ".rayneo"
        if let t = sourceToken { stem += ".\(t)" }
        return stem + ".\(selectedWidthLabel()).mp4"
    }

    @objc private func setupChanged() {
        refreshOutputLabel()
        updatePresetDesc()
    }

    /// One-line explanation of the selected codec + preset combination, so
    /// "fast/medium/slow" isn't guesswork. The VideoToolbox path is the
    /// default: measured ~0.55× realtime for an 8K HEVC source on this
    /// M1, where software decode is the bottleneck — presets have no effect.
    private func updatePresetDesc() {
        let text: String
        switch (codecPopup.indexOfSelectedItem, presetPopup.indexOfSelectedItem) {
        case (2, _):
            text = "hardware encode — ~0.5–0.6× realtime for 8K sources (decode-bound); preset ignored"
        case (1, 1):
            text = "fast — quickest x264 encode; files stay larger"
        case (1, 2):
            text = "slow — best quality per byte, several times slower than hardware encode"
        case (1, _):
            text = "medium — balanced; several times faster than H.265"
        case (0, 1):
            text = "fast — quickest x265 encode; files stay larger"
        case (0, 2):
            text = "slow — smallest files; on the M1 this can drop below realtime"
        case (0, _):
            text = "medium — balanced; roughly realtime for 4K on the M1"
        default:
            text = ""
        }
        presetDesc.stringValue = text
    }

    private func refreshOutputLabel() {
        guard let fileURL else {
            startButton?.isEnabled = false
            return
        }
        startButton?.isEnabled = true
        let name = outputName()
        outputLabel.stringValue = "→ \(name) (same folder)"
    }

    private func selectedWidth() -> Int? {
        switch widthPopup.indexOfSelectedItem {
        case 0: return 3840
        case 1: return 2560
        case 2: return 1920
        case 3: return 1280
        default: return nil // keep source size
        }
    }

    private func selectedWidthLabel() -> String {
        switch widthPopup.indexOfSelectedItem {
        case 0: return "3840"
        case 1: return "2560"
        case 2: return "1920"
        case 3: return "1280"
        default: return "src"
        }
    }

    // MARK: transcode run

    @objc private func startClicked() {
        guard let input = fileURL, let ff = ffmpegPath else { return }
        triedH264Fallback = false
        lastErrorLines = []
        let width = selectedWidth()
        let preset = presetPopup.titleOfSelectedItem?.lowercased() ?? "medium"

        let name = outputName()
        let out = input.deletingLastPathComponent().appendingPathComponent(name)
        outputURL = out

        var args = ["-y", "-i", input.path]
        if let width { args += ["-vf", "scale=\(width):-2"] }
        switch codecPopup.indexOfSelectedItem {
        case 2: // H.265 software
            args += ["-c:v", "libx265", "-tag:v", "hvc1", "-crf", "22"]
        case 1: // H.264 software
            args += ["-c:v", "libx264", "-crf", "20"]
        default: // H.264 hardware (VideoToolbox) — bitrate scales with width
            let bitrate: Int
            switch width ?? 3840 {
            case 2560: bitrate = 16
            case 1920: bitrate = 10
            case 1280: bitrate = 6
            default: bitrate = 25 // 3840 / keep-source
            }
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)M"]
        }
        args += ["-preset", preset, "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k",
                 "-movflags", "+faststart", out.path]

        progressTitle.stringValue = "Transcoding…"
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        processedLabel.stringValue = "processed — of —"
        etaLabel.stringValue = "estimating total length…"
        speedLabel.stringValue = ""
        speedFactor = 0
        logView.string = ""
        startedAt = Date()
        showOnly(progressGroup)
        run(args: args, ffmpeg: ff, useH264: false)
    }

    private func run(args: [String], ffmpeg: String, useH264: Bool) {
        var finalArgs = args
        if useH264 {
            if let i = finalArgs.firstIndex(of: "libx265") { finalArgs[i] = "libx264" }
            if let i = finalArgs.firstIndex(of: "-tag:v") {
                finalArgs.removeSubrange(i...(i + 1))
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = finalArgs
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice

        process = p
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finished(exit: Int(proc.terminationStatus)) }
        }
        do {
            try p.run()
        } catch {
            finished(exit: -1)
            return
        }
        // Stream stderr (split on \n and \r — ffmpeg progress uses \r).
        DispatchQueue.global().async { [weak self] in
            let fh = pipe.fileHandleForReading
            var pending = ""
            while true {
                let data = fh.availableData
                if data.isEmpty { break }
                for ch in String(data: data, encoding: .utf8) ?? "" {
                    if ch == "\n" || ch == "\r" {
                        let line = pending
                        pending = ""
                        if !line.isEmpty {
                            DispatchQueue.main.async { [weak self] in self?.handleLine(line) }
                        }
                    } else {
                        pending.append(ch)
                    }
                }
            }
            if !pending.isEmpty {
                let line = pending
                DispatchQueue.main.async { [weak self] in self?.handleLine(line) }
            }
        }
    }

    private func handleLine(_ line: String) {
        lastErrorLines.append(line)
        if lastErrorLines.count > 40 { lastErrorLines.removeFirst() }
        appendLog(line)

        if line.contains("Unknown encoder 'libx265'"), !triedH264Fallback {
            // Minimal ffmpeg build without x265 — retry with H.264.
            triedH264Fallback = true
            appendLog("→ no HEVC encoder in this ffmpeg build — retrying with libx264")
            if var args = process?.arguments {
                if let i = args.firstIndex(of: "libx265") { args[i] = "libx264" }
                if let i = args.firstIndex(of: "-tag:v") { args.removeSubrange(i...(i + 1)) }
                process = nil
                if let ff = ffmpegPath { run(args: args, ffmpeg: ff, useH264: false) }
            }
            return
        }
        if line.contains("Unknown encoder 'h264_videotoolbox'"), !triedH264Fallback {
            // No VideoToolbox in this ffmpeg build — retry with libx264.
            triedH264Fallback = true
            appendLog("→ no VideoToolbox encoder in this ffmpeg build — retrying with libx264")
            if var args = process?.arguments, let i = args.firstIndex(of: "h264_videotoolbox") {
                args[i] = "libx264"
                if let b = args.firstIndex(of: "-b:v") { args.removeSubrange(b...(b + 1)) }
                args.insert(contentsOf: ["-crf", "20"], at: i + 1)
                process = nil
                if let ff = ffmpegPath { run(args: args, ffmpeg: ff, useH264: false) }
            }
            return
        }

        // Source duration ("Duration: hh:mm:ss.ss," on the input probe line).
        if let dur = timeSeconds(in: line, key: "Duration: "), dur > 0 {
            durationSec = dur
            processedLabel.stringValue = "processed — of \(hms(dur))"
        }

        // ffmpeg progress line: frame= fps= q= size= time= bitrate= speed=
        guard durationSec > 0, let t = timeSeconds(in: line, key: "time=") else {
            updateThroughput(line) // still refresh speed/fps even without a duration
            return
        }
        progressBar.isIndeterminate = false
        progressBar.stopAnimation(nil)
        let frac = min(1, t / durationSec)
        progressBar.doubleValue = frac * 100
        progressTitle.stringValue = String(format: "Transcoding… %.0f%%", frac * 100)
        processedLabel.stringValue = String(
            format: "processed %@ of %@", hms(t), hms(durationSec))
        updateETA(processed: t)
        updateThroughput(line)
    }

    /// speed / size / fps row — parsed independently of the duration so it
    /// shows even before the total length is known.
    private func updateThroughput(_ line: String) {
        var parts: [String] = []
        if let speed = token(after: "speed=", in: line) {
            // "0.34x" → 0.34; drives the wall-clock finish projection.
            speedFactor = Double(speed.dropLast()) ?? speedFactor
            parts.append("speed \(speed.dropLast())× realtime") // "0.34x" → "0.34×"
        }
        if let size = token(after: "size=", in: line) {
            let digits = size.prefix { $0.isNumber || $0 == "." }
            if let kb = Double(digits) {
                parts.append(String(format: "%.0f MB written", kb / 1024))
            }
        }
        if let fps = token(after: "fps=", in: line) {
            parts.append("\(fps) fps")
        }
        if !parts.isEmpty { speedLabel.stringValue = parts.joined(separator: " · ") }
    }

    /// Projected render time: elapsed, remaining, and the wall-clock moment
    /// the file should be done. Remaining *processing* time is video-time
    /// remaining divided by ffmpeg's speed factor — at a low realtime factor
    /// each minute of video needs several minutes of encoding.
    private func updateETA(processed t: Double) {
        let remaining = max(0, durationSec - t)
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        // Until ffmpeg has warmed up its speed estimate, assume its current
        // factor (0 → fall back to assuming 1× only for the first moments).
        let procRemaining = speedFactor > 0.05 ? remaining / speedFactor : remaining
        let finish = DateFormatter.localizedString(
            from: Date().addingTimeInterval(procRemaining), dateStyle: .none, timeStyle: .short)
        etaLabel.stringValue = String(
            format: "elapsed %d:%02d · ~%d:%02d remaining · projected render time ~%@",
            Int(elapsed) / 60, Int(elapsed) % 60,
            Int(procRemaining) / 3600, (Int(procRemaining) / 60) % 60, finish)
    }

    private func appendLog(_ line: String) {
        logView.string += line + "\n"
        if logView.string.count > 12_000 { logView.string = String(logView.string.suffix(8_000)) }
        logView.scrollRangeToVisible(NSRange(location: (logView.string as NSString).length, length: 0))
    }

    private var durationSec = 0.0
    /// ffmpeg's reported realtime factor ("0.34x") — the finish projection
    /// divides remaining video time by this, so a 0.3× encode doesn't get a
    /// wall-clock estimate (sustained thermal throttling makes
    /// this the honest rate on a fanless M1).
    private var speedFactor = 0.0

    /// Whitespace-delimited token following `key` (e.g. "time=hh:mm:ss.ss").
    /// Skips ffmpeg's field padding ("size=    30720KiB") before reading.
    private func token(after key: String, in line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let tail = line[range.upperBound...].drop(while: { $0 == " " })
        let tok = tail.prefix { !$0.isWhitespace }
        return tok.isEmpty ? nil : String(tok)
    }

    /// h:mm:ss(.ff) after `key` — regex so trailing characters (the comma in
    /// "Duration: hh:mm:ss.ss, start:" etc.) can't break the parse.
    private func timeSeconds(in line: String, key: String) -> Double? {
        guard let tok = token(after: key, in: line),
              let match = tok.range(of: #"^\d+:\d+:\d+(?:\.\d+)?"#,
                                    options: .regularExpression) else { return nil }
        let parts = tok[match].split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private func hms(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func finished(exit: Int) {
        guard let out = outputURL else { return }
        if exit == 0 {
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
            progressBar.doubleValue = 100
            progressTitle.stringValue = "Transcoding… 100%"
            etaLabel.stringValue = "done"
            speedLabel.stringValue = ""
            doneLabel.stringValue = "Done — \(out.lastPathComponent)"
            showOnly(doneGroup)
        } else if process?.isRunning == false, triedH264Fallback || exit != 0 {
            let alert = NSAlert()
            alert.messageText = "Transcode failed (exit \(exit))"
            alert.informativeText = lastErrorLines.suffix(8).joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            showSetup()
        }
    }

    @objc private func cancelClicked() {
        process?.terminate()
        showSetup()
    }

    @objc private func openInPlayerClicked() {
        guard let out = outputURL else { return }
        window?.close()
        onOpenInPlayer?(out)
    }

    @objc private func showInFinderClicked() {
        guard let out = outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([out])
    }

    // MARK: ffmpeg installation

    private func offerInstall() {
        let alert = NSAlert()
        alert.messageText = "ffmpeg is not installed"
        if let brew = FFmpeg.brewPath() {
            alert.informativeText = """
                The transcoder uses the ffmpeg command-line tool, which isn't on this Mac.
                Homebrew is installed — install ffmpeg with it now?
                """
            alert.addButton(withTitle: "Install via Homebrew")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                installWithBrew(brew)
            }
        } else {
            alert.informativeText = """
                The transcoder uses the ffmpeg command-line tool, which isn't on this Mac.

                Easiest: install Homebrew, then ffmpeg — paste in Terminal:

                  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                  brew install ffmpeg

                Or download a build from https://ffmpeg.org/download.html and put the
                ffmpeg binary somewhere in your PATH.
                """
            alert.addButton(withTitle: "Copy install commands")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("""
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                    brew install ffmpeg
                    """, forType: .string)
            }
        }
    }

    private func installWithBrew(_ brew: String) {
        showOnly(installGroup)
        installLog.string = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["install", "ffmpeg"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        process = p
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.ffmpegPath = FFmpeg.locate()
                if self.ffmpegPath != nil {
                    let ok = NSAlert()
                    ok.messageText = "ffmpeg installed"
                    ok.informativeText = "The transcoder is ready."
                    ok.addButton(withTitle: "Continue")
                    ok.runModal()
                    self.showSetup()
                    self.window?.center()
                } else {
                    let err = NSAlert()
                    err.messageText = "Homebrew install didn't produce ffmpeg (exit \(proc.terminationStatus))"
                    err.informativeText = "See the log below; you can retry or install manually."
                    err.addButton(withTitle: "OK")
                    err.runModal()
                    self.offerInstall()
                }
            }
        }
        do {
            try p.run()
        } catch {
            installLog.string += "failed to launch brew: \(error)\n"
            return
        }
        DispatchQueue.global().async { [weak self] in
            let fh = pipe.fileHandleForReading
            var pending = ""
            while true {
                let data = fh.availableData
                if data.isEmpty { break }
                for ch in String(data: data, encoding: .utf8) ?? "" {
                    if ch == "\n" || ch == "\r" {
                        let line = pending
                        pending = ""
                        if !line.isEmpty {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, let log = self.installLog else { return }
                                log.string += line + "\n"
                                log.scrollRangeToVisible(NSRange(location: (log.string as NSString).length, length: 0))
                            }
                        }
                    } else {
                        pending.append(ch)
                    }
                }
            }
        }
    }
}
