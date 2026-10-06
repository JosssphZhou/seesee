import Foundation

/// 待播清单的两种看法：列表视图（左侧栏加播放器）和看板视图（按状态分列）。
/// 记在偏好设置里，下次打开还是上次用的那种。
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list
    case board

    static let defaultsKey = "libraryViewMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表视图"
        case .board: return "看板视图"
        }
    }

    /// 和 ⌘ 一起按的数字键，沿用 Finder 切换视图的约定。
    var shortcutKey: Character {
        switch self {
        case .list: return "1"
        case .board: return "2"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> LibraryViewMode {
        defaults.string(forKey: defaultsKey).flatMap(LibraryViewMode.init(rawValue:)) ?? .list
    }

    static func store(_ mode: LibraryViewMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}

/// 看板右侧播放器面板的宽度：可拖动，记在偏好设置里。
enum BoardPlayerPanelMetrics {
    static let widthDefaultsKey = "boardPlayerPanelWidth"
    static let defaultWidth: Double = 660
    static let minimumWidth: Double = 420
    /// 面板拉宽时左边至少留一列卡片（247）加看板的左右内边距。
    static let minimumBoardWidth: Double = 300

    static func clampedWidth(_ width: Double, windowWidth: Double) -> Double {
        let maximum = max(minimumWidth, windowWidth - minimumBoardWidth)
        guard width.isFinite else { return min(defaultWidth, maximum) }
        return min(max(width, minimumWidth), maximum)
    }
}

/// 设置里「显示「已归档」列」的开关：看板要不要显示第五列。关着时归档条目只在列表视图的「已看完」分组里。
/// 设置页的文字在 `DigestSettingsCopy.archivedColumnLabel`。
enum BoardArchivedColumnSetting {
    static let defaultsKey = "boardShowsArchivedColumn"
}
