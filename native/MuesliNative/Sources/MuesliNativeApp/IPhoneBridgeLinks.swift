import Foundation

enum IPhoneBridgeLinks {
    static let iOSSyncDeepLinkURL = syncDeepLinkURL(bundleIdentifier: Bundle.main.bundleIdentifier)
    static let installURL = URL(string: "https://github.com/Muesli-HQ/muesli-ios")!

    static func syncDeepLinkURL(bundleIdentifier: String?) -> URL {
        let scheme = bundleIdentifier?.hasPrefix("com.muesli.dev") == true
            ? "mueslidev"
            : "muesli"
        return URL(string: "\(scheme)://sync?source=mac_bridge")!
    }
}
