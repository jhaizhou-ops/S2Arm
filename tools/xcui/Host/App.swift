// 运行器的宿主 App：XCUITest 必须挂在一个 App 上；它自己什么都不做，点按的对象是按包名附着的别的 App（Runner/RunnerTests.swift）
import UIKit
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible(); return true
    }
}
