// PlaybackBar.swift — the playback overlay: status line (HUD) on top and a
// centered controls row (play/pause · time · scrubber · volume) below.
//
// One full-width instance sits at the bottom of the windowed player. In VR
// mode two half-width instances are laid out over each eye's half of the
// 3840-wide glasses panel, so the overlay reads as a single 3D bar through
// the glasses instead of being torn apart between the eyes.

import AppKit

final class PlaybackBar: NSVisualEffectView {
    var onTogglePlay: (() -> Void)?
    var onScrub: ((Double) -> Void)?    // 0…1 of the timeline
    var onScrubStart: (() -> Void)?
    var onVolume: ((Double) -> Void)?   // 0…1
    var onMuteToggle: (() -> Void)?
    var onPointerActivity: (() -> Void)?

    let statusLabel = NSTextField(labelWithString: "")
    let playButton = NSButton()
    let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let volumeButton = NSButton()
    let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    private var trackingAdded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .withinWindow
        state = .active

        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "play")
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playClicked)

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingHead

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        scrubber.isEnabled = false

        volumeButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                     accessibilityDescription: "speaker.wave.2.fill")
        volumeButton.isBordered = false
        volumeButton.target = self
        volumeButton.action = #selector(muteClicked)

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)

        let row = NSStackView(views: [playButton, timeLabel, scrubber, volumeButton, volumeSlider])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusLabel)
        addSubview(row)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),

            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            playButton.widthAnchor.constraint(equalToConstant: 26),
            playButton.heightAnchor.constraint(equalToConstant: 26),
            timeLabel.widthAnchor.constraint(equalToConstant: 100),
            scrubber.widthAnchor.constraint(equalToConstant: 380),
            volumeButton.widthAnchor.constraint(equalToConstant: 26),
            volumeButton.heightAnchor.constraint(equalToConstant: 26),
            volumeSlider.widthAnchor.constraint(equalToConstant: 96),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

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
        onPointerActivity?()
    }

    // MARK: state sync (the controller calls these for every bar)

    func setProgress(current t: Double, duration d: Double) {
        let hasDuration = d.isFinite && d > 0
        scrubber.isEnabled = hasDuration
        if hasDuration { scrubber.doubleValue = min(max(0, t / d), 1) }
        timeLabel.stringValue = "\(fmt(t)) / \(hasDuration ? fmt(d) : "--:--")"
    }

    func setPlaying(_ playing: Bool) {
        let symbol = playing ? "pause.fill" : "play.fill"
        if playButton.image?.accessibilityDescription != symbol {
            playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
    }

    func setVolume(_ volume: Double) {
        if abs(volumeSlider.doubleValue - volume) > 0.01 { volumeSlider.doubleValue = volume }
        let symbol = volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        if volumeButton.image?.accessibilityDescription != symbol {
            volumeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
    }

    func setStatus(_ text: String) {
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: actions

    @objc private func playClicked() { onTogglePlay?() }
    @objc private func muteClicked() { onMuteToggle?() }
    @objc private func volumeChanged() { onVolume?(volumeSlider.doubleValue) }
    @objc private func scrubbed() {
        onScrubStart?() // suppress auto-sync while the user is dragging
        onScrub?(scrubber.doubleValue)
    }
}
