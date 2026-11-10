import Foundation

/// 游戏设置定义表（launchers/shared/game_settings.v1.json，Mac 启动设置页与 iOS 游戏内菜单共用）里 Mac 有的那些项。
/// 文案、类型、取值都从表里读，界面不另存一份；读不到 / 格式不对抛错（不猜）。
public struct GameSettingItem: Equatable, Identifiable {
    public struct Option: Equatable { public let value: String; public let label: [String: String] }
    public let id: String
    /// bool / choice / patches / page
    public let type: String
    /// display / controls / other
    public let group: String
    public let label: [String: String]
    public let note: [String: String]
    public let options: [Option]

    public func text(_ language: String) -> String { label[language] ?? label["zh-Hans"] ?? id }
    public func detail(_ language: String) -> String { note[language] ?? note["zh-Hans"] ?? "" }
}

public enum GameSettingsSpec {
    public static func url() throws -> URL {
        guard let url = try BackendText.resourceBundle().url(forResource: "game_settings.v1", withExtension: "json") else {
            throw BackendText.ResourceError(message: "Game settings table is missing")
        }
        return url
    }

    /// 表里 platforms 含 mac 的项，按表里的顺序
    public static func macItems(_ data: Data? = nil) throws -> [GameSettingItem] {
        let raw = try data ?? Data(contentsOf: url())
        guard let spec = try JSONSerialization.jsonObject(with: raw) as? [String: Any], spec["contract"] as? String == "s2a.game-settings.v1",
              let items = spec["items"] as? [[String: Any]] else { throw BackendText.ResourceError(message: "Game settings table is invalid") }
        return try items.filter { ($0["platforms"] as? [String] ?? []).contains("mac") }.map { item in
            guard let id = item["id"] as? String, let type = item["type"] as? String, let label = item["label"] as? [String: String] else {
                throw BackendText.ResourceError(message: "Game settings item is invalid")
            }
            let options = try (item["options"] as? [[String: Any]] ?? []).map { o -> GameSettingItem.Option in
                guard let v = o["value"] as? String, let l = o["label"] as? [String: String] else { throw BackendText.ResourceError(message: "Game settings option is invalid") }
                return .init(value: v, label: l)
            }
            return GameSettingItem(id: id, type: type, group: item["group"] as? String ?? "other", label: label,
                                   note: item["note"] as? [String: String] ?? [:], options: options)
        }
    }
}
