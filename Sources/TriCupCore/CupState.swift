import Foundation

/// The three working states of TriCup, ordered by how much sleep is prevented.
public enum CupState: Int, CaseIterable, Sendable {
    /// Allow system, display and lid-close sleep (default).
    case empty = 0
    /// Keep the system and display awake; lid-close sleep is still allowed.
    case half = 1
    /// Keep the system running even when the lid is closed.
    case full = 2

    /// Next state when cycling with a left click: empty -> half -> full -> empty.
    public var next: CupState {
        switch self {
        case .empty: return .half
        case .half: return .full
        case .full: return .empty
        }
    }

    public var title: String {
        switch self {
        case .empty: return "Sleep"
        case .half: return "Awake"
        case .full: return "Always Awake"
        }
    }

    public var detail: String {
        switch self {
        case .empty: return "允许系统、显示器与合盖休眠"
        case .half: return "系统与显示器保持唤醒，允许合盖休眠"
        case .full: return "系统持续运行，合盖也不休眠"
        }
    }
}
