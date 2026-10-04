import ApplicationServices
import Foundation

enum AXWindowIDResolver {
    private typealias AXUIElementGetWindowFn = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let getWindow: AXUIElementGetWindowFn? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "_AXUIElementGetWindow"
        ) else {
            return nil
        }
        return unsafeBitCast(symbol, to: AXUIElementGetWindowFn.self)
    }()

    static func getWindowID(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> Bool {
        guard let getWindow else { return false }
        return getWindow(element, windowID) == .success
    }
}
