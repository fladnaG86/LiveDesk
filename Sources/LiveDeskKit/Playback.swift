import AppKit
import CoreGraphics
import IOKit.ps

/// Inputs that decide whether wallpapers animate.
public struct PlaybackConditions: Equatable, Sendable {
    public var userPaused = false
    public var onBattery = false
    public var lowPowerMode = false
    public var screensAsleep = false
    public var sessionInactive = false
    public var coveredScreens: Set<String> = []

    public init() {}
}

public enum PlaybackPolicy {
    public static func shouldPlay(screen: String, conditions c: PlaybackConditions, settings s: PlaybackSettings) -> Bool {
        if c.userPaused || c.screensAsleep || c.sessionInactive { return false }
        if s.pauseOnBattery && c.onBattery { return false }
        if s.pauseInLowPowerMode && c.lowPowerMode { return false }
        if s.pauseWhenCovered && c.coveredScreens.contains(screen) { return false }
        return true
    }

    /// Human readable reason, nil when playing.
    public static func pauseReason(screen: String, conditions c: PlaybackConditions, settings s: PlaybackSettings) -> String? {
        if c.userPaused { return "In pausa" }
        if c.screensAsleep || c.sessionInactive { return "Schermo spento" }
        if s.pauseOnBattery && c.onBattery { return "A batteria" }
        if s.pauseInLowPowerMode && c.lowPowerMode { return "Risparmio energetico" }
        if s.pauseWhenCovered && c.coveredScreens.contains(screen) { return "Coperto da una finestra" }
        return nil
    }
}

/// A window as reported by CGWindowList, in global top-left coordinates.
public struct WindowRect: Equatable, Sendable {
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public var ownerPID: pid_t

    public init(layer: Int, bounds: CGRect, alpha: Double, ownerPID: pid_t) {
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
        self.ownerPID = ownerPID
    }
}

public enum OcclusionDetector {
    /// True when a single normal, opaque window covers at least `threshold` of the screen (fullscreen apps, maximized windows).
    public static func isCovered(screenBounds: CGRect, windows: [WindowRect], ownPID: pid_t, threshold: Double = 0.95) -> Bool {
        let area = screenBounds.width * screenBounds.height
        guard area > 0 else { return false }
        for w in windows where w.layer == 0 && w.ownerPID != ownPID && w.alpha >= 0.95 {
            let inter = w.bounds.intersection(screenBounds)
            guard !inter.isNull else { continue }
            if Double(inter.width * inter.height / area) >= threshold { return true }
        }
        return false
    }

    /// Live window list (bounds are readable without Screen Recording permission).
    public static func onScreenWindows() -> [WindowRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return WindowRect(layer: layer, bounds: bounds, alpha: alpha, ownerPID: pid_t(pid))
        }
    }
}

public enum PowerState {
    public static var onBattery: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    public static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
