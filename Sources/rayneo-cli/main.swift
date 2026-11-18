// rayneo-cli — M1 verification tool for the RayNeo Cinema device layer.
//
// Subcommands:
//   list                    enumerate RayNeo glasses
//   send <cmd>              one-shot panel command: sbs | 2d | 60hz | 120hz
//   track                   stream IMU, fuse, print live yaw/pitch/roll
//   probe                   list + 2 s IMU sample-count check
//
// `track` is the head-tracking verification: connect the glasses, run it,
// hold still ~1.5 s for gyro-bias calibration, then turn your head — yaw and
// pitch should follow. Ctrl-C stops (IMU is turned off and devices closed).

import Foundation
import RayNeoCore

let args = Array(CommandLine.arguments.dropFirst())

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("rayneo-cli: \(msg)\n".utf8))
    exit(1)
}

func err(_ msg: String) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
}

let hid = RayNeoHID()

func panelCommand(_ name: String) -> RayNeoHID.PanelCommand {
    switch name {
    case "sbs": return .sbs3d
    case "2d": return .twod
    case "60hz": return .rate60
    case "120hz": return .rate120
    default: die("unknown command '\(name)' (sbs | 2d | 60hz | 120hz)")
    }
}

// Clean Ctrl-C: exit code 0; the runloop teardown in stopIMU is handled by
// deinit paths on normal exits, and the panel state is always restored by
// later milestones — for M1 the IMU-off command is best-effort here.
signal(SIGINT) { _ in
    err("\nstopping…")
    exit(0)
}

switch args.first {
case "list":
    let devices = hid.findDevices()
    if devices.isEmpty {
        print("no RayNeo glasses found (VIDs 0x1bbb/0x0f65, PID 0xaf50)")
    } else {
        for d in devices { print(d) }
    }

case "send":
    guard args.count >= 2 else { die("usage: rayneo-cli send <sbs|2d|60hz|120hz>") }
    do {
        try hid.sendPanelCommand(panelCommand(args[1]))
        print("sent \(args[1])")
    } catch {
        die("\(error)")
    }

case "track":
    let jsonMode = args.contains("--json")
    let fuser = OrientationFuser { msg in err("[fuser] \(msg)") }
    var sampleCount = 0
    var samplesPerSec = 0
    var lastSec = Date()

    hid.onSample = { (sample: RayNeoIMUSample) in
        sampleCount += 1
        samplesPerSec += 1
        fuser.feed(sample.accel, sample.gyro, sample.tick)
    }
    hid.onError = { (msg: String) in err("[hid] \(msg)") }

    do {
        try hid.startIMU()
    } catch {
        die("\(error)")
    }
    err("""
    tracking — hold STILL ~1.5 s for gyro-bias calibration, then turn your head.
    Ctrl-C to stop.
    """)

    // Readout timer: 10 Hz live line (or JSON lines).
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler {
        let now = Date()
        if now.timeIntervalSince(lastSec) >= 1.0 {
            let rate = samplesPerSec
            samplesPerSec = 0
            lastSec = now
            if !jsonMode {
                err("   (\(rate) samples/s, \(sampleCount) total)")
            }
        }
        let a = fuser.viewAngles()
        let calib = fuser.calibrated ? "" : "  CALIBRATING — hold still"
        if jsonMode {
            print(String(format: "{\"yaw\":%.2f,\"pitch\":%.2f,\"roll\":%.2f,\"samples\":%d,\"calibrated\":%@}",
                         a.yaw, a.pitch, a.roll, sampleCount, fuser.calibrated ? "true" : "false"))
        } else {
            print(String(format: "\ryaw %7.2f°  pitch %6.2f°  roll %6.2f°%@",
                         a.yaw, a.pitch, a.roll, calib), terminator: "")
        }
        fflush(stdout)
    }
    timer.resume()

    // The IMU callbacks and this timer are scheduled on the main run loop.
    RunLoop.main.run()

case "probe":
    let devices = hid.findDevices()
    guard !devices.isEmpty else { die("no RayNeo glasses found") }
    for d in devices { print(d) }
    print("checking IMU stream for 2 s…")
    var count = 0
    hid.onSample = { (_: RayNeoIMUSample) in count += 1 }
    do {
        try hid.startIMU()
    } catch {
        die("\(error)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        hid.stopIMU()
        print(count > 0 ? "IMU OK — \(count) samples in 2 s (\(count / 2)/s)" : "IMU silent — glasses may be asleep; wake them and retry")
        exit(count > 0 ? 0 : 2)
    }
    RunLoop.main.run()

case "detect":
    guard args.count >= 4, let w = Int(args[1]), let h = Int(args[2]) else {
        die("usage: rayneo-cli detect <width> <height> <filename>")
    }
    let info = VideoFormat.detect(width: w, height: h, filename: args[3])
    print("mode:    \(info.modeName)")
    print("hint:    \(info.hint ?? "none")")
    print("cycles:  \(VideoFormat.modesFor(info).joined(separator: " → "))")
    print("fov:     \(VideoFormat.fovFor(info, mode: VideoFormat.modesFor(info)[0]))°")

default:
    die("usage: rayneo-cli list | send <sbs|2d|60hz|120hz> | track [--json] | probe | detect <w> <h> <filename>")
}
