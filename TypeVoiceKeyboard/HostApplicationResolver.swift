import Darwin
import Foundation
import ObjectiveC.runtime
import UIKit

/// Best-effort resolver for the app that currently hosts this keyboard.
///
/// iOS 26.4 removed the older _hostBundleID path used by many keyboard
/// frameworks. For this AltServer build we also try the host process XPC
/// connection, which is the same family of technique used by older
/// "boomerang" keyboard implementations.
enum HostApplicationResolver {
    static func resolve(from controller: UIInputViewController) -> String? {
        if let parent = controller.parent {
            if let direct = value(forPrivateKey: "_hostBundleID", on: parent) as? String,
               isUsableBundleID(direct) {
                return direct
            }
        }

        return resolveThroughHostConnection(from: controller)
    }

    private static func resolveThroughHostConnection(
        from controller: UIInputViewController
    ) -> String? {
        guard let parent = controller.parent,
              let pid = value(forPrivateKey: "_hostPID", on: parent)
        else {
            return nil
        }

        let defaultService = NSSelectorFromString("defaultService")
        guard let serviceClass: AnyObject = NSClassFromString("PKService"),
              serviceClass.responds(to: defaultService),
              let service = serviceClass.perform(defaultService)?.takeUnretainedValue() as? NSObject
        else {
            return nil
        }

        let personalitiesSelector = NSSelectorFromString("personalities")
        guard service.responds(to: personalitiesSelector),
              let personalities = service.perform(personalitiesSelector)?.takeUnretainedValue() as? NSDictionary,
              let keyboardBundleID = Bundle.main.bundleIdentifier,
              let bundleInfo = personalities.object(forKey: keyboardBundleID) as? NSDictionary,
              let info = bundleInfo.object(forKey: pid) as? NSObject
        else {
            return nil
        }

        let connectionSelector = NSSelectorFromString("connection")
        guard info.responds(to: connectionSelector),
              let connection = info.perform(connectionSelector)?.takeUnretainedValue() as? NSObject
        else {
            return nil
        }

        let xpcSelector = NSSelectorFromString("_xpcConnection")
        guard connection.responds(to: xpcSelector),
              let xpcConnection = connection.perform(xpcSelector)?.takeUnretainedValue()
        else {
            return nil
        }

        guard let handle = dlopen("/usr/lib/libc.dylib", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "xpc_connection_copy_bundle_id") else {
            return nil
        }

        typealias CopyBundleID = @convention(c) (AnyObject) -> UnsafeMutablePointer<CChar>?
        let copyBundleID = unsafeBitCast(symbol, to: CopyBundleID.self)

        guard let cString = copyBundleID(xpcConnection as AnyObject) else {
            return nil
        }
        defer { free(cString) }

        let bundleID = String(cString: cString)
        return isUsableBundleID(bundleID) ? bundleID : nil
    }

    private static func value(
        forPrivateKey key: String,
        on object: NSObject
    ) -> Any? {
        guard hasPrivateMember(named: key, on: object) else {
            return nil
        }
        return object.value(forKey: key)
    }

    private static func hasPrivateMember(
        named name: String,
        on object: NSObject
    ) -> Bool {
        var currentClass: AnyClass? = object_getClass(object)

        while let cls = currentClass {
            if class_getInstanceVariable(cls, name) != nil {
                return true
            }

            let selector = NSSelectorFromString(name)
            if class_respondsToSelector(cls, selector) {
                return true
            }

            currentClass = class_getSuperclass(cls)
        }

        return false
    }

    private static func isUsableBundleID(_ value: String) -> Bool {
        let bundleID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty,
              bundleID != "<null>",
              bundleID != Bundle.main.bundleIdentifier
        else {
            return false
        }
        return bundleID.contains(".")
    }
}
