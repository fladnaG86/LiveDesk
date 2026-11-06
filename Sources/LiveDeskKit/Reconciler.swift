import Foundation

/// What must change to go from the players that exist to the players that should exist.
public struct ReconcilePlan: Equatable, Sendable {
    public var create: [String]
    public var update: [String]
    public var destroy: [String]

    public var isEmpty: Bool { create.isEmpty && update.isEmpty && destroy.isEmpty }
}

public enum Reconciler {
    /// - Parameters:
    ///   - current: screen key -> wallpaper currently playing.
    ///   - desired: screen key -> wallpaper that should play (connected screens only).
    public static func plan(current: [String: UUID], desired: [String: UUID]) -> ReconcilePlan {
        let create = desired.keys.filter { current[$0] == nil }.sorted()
        let destroy = current.keys.filter { desired[$0] == nil }.sorted()
        let update = desired.keys.filter { key in
            guard let now = current[key] else { return false }
            return now != desired[key]
        }.sorted()
        return ReconcilePlan(create: create, update: update, destroy: destroy)
    }
}
