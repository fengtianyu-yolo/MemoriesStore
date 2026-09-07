import Foundation
import Combine

enum ViewerDisplayStyle: String, CaseIterable, Identifiable {
    case border
    case watermark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .border: return "边框模式"
        case .watermark: return "水印杂志"
        }
    }

    var subtitle: String {
        switch self {
        case .border: return "模糊背景 + 悬浮主图 + 下方元数据"
        case .watermark: return "浅色画布 + 图上艺术字文案"
        }
    }
}

@MainActor
final class ViewerPreferences: ObservableObject {
    @Published var style: ViewerDisplayStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.key) }
    }

    private static let key = "ms.viewerDisplayStyle"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let s = ViewerDisplayStyle(rawValue: raw) {
            style = s
        } else {
            style = .border
        }
    }
}
