import Foundation
import ObjectiveC.runtime

/// Side-loaded return helper transplanted from VoiceKing 0.4.1.
///
/// Try the legacy LaunchServices selector first, then the newer iOS 26 selector.
/// This is only used after TypeVoice was explicitly opened by its keyboard.
enum PreviousAppReturner {
    @discardableResult
    static func open(bundleID: String) -> Bool {
        let target = bundleID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !target.isEmpty,
              target.contains("."),
              target != Bundle.main.bundleIdentifier,
              let workspaceClass = NSClassFromString(
                "LSApplicationWorkspace"
              ) as? NSObject.Type else {
            return false
        }

        let defaultWorkspaceSelector = NSSelectorFromString(
            "defaultWorkspace"
        )
        guard workspaceClass.responds(to: defaultWorkspaceSelector),
              let workspaceValue = workspaceClass.perform(
                defaultWorkspaceSelector
              ),
              let workspace = workspaceValue.takeUnretainedValue()
                as? NSObject else {
            return false
        }

        let legacySelector = NSSelectorFromString(
            "openApplicationWithBundleID:"
        )
        if workspace.responds(to: legacySelector) {
            typealias LegacyOpenApplication = @convention(c) (
                AnyObject,
                Selector,
                NSString
            ) -> Bool

            let implementation = workspace.method(
                for: legacySelector
            )
            let openApplication = unsafeBitCast(
                implementation,
                to: LegacyOpenApplication.self
            )

            if openApplication(
                workspace,
                legacySelector,
                target as NSString
            ) {
                return true
            }
        }

        let modernSelector = NSSelectorFromString(
            "openApplicationWithBundleIdentifier:configuration:completionHandler:"
        )
        guard workspace.responds(to: modernSelector) else {
            return false
        }

        typealias Completion = @convention(block) (
            Bool,
            NSError?
        ) -> Void
        typealias ModernOpenApplication = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            AnyObject?,
            Completion
        ) -> Void

        let completion: Completion = { _, _ in }

        let implementation = workspace.method(
            for: modernSelector
        )
        let openApplication = unsafeBitCast(
            implementation,
            to: ModernOpenApplication.self
        )

        openApplication(
            workspace,
            modernSelector,
            target as NSString,
            nil,
            completion
        )
        return true
    }
}
