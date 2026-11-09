import Foundation
import ImageIO

/// 联网获取封面（设备端懒抓）：清单里没有横版封面（banner）的游戏，按标题 ID 联网抓一次官方横版主视觉，
/// 存本机 Documents/FetchedCovers/<标题ID>.jpg，下次直接用缓存。抓取链与 GameCase 的 LCFetchedCover 落地版
/// 逐项对齐（该链已在 GC 真机验通，三款标题 ID 均取到 1920×1080）：
///
/// - 接入：ec.nintendo.com/apps/<标题ID>/US → 商品页 HTML → __NEXT_DATA__ 的 schema.org linkedData.image
///   （assets.nintendo.com），结构漂移时退回整页正则找同形状的 image URL；
/// - 门槛：host 必须是 assets.nintendo.com、图宽 ≥1280 且宽 > 高（只读图头像素尺寸判定，不整图解码）；
/// - 纪律：同一款在飞只发一发；失败（页无图 / 图不达标 / 网络错）记负缓存，7 天内不重试；
///   全程静默——失败不弹窗、不打扰，界面退回图标占位；抓取在后台，不阻塞库加载。

// MARK: - 存储（Documents/FetchedCovers/<标题ID>.jpg）

enum FetchedCoverStore {
    static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FetchedCovers", isDirectory: true)
    }

    static func fileURL(for titleID: String) -> URL {
        directoryURL.appendingPathComponent("\(titleID).jpg")
    }

    static func cachedData(for titleID: String) -> Data? {
        try? Data(contentsOf: fileURL(for: titleID))
    }

    static func save(_ data: Data, for titleID: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: titleID), options: .atomic)
    }
}

// MARK: - 抓取服务（去重 + 负缓存 + 静默）

/// 回调的 Sendable 盒：抓取完成回调只在后台线程被调用恰好一次（见 ensureFetched 契约），
/// 调用方负责自行回主线程；装盒只为过 Swift 6 的 sending 捕获检查，不改线程语义。
private struct SendableCoverCallback: @unchecked Sendable {
    let body: (Data) -> Void
    init(_ body: @escaping (Data) -> Void) { self.body = body }
}

/// 内部可变状态（inFlight）由 NSLock 守护，故 @unchecked Sendable。
final class CoverFetchService: @unchecked Sendable {
    static let shared = CoverFetchService()

    /// 负缓存重试间隔：7 天
    private static let negativeCacheInterval: TimeInterval = 7 * 24 * 3600
    /// 验收门槛：只收横版宽图（宽 ≥1280 且宽 > 高），小图 / 方图一律当失败
    private static let minimumLandscapeWidth: CGFloat = 1280
    /// 与商品页实测一致的 UA（桌面 / 移动 UA 返回同一页面）
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let lock = NSLock()
    private var inFlight: Set<String> = []

    private init() {}

    // MARK: 负缓存（UserDefaults 记每款上次尝试时刻）

    private static func attemptDefaultsKey(for titleID: String) -> String { "S2AFetchedCover.lastAttempt.\(titleID)" }

    private func negativeCacheIsFresh(for titleID: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.attemptDefaultsKey(for: titleID))
        guard last > 0 else { return false }
        return Date().timeIntervalSince1970 - last < Self.negativeCacheInterval
    }

    private func recordNegativeAttempt(for titleID: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.attemptDefaultsKey(for: titleID))
    }

    // MARK: 入口

    /// 去重抓取入口：负缓存新鲜 / 已在飞时直接返回；成功落盘后在后台线程回调一次（调用方自行回主线程）。
    func ensureFetched(titleID: String, onFetched: @escaping (Data) -> Void) {
        if negativeCacheIsFresh(for: titleID) { return }
        // Swift 6：NSLock.lock()/unlock() 在 async 上下文不可用，统一用 withLock
        let alreadyFlying = lock.withLock {
            if inFlight.contains(titleID) { return true }
            inFlight.insert(titleID)
            return false
        }
        guard !alreadyFlying else { return }

        // Swift 6 并发检查：Task.detached 的闭包是 sending 语义，不能直接捕获非 @Sendable 的
        // onFetched 参数（42582041076 实测报错）。回调契约本就是「后台线程恰好回一次、调用方
        // 自行回主线程」，故先装进 @unchecked Sendable 盒再捕获，语义不变。
        let callback = SendableCoverCallback(onFetched)
        Task.detached(priority: .utility) { [self] in
            let data = await fetchStoreCoverData(titleID: titleID)
            lock.withLock { inFlight.remove(titleID) }
            guard let data else { recordNegativeAttempt(for: titleID); return }
            FetchedCoverStore.save(data, for: titleID)
            callback.body(data)
        }
    }

    // MARK: 抓取实现（任天堂官方链）

    /// ec.nintendo.com/apps/<标题ID>/US → 商品页 HTML → linkedData.image → 图字节。
    /// 任一步失败 / 图不达标都返回 nil（由调用方记负缓存），全程静默。
    private func fetchStoreCoverData(titleID: String) async -> Data? {
        guard let pageURL = URL(string: "https://ec.nintendo.com/apps/\(titleID)/US") else { return nil }
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        pageRequest.timeoutInterval = 30
        guard let (pageData, pageResponse) = try? await URLSession.shared.data(for: pageRequest),
              (pageResponse as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: pageData, encoding: .utf8),
              let imageURL = Self.extractStoreImageURL(fromHTML: html) else { return nil }

        var imageRequest = URLRequest(url: imageURL)
        imageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        imageRequest.timeoutInterval = 30
        guard let (imageData, imageResponse) = try? await URLSession.shared.data(for: imageRequest),
              (imageResponse as? HTTPURLResponse)?.statusCode == 200,
              let pixelSize = Self.imagePixelSize(data: imageData),
              pixelSize.width >= Self.minimumLandscapeWidth, pixelSize.width > pixelSize.height else { return nil }
        return imageData
    }

    /// 商品页主图提取：首选 __NEXT_DATA__ JSON 里的 schema.org linkedData（image 字段，实测即官方主视觉）；
    /// 结构漂移时退回正则在整页里找 store/software/switch/<nsuid>/ 路径的 image 值。
    private static func extractStoreImageURL(fromHTML html: String) -> URL? {
        if let open = html.range(of: "id=\"__NEXT_DATA__\""),
           let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
           let close = html.range(of: "</script>", range: tagEnd.upperBound..<html.endIndex) {
            let jsonText = html[tagEnd.upperBound..<close.lowerBound]
            if let data = jsonText.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let props = root["props"] as? [String: Any],
               let pageProps = props["pageProps"] as? [String: Any],
               let linkedData = pageProps["linkedData"] as? [Any] {
                for entry in linkedData {
                    guard let dict = entry as? [String: Any],
                          let image = dict["image"] as? String,
                          let url = URL(string: image),
                          url.host == "assets.nintendo.com" else { continue }
                    return url
                }
            }
        }
        let pattern = "\"image\"\\s*:\\s*\"(https://assets\\.nintendo\\.com/image/upload/[^\"]*/store/software/switch/[0-9]+/[^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return URL(string: String(html[range]))
        }
        return nil
    }

    /// 只读像素尺寸（不整图解码）
    private static func imagePixelSize(data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }
}
