import Foundation
import PetalCore

/// Pure policy lives below sync so the repository can evaluate it while holding
/// its transaction lock. No read/resolve/write gap crosses the actor boundary.
public enum SyncConflictResolver {
    public static func remoteWins(localDate: Date, localDevice: String, remoteDate: Date, remoteDevice: String) -> Bool {
        remoteDate > localDate || (remoteDate == localDate && remoteDevice > localDevice)
    }
    public static func userVisibleDifference(_ a: CardLine, _ b: CardLine) -> Bool {
        a.text != b.text || a.kind != b.kind || a.isCompleted != b.isCompleted || a.completedAt != b.completedAt
            || a.reminder != b.reminder || a.sortIndex != b.sortIndex || a.deletedAt != b.deletedAt
    }
    public static func userVisibleDifference(_ a: Card, _ b: Card) -> Bool {
        a.title != b.title || a.status != b.status || a.themeID != b.themeID
    }
}
