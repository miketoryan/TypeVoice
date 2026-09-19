import Foundation
import ObjectiveC.runtime

/// Side-loaded cold-start return helper.
///
/// This intentionally resolves LaunchServices at runtime instead of linking
/// private headers. It is only used after TypeVoice was opened from its keyboard.
enum PreviousAppReturner {
    @discardableResult
    static func open(bundleID: String) -> Bool {
        let target = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !target.isEmpty,
              target.contains("."),
              target != Bundle.main.bundleIdentifier
        else {
            return false
        }

        guard let workspaceClass: AnyObject = NSClassFromString("LSApplicationWorkspace") else {
            return false
        }

        let defaultWorkspace = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultWorkspace),
              let workspace = workspaceClass
                .perform(defaultWorkspace)?
                .takeUnretainedValue() as? NSObject
        else {
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector) else {
            return false
        }

        return workspace.perform(openSelector, with: target) != nil
    }
}
