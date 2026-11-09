import SwiftUI
import UIKit
import UserNotifications

@main
struct FamilyPizzaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(appDelegate.model)
                if showingSplash {
                    // Cold launch only: toppings land, then it fades into the app.
                    SplashView {
                        withAnimation(.easeOut(duration: 0.6)) { showingSplash = false }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await appDelegate.model.refreshAll() }
            }
        }
    }
}

/// Owns the model, and receives the APNs token and notifications from iOS.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await model.didReceivePushToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Completion-handler forms, not the `async` ones: with the async forms iOS finishes the
    // callback on a background thread and UIKit aborts (seen on a real iPhone, 2026-11-09:
    // NSAssertionHandler in _updateSnapshotAndStateRestoration). Completion is called on the main actor.

    // A notification arrived while the app is open: show it anyway, then refresh the orders
    // (after completing, so the banner never waits on the network, e.g. off home Wi-Fi).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            completionHandler([.banner, .list, .sound])
            await model.handlePush(tapped: false)
        }
    }

    // The person tapped the notification: open the Orders tab and that order's tracker.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let orderId = response.notification.request.content.userInfo["order_id"] as? Int
        Task { @MainActor in
            model.selectedTab = .orders
            completionHandler()
            await model.handlePush(tapped: true, orderId: orderId)
        }
    }
}
