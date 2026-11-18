import AppKit
import os
import Sync

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "push")

/// Receives CloudKit's pushes and starts a check for each one.
@MainActor
final class PushReceiver: NSObject, NSApplicationDelegate {
    private let sync: SyncService

    init(sync: SyncService) {
        self.sync = sync
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken _: Data) {
        log.notice("registered for pushes")
    }

    func application(_: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        log.error("cannot register for pushes: \(String(describing: error), privacy: .public)")
    }

    func application(_: NSApplication, didReceiveRemoteNotification _: [String: Any]) {
        sync.pushArrived()
    }
}
