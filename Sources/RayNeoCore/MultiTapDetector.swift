// MultiTapDetector.swift — multi-tap-on-the-temple detection from the
// glasses' gyro stream. Faithful port of wheaney/XRLinuxDriver's
// src/multitap.c (GPL-3.0), the Steam Deck XR Gaming plugin's driver.
//
// Key insight from that driver: a tap is a *rotational* jolt, so it detects
// spikes in the derivative of the angular-velocity magnitude (|ω|), not in
// linear acceleration — which makes it immune to walking bumps and being
// carried. State machine over the 25 ms sliding-window derivative:
//
//   IDLE  — derivative of |ω| exceeds 2000 °/s²  → RISE
//   RISE  — derivative flips negative            → FALL
//   FALL  — derivative flips positive again; the
//           rise→fall cycle must fit in 70 ms    → one tap counted, PAUSE
//   PAUSE — |derivative| stays under 100 °/s²
//           for ≥ 10 ms (the "knock" pause)      → IDLE (next tap)
//
// Taps accumulate for up to 750 ms from the first rise; the count is
// emitted when the window expires. 2 taps = recenter, 3 = recalibrate
// (same actions as the XR Gaming plugin).

import Foundation

public final class MultiTapDetector {
    /// |ω| derivative (°/s²) that starts a tap.
    public var detectThreshold = 2000.0
    /// |derivative| below this counts as a pause between taps (°/s²).
    public var pauseThreshold = 100.0
    /// Longest time-frame from the first rise for taps to accumulate.
    public var maxTapPeriod: TimeInterval = 0.75
    /// A single tap's rise→fall must be quicker than this.
    public var maxTapDuration: TimeInterval = 0.070
    /// Required stillness between taps.
    public var minPause: TimeInterval = 0.010
    /// Sliding-window width for the derivative.
    public var bufferWindow: TimeInterval = 0.025

    /// Fired once per gesture with the tap count (2, 3, …). Called from the
    /// IMU callback queue (main run loop).
    public var onTaps: ((Int) -> Void)?
    /// Optional debug trace of state transitions/derivatives.
    public var onDebug: ((String) -> Void)?

    private struct Sample { let tick: UInt32; let mag: Double }

    private enum State { case idle, rise, fall, pause }
    private var state: State = .idle
    private var buffer: [Sample] = []
    private var tapCount = 0
    private var tapStartTick: UInt32 = 0
    private var pauseStartTick: UInt32 = 0
    private var lastTick: UInt32 = 0
    private var gotFirst = false

    public init() {}

    /// Feed one gyro sample (deg/s, device tick in 100 µs units).
    @discardableResult
    public func feed(_ gyro: (Double, Double, Double), _ tick: UInt32) -> Int {
        guard gotFirst else { lastTick = tick; gotFirst = true; return 0 }
        guard tick != lastTick else { return 0 } // idle re-sends
        lastTick = tick

        let mag = (gyro.0 * gyro.0 + gyro.1 * gyro.1 + gyro.2 * gyro.2).squareRoot()
        buffer.append(Sample(tick: tick, mag: mag))
        // Drop samples older than the window (wrap-safe deltas).
        while buffer.count > 1,
              Double(tick &- buffer[0].tick) * 1e-4 > bufferWindow {
            buffer.removeFirst()
        }
        guard buffer.count >= 2 else { return 0 }

        let oldest = buffer[0]
        let dt = Double(tick &- oldest.tick) * 1e-4 // ≥ bufferWindow
        guard dt > 0 else { return 0 }
        let derivative = (mag - oldest.mag) / dt // °/s²

        var emit = 0
        // Sequence active? Expire it after maxTapPeriod from the first rise.
        if tapCount > 0 || state != .idle {
            let elapsed = Double(tick &- tapStartTick) * 1e-4
            if elapsed > maxTapPeriod {
                emit = tapCount
                state = .idle
                tapCount = 0
                buffer.removeAll(keepingCapacity: true)
                if emit > 0 {
                    onDebug?("emit \(emit)")
                    if let onTaps { onTaps(emit) }
                }
                return emit
            }
            switch state {
            case .idle:
                break
            case .rise:
                if derivative < 0 { state = .fall } // reversing direction
            case .fall:
                if derivative > 0 {
                    if elapsed > maxTapDuration {
                        onDebug?("too-long \(Int(elapsed * 1000))ms")
                        // Too slow to be a tap — abort the sequence.
                        state = .idle
                        tapCount = 0
                    } else {
                        tapCount += 1
                        pauseStartTick = tick
                        state = .pause
                        onDebug?("tap#\(tapCount)")
                    }
                }
            case .pause:
                if abs(derivative) < pauseThreshold {
                    if Double(tick &- pauseStartTick) * 1e-4 > minPause {
                        state = .idle // ready for the next tap
                    }
                } else {
                    pauseStartTick = tick // still moving; reset the pause timer
                }
            }
        }
        if state == .idle, derivative > detectThreshold {
            // NOTE: don't reset tapCount here — taps accumulate across the
            // whole maxTapPeriod window; only expiry clears it (same as the
            // C original).
            tapStartTick = tick
            state = .rise
            onDebug?("rise \(Int(derivative))")
        }
        return emit
    }

    /// Drop pending state (e.g. on reconnection).
    public func reset() {
        state = .idle
        tapCount = 0
        buffer.removeAll(keepingCapacity: true)
        gotFirst = false
    }
}
