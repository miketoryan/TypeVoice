import Darwin
import Foundation
import ObjectiveC.runtime
import UIKit

/// Side-loaded cold-start return helper.
///
/// Two-stage strategy:
/// 1) Ask FrontBoard to foreground the original keyboard host.
/// 2) If TypeVoice is still foreground shortly after, suspend TypeVoice itself
///    so iOS can reveal the previous foreground scene instead of leaving the
///    user stranded in the containing app.
///
/// All private symbols are resolved at runtime.
enum PreviousAppReturner {
    @discardableResult
    static func open(bundleID: String) -> Bool {
        let target = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isUsable(target) else {
            return false
        }

        if openWithFrontBoard(bundleID: target) {
            return true
        }

        return openWithLaunchServices(bundleID: target)
    }

    static func suspendCurrentAppIfStillForeground() {
        guard UIApplication.shared.applicationState == .active else {
            return
        }

        let selector = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: selector) else {
            return
        }

        UIApplication.shared.perform(selector)
    }

    private static func openWithFrontBoard(bundleID: String) -> Bool {
        let frameworkPath =
            "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices"

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return false
        }
        defer { dlclose(handle) }

        guard let serviceClass = NSClassFromString("FBSSystemService") else {
            return false
        }

        let sharedSelector = NSSelectorFromString("sharedService")
        let classObject: AnyObject = serviceClass

        guard classObject.responds(to: sharedSelector),
              let service = classObject
                .perform(sharedSelector)?
                .takeUnretainedValue() as? NSObject
        else {
            return false
        }

        let openSelector = NSSelectorFromString(
            "openApplication:options:withResult:"
        )

        guard service.responds(to: openSelector) else {
            return false
        }

        typealias ResultBlock = @convention(block) (AnyObject?) -> Void
        typealias OpenApplicationIMP = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            NSDictionary,
            ResultBlock
        ) -> Void

        let implementation = service.method(for: openSelector)
        let function = unsafeBitCast(
            implementation,
            to: OpenApplicationIMP.self
        )

        let completion: ResultBlock = { _ in }
        function(
            service,
            openSelector,
            bundleID as NSString,
            NSDictionary(),
            completion
        )

        return true
    }

    private static func openWithLaunchServices(bundleID: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            return false
        }

        let defaultWorkspace = NSSelectorFromString("defaultWorkspace")
        let classObject: AnyObject = workspaceClass

        guard classObject.responds(to: defaultWorkspace),
              let workspace = classObject
                .perform(defaultWorkspace)?
                .takeUnretainedValue() as? NSObject
        else {
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector) else {
            return false
        }

        typealias OpenApplicationIMP = @convention(c) (
            AnyObject,
            Selector,
            NSString
        ) -> Bool

        let implementation = workspace.method(for: openSelector)
        let function = unsafeBitCast(
            implementation,
            to: OpenApplicationIMP.self
        )

        return function(workspace, openSelector, bundleID as NSString)
    }

    private static func isUsable(_ bundleID: String) -> Bool {
        !bundleID.isEmpty
            && bundleID.contains(".")
            && bundleID != "<null>"
            && bundleID != "(null)"
            && bundleID != Bundle.main.bundleIdentifier
    }
}
