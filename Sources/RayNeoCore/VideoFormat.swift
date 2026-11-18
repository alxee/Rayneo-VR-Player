// VideoFormat.swift — VR/stereo video format detection.
//
// Port of the IINA plugin's lib/video-modes.js detection heuristics (itself
// derived from the WebXR extension's youtube-vr.js getVRInfo): filename
// tokens first, then per-eye frame-shape heuristics, with an explicit hint
// for ambiguous files instead of a silent guess.

import Foundation

public struct VideoInfo {
    public enum StereoFormat: String {
        case sbs   // side-by-side pair
        case ou    // over/under pair
        case mono  // single view
    }

    /// 0 = flat, 180 or 360 = spherical content.
    public var degree: Int
    public var format: StereoFormat
    public var width: Int
    public var height: Int
    /// Human-readable explanation of how the detection decided, or a warning
    /// when the file is ambiguous ("checker" OSD in the plugin).
    public var hint: String?

    public var spherical: Bool { degree == 180 || degree == 360 }

    public var modeName: String {
        var parts: [String] = []
        if degree != 0 { parts.append("\(degree)°") }
        switch format {
        case .sbs: parts.append("side-by-side")
        case .ou: parts.append("over/under")
        case .mono: parts.append("mono")
        }
        parts.append("\(width)×\(height)")
        return parts.joined(separator: " ")
    }
}

public enum VideoFormat {
    // MARK: - Detection

    /// Detect from video dimensions + filename tokens. `width`/`height` are
    /// the decoded frame dimensions (for stereo pairs, BOTH eyes).
    public static func detect(width: Int, height: Int, filename: String) -> VideoInfo {
        let words = Set(
            filename.lowercased()
                .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
                .map(String.init))

        // Stereo layout token (word-boundary matched, so "sound" or
        // "heartbeat" cannot false-positive). "3d" is a weak token: it says
        // stereo-ish content but not the layout, so it's resolved by the
        // per-eye aspect heuristics below instead of being trusted outright.
        var format: VideoInfo.StereoFormat
        var tokenHint: String? = nil
        if words.contains("sbs") || words.contains("hsbs") || words.contains("3dsbs") {
            format = .sbs
            tokenHint = "'sbs' in filename"
        } else if words.contains("ou") || words.contains("tb") || words.contains("oub")
            || words.contains("utb") || words.contains("3dtb") || words.contains("3dou")
            || words.contains("overunder") || words.contains("topbottom") {
            format = .ou
            tokenHint = "'ou'/'tb' in filename"
        } else {
            format = .mono
            tokenHint = words.contains("3d") ? "'3d' in filename" : nil
        }

        // Spherical token.
        var degree = 0
        var degreeToken: String? = nil
        if words.contains("180") || words.contains("vr180") || words.contains("vr1803d") {
            degree = 180
            degreeToken = "180"
        } else if words.contains("360") || words.contains("vr360") || words.contains("360vr") {
            degree = 360
            degreeToken = "360"
        }

        // Aspect-ratio heuristics (per-eye shapes: 360 mono 2:1, 360 SBS 4:1,
        // VR180 SBS 2:1, VR180 mono 1:1). Note a plain 1080p SBS movie is
        // 3840x1080 ≈ 3.56:1 — between the spherical shapes — so aspect alone
        // never overrides tokens.
        let aspect = Double(width) / Double(max(1, height))
        func near(_ target: Double, _ tol: Double = 0.12) -> Bool {
            abs(aspect - target) <= target * tol
        }

        var hint: String? = nil
        if format == .sbs || format == .ou {
            // Stereo token wins; spherical only if a degree token or an
            // unambiguous spherical shape agrees.
            if degree == 0 && degreeToken == nil {
                if near(4.0) && format == .sbs {
                    degree = 360
                    hint = "≈4:1 stereo frame — assuming 360° SBS"
                } else if near(2.0) {
                    hint = "≈2:1 stereo frame — could be VR180 SBS (cycle mode if the view is wrong)"
                }
            }
        } else if degreeToken != nil {
            // Degree token without stereo token: infer the layout from the
            // canonical VR frame shapes — 180° mono is 1:1, VR180 SBS is 2:1;
            // 360° mono is 2:1, 360° SBS is 4:1.
            if degree == 360 && near(2.0) { /* 360 mono, canonical shape */ }
            else if degree == 180 && near(1.0) { /* 180 mono, canonical */ }
            else if degree == 180 && near(2.0) {
                format = .sbs
                hint = "'180°' + 2:1 frame — assuming VR180 SBS (cycle mode if it plays mono)"
            } else if degree == 360 && near(4.0) {
                format = .sbs
                hint = "'360°' + 4:1 frame — assuming 360° SBS"
            } else {
                hint = "\(degree)° token on an unusual frame shape — cycle mode to check"
            }
        } else if near(4.0) {
            degree = 360
            format = .sbs
            hint = "≈4:1 frame — assuming 360° SBS"
        } else if near(2.0) {
            if tokenHint == "'3d' in filename" {
                // "3d" + 2:1 frame (per-eye 1:1) — the canonical VR180 SBS
                // shape. Absolute ±0.12 band, so a 16:9 "3d" movie (≈1.78)
                // stays flat.
                if abs(aspect - 2.0) <= 0.12 {
                    degree = 180
                    format = .sbs
                    hint = "'3d' + 2:1 frame — assuming VR180 SBS (cycle mode if the view is wrong)"
                } else {
                    hint = "'3d' in filename — if this is 3D, cycle mode"
                }
            } else if tokenHint != nil {
                hint = "2:1 frame — could be VR180 SBS. Cycle mode to check"
            } else {
                hint = "2:1 frame — could be 360° mono (or 180° SBS). Cycle mode to enable a spherical view"
            }
        } else if near(1.0) {
            hint = "square frame — could be VR180° mono. Cycle mode to enable a spherical view"
        }

        if degreeToken != nil, format != .mono {
            hint = hint ?? "'\(degree)°' + '\(format.rawValue)' in filename"
        } else if degreeToken != nil {
            hint = hint ?? "'\(degree)°' in filename"
        } else if tokenHint != nil {
            hint = hint ?? tokenHint
        }

        return VideoInfo(degree: degree, format: format, width: width, height: height, hint: hint)
    }

    // MARK: - Mode planning

    /// Render modes (same names as the IINA plugin's video-modes):
    ///   flatsbs    — SBS pair passthrough (each eye sees its half)
    ///   flatou     — over/under pair converted to SBS on the fly
    ///   flatmono   — stereo collapsed to one eye / mono shown as-is
    ///   360sbs     — 360° stereo per-eye re-projection (head tracked)
    ///   180sbs     — 180° stereo per-eye re-projection (head tracked)
    ///   360mono    — 360° mono, same re-projected view to both eyes
    ///   180mono    — 180° mono, same re-projected view to both eyes
    public static func modesFor(_ info: VideoInfo) -> [String] {
        if info.spherical {
            let stem = info.degree == 180 ? "180" : "360"
            if info.format == .mono {
                return [stem + "mono", stem + "sbs"]
            }
            return [stem + "sbs", stem + "mono"]
        }
        // Non-spherical content that matches a spherical per-eye shape stays
        // ambiguous — offer the spherical modes via cycle mode (C) rather
        // than blocking them. First entry is the default.
        switch info.format {
        case .sbs: return ["flatsbs", "flatmono"]
        case .ou: return ["flatou", "flatmono"]
        case .mono:
            let aspect = Double(info.width) / Double(max(1, info.height))
            if abs(aspect - 2.0) <= 0.24 {
                // 2:1-ish mono: 360° mono or VR180 (mono or SBS).
                return ["flatmono", "180mono", "180sbs", "360mono"]
            }
            if abs(aspect - 1.0) <= 0.12 {
                // Square mono: VR180 mono or SBS.
                return ["flatmono", "180mono", "180sbs"]
            }
            return ["flatmono"]
        }
    }

    public static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "flatsbs": return "flat 3D (SBS)"
        case "flatou": return "flat 3D (over/under)"
        case "flatmono": return "flat 2D"
        case "360sbs": return "360° stereo"
        case "180sbs": return "180° stereo"
        case "360mono": return "360° mono"
        case "180mono": return "180° mono"
        default: return mode
        }
    }

    /// Vertical FOV for spherical modes (degrees) — defaults match the
    /// extension's DEFAULT_FOV; the glasses' optics subtend ~46° diagonal,
    /// so much wider renders look tiny.
    public static func fovFor(_ info: VideoInfo?, mode: String, fov360: Double = 60, fov180: Double = 60) -> Double {
        mode.hasPrefix("180") ? fov180 : fov360
    }
}
