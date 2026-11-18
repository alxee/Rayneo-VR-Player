// OrientationFuser.swift — Mahony AHRS with gyro-bias calibration and
// rest-detection, verbatim port of the extension's rayneo-hid.js `_fuse()`
// (as also carried in the IINA plugin's lib/imu.js).
//
// Pipeline:
//   1. Startup bias calibration — ~150 still samples (~1.3 s) estimate the
//      gyro bias; any motion resets the window.
//   2. Rest detection (VQF-style) — while still, the low-passed gyro
//      continuously refines the bias, compensating thermal drift.
//   3. Mahony complementary filter — gyro integration, gravity-corrected by
//      the accelerometer with gating (rejected while accelerating or during
//      fast turns, fast re-convergence after long rejections).
//   4. Yaw-only recentering — standard 3DoF XR behavior.
//
// Device frame: x right, y up, z toward the face — matching the WebXR viewer
// frame, so the fused orientation maps 1:1 onto the view.

import Foundation

public struct Quat {
    public var w: Double, x: Double, y: Double, z: Double

    static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    public func normalized() -> Quat {
        let m = (w * w + x * x + y * y + z * z).squareRoot()
        guard m > 1e-12 else { return .identity }
        return Quat(w: w / m, x: x / m, y: y / m, z: z / m)
    }

    public static func axisAngle(_ ax: (Double, Double, Double), _ angle: Double) -> Quat {
        let s = (angle / 2).sine()
        let m = (ax.0 * ax.0 + ax.1 * ax.1 + ax.2 * ax.2).squareRoot()
        let inv = m < 1e-12 ? 0 : 1 / m
        return Quat(w: (angle / 2).cosine(), x: ax.0 * inv * s, y: ax.1 * inv * s, z: ax.2 * inv * s)
    }

    /// Rotate vector v by q (v is an [x, y, z] array).
    public func rotate(_ v: [Double]) -> [Double] {
        let qv = Quat(w: 0, x: v[0], y: v[1], z: v[2])
        let t = self * qv * conjugate
        return [t.x, t.y, t.z]
    }

    /// Quaternion that rotates unit vector a onto unit vector b.
    public static func fromTo(_ a: [Double], _ b: [Double]) -> Quat {
        let d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
        if d > 0.999999 { return .identity }
        if d < -0.999999 {
            // 180° about any axis orthogonal to a
            var ax = [1.0, 0.0, 0.0]
            if abs(a[0]) > 0.9 { ax = [0, 1, 0] }
            let orth = [
                ax[1] * a[2] - ax[2] * a[1],
                ax[2] * a[0] - ax[0] * a[2],
                ax[0] * a[1] - ax[1] * a[0],
            ]
            return axisAngle((orth[0], orth[1], orth[2]), .pi)
        }
        let cross = [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ]
        return Quat(w: 1 + d, x: cross[0], y: cross[1], z: cross[2]).normalized()
    }
}

private extension Double {
    func sine() -> Double { Darwin.sin(self) }
    func cosine() -> Double { Darwin.cos(self) }
}

/// The fuser — port of the extension's `_fuse()` / `recenter()`.
public final class OrientationFuser {
    static let degreesToRadians = Double.pi / 180

    // Same tuning as the extension.
    static let kp = 0.5                      // Mahony proportional gain
    static let calibSamples = 150            // ~1.3 s of still samples
    static let calibMaxGyro = 3 * degreesToRadians  // rad/s per axis allowed during calibration

    public private(set) var quaternion = Quat.identity

    private var initialized = false
    private var q: Quat?
    private var lastTick: UInt32 = 0
    private var lpAcc: [Double] = [0, 0, 0]
    private var lpGyro: [Double] = [0, 0, 0]
    private var bias: [Double] = [0, 0, 0]   // gyro bias, rad/s
    private var calCount = 0
    private var calSum: [Double] = [0, 0, 0]
    public private(set) var calibrated = false
    /// Fired when startup calibration completes (also used to persist the
    /// bias across sessions).
    public var onCalibrated: (() -> Void)?
    private var rejectTime: Double = 0
    private var stillTime: Double = 0
    private var yawRef: Quat?                // yaw reference for recentering
    private var log: ((String) -> Void)?

    public init(log: ((String) -> Void)? = nil) {
        self.log = log
    }

    /// Current gyro bias in deg/s (for persistence).
    public var currentBiasDegPerSec: [Double] {
        bias.map { $0 / Self.degreesToRadians }
    }

    /// Warm start: adopt a bias persisted from a previous session and skip
    /// startup calibration. Pitch/roll are unaffected (they initialize from
    /// the accelerometer), and the rest detector keeps refining the bias, so
    /// a stale value self-corrects on the first stillness.
    public func warmStart(biasDegPerSec: [Double]) {
        guard !calibrated, biasDegPerSec.count == 3 else { return }
        bias = biasDegPerSec.map { $0 * Self.degreesToRadians }
        calibrated = true
        log?("warm start: gyro bias from previous session (" + biasDegPerSec.map { String(format: "%.3f", $0) }.joined(separator: ", ") + " deg/s)")
    }

    /// Feed one raw sample (accel m/s^2, gyro deg/s, device tick counter).
    public func feed(_ accel: (Double, Double, Double), _ gyroDeg: (Double, Double, Double), _ tick: UInt32) {
        let gyro = [gyroDeg.0 * Self.degreesToRadians, gyroDeg.1 * Self.degreesToRadians, gyroDeg.2 * Self.degreesToRadians]
        fuse([accel.0, accel.1, accel.2], gyro, tick)
    }

    private func fuse(_ acc: [Double], _ gyro: [Double], _ tick: UInt32) {
        guard let qCur = q else {
            let an = (acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]).squareRoot()
            guard an >= 1 else { return }
            // Initialize orientation from gravity: map measured "up" onto world +y
            q = Quat.fromTo([acc[0] / an, acc[1] / an, acc[2] / an], [0, 1, 0])
            initialized = true
            lastTick = tick
            lpAcc = acc
            lpGyro = gyro
            return
        }
        _ = qCur

        if tick == lastTick { return } // glasses re-send the last sample when idle
        let dt = Double(tick &- lastTick) * 1e-4
        lastTick = tick
        guard dt > 0, dt <= 0.05 else { return } // bad/first dt after a stall

        // --- Startup bias calibration: mean of still samples -------------------
        if !calibrated {
            let moving = max(abs(gyro[0]), abs(gyro[1]), abs(gyro[2])) > Self.calibMaxGyro
            if moving {
                calCount = 0
                calSum = [0, 0, 0]
            } else {
                for i in 0..<3 { calSum[i] += gyro[i] }
                calCount += 1
                if calCount >= Self.calibSamples {
                    bias = calSum.map { $0 / Double(calCount) }
                    calibrated = true
                    log?("gyro bias calibrated: " + bias.map { String(format: "%.3f", $0 / Self.degreesToRadians) }.joined(separator: ", ") + " deg/s")
                    onCalibrated?()
                    recenter() // define "forward" once we're stable
                }
            }
        }

        // --- Low-pass for rest detection (VQF-style) ---------------------------
        let k = min(dt / 0.5, 1)
        for i in 0..<3 {
            lpGyro[i] += (gyro[i] - lpGyro[i]) * k
            lpAcc[i] += (acc[i] - lpAcc[i]) * k
        }

        // At rest: gyro matches its own low-pass, the low-passed gyro is close
        // to the current bias, and the accelerometer is steady. Then the
        // low-passed gyro IS the bias (drift correction).
        let gyroJitter = ((gyro[0] - lpGyro[0]) * (gyro[0] - lpGyro[0])
            + (gyro[1] - lpGyro[1]) * (gyro[1] - lpGyro[1])
            + (gyro[2] - lpGyro[2]) * (gyro[2] - lpGyro[2])).squareRoot()
        let accJitter = ((acc[0] - lpAcc[0]) * (acc[0] - lpAcc[0])
            + (acc[1] - lpAcc[1]) * (acc[1] - lpAcc[1])
            + (acc[2] - lpAcc[2]) * (acc[2] - lpAcc[2])).squareRoot()
        var corrMax = 0.0
        for i in 0..<3 { corrMax = max(corrMax, abs(lpGyro[i] - bias[i])) }
        let resting = gyroJitter < 2 * Self.degreesToRadians
            && corrMax < 0.6 * Self.degreesToRadians
            && accJitter < 0.5

        stillTime = resting ? stillTime + dt : 0
        if stillTime > 1.5 {
            let kb = min(dt / 3, 1)
            for i in 0..<3 { bias[i] += (lpGyro[i] - bias[i]) * kb }
        }

        // --- Mahony correction -------------------------------------------------
        let w = [gyro[0] - bias[0], gyro[1] - bias[1], gyro[2] - bias[2]]
        var wc = w
        let an = (acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]).squareRoot()

        if an > 7, an < 12.5 {
            let measuredUp = [acc[0] / an, acc[1] / an, acc[2] / an]
            let estimatedUp = (q!).conjugate.rotate([0, 1, 0]) // world up in device frame
            let err = [
                measuredUp[1] * estimatedUp[2] - measuredUp[2] * estimatedUp[1],
                measuredUp[2] * estimatedUp[0] - measuredUp[0] * estimatedUp[2],
                measuredUp[0] * estimatedUp[1] - measuredUp[1] * estimatedUp[0],
            ]
            let errMag = (err[0] * err[0] + err[1] * err[1] + err[2] * err[2]).squareRoot()
            let errAngle = Darwin.asin(min(1, errMag))

            let accept = (abs(an - 9.81) < 1.5 && errAngle < 10 * Self.degreesToRadians) || rejectTime > 3
            var gain = Self.kp / (1 + (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot() / 2)

            if accept {
                // After a long rejection, converge fast once (x-io Fusion style)
                if rejectTime > 3 { gain *= 5 }
                rejectTime = 0
                wc = [wc[0] + gain * err[0], wc[1] + gain * err[1], wc[2] + gain * err[2]]
            } else {
                // Fast head turns leak centripetal acceleration into the reading
                rejectTime += dt
            }
        }

        // Integrate: q = q * quat(wc * dt)   (body-frame angular velocity)
        let wMag = (wc[0] * wc[0] + wc[1] * wc[1] + wc[2] * wc[2]).squareRoot()
        let angle = wMag * dt
        if angle > 1e-12 {
            q = (q! * Quat.axisAngle((wc[0], wc[1], wc[2]), angle)).normalized()
        }

        // --- Pose with yaw-only recentering ------------------------------------
        if let yawRef {
            quaternion = (yawRef.conjugate * q!).normalized()
        } else {
            quaternion = q!
        }
    }

    /// Reset yaw to the current facing direction; keep pitch and roll absolute.
    public func recenter() {
        guard let q else { return }
        let f = q.rotate([0, 0, -1]) // forward in world frame
        let yaw = Darwin.atan2(-f[0], -f[2])
        let ref = Quat.axisAngle((0, 1, 0), yaw)
        yawRef = ref
        quaternion = (ref.conjugate * q).normalized()
    }

    /// Full recalibration (triple-tap in the XR driver): drop the bias and
    /// orientation so the next ~1.3 s of still samples re-runs startup
    /// calibration from scratch. Use when drift/noise creeps in.
    public func recalibrate() {
        q = nil
        lastTick = 0
        bias = [0, 0, 0]
        calCount = 0
        calSum = [0, 0, 0]
        calibrated = false
        stillTime = 0
        rejectTime = 0
        yawRef = nil
        lpGyro = [0, 0, 0]
        lpAcc = [0, 0, 0]
        quaternion = .identity
        log?("recalibration requested — hold still ~1.3 s")
    }

    /// Yaw/pitch/roll of the current view in degrees.
    /// Port of the extension's trackingFrame() math: forward = rotate(q, [0,0,-1]),
    /// yaw = atan2(fx, -fz), pitch = asin(-fy), roll from the right vector.
    /// The view should follow the head: negate both, same convention the
    /// extension uses for YouTube's spherical renderer. Flip the signs here if
    /// the directions feel inverted on a different consumer.
    public func viewAngles() -> (yaw: Double, pitch: Double, roll: Double) {
        let f = quaternion.rotate([0, 0, -1])
        var yaw = Darwin.atan2(f[0], -f[2]) / Self.degreesToRadians
        var pitch = Darwin.asin(max(-1, min(1, -f[1]))) / Self.degreesToRadians
        yaw = -yaw
        pitch = -pitch
        let r = quaternion.rotate([1, 0, 0])
        let roll = Darwin.atan2(r[1], r[0]) / Self.degreesToRadians
        return (yaw, pitch, roll)
    }
}
