import KeyboardHostBundleID
import UIKit

/// Unified host resolver.
///
/// iOS 26.4+ uses KeyboardHostBundleID's keyboard-arbiter hook. Older iOS
/// versions fall back inside that package to the legacy PKService/XPC path.
enum HostApplicationResolver {
    static func resolve(from controller: UIInputViewController) -> String? {
        KeyboardHost.resolve(from: controller)
    }

    static var lastCaptured: String? {
        KeyboardHost.lastCapturedHostBundleId
    }

    static func invalidate() {
        KeyboardHost.invalidateCache()
    }
}
