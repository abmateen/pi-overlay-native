import AppKit
import UserNotifications

// ---------------------------------------------------------------------------
// Pi Overlay notifier
//
// Posts the "prompt finished" notification for the overlay and reports a click
// back to it.
//
// It exists because a process that was not launched by LaunchServices as an
// app bundle (the overlay is spawned by the pi extension) is not allowed to use
// UserNotifications at all. This helper is a real .app, so macOS accepts its
// authorisation request.
//
//   --post            post a notification, then quit
//   --title / --body  notification text
//   --profile / --tab which overlay profile/tab finished (echoed back on click)
//   --click           skip the notification and deliver the click directly
//                     (used to test the overlay side end to end)
//
// When the user clicks the notification, macOS launches this helper and hands
// it the response; the helper then broadcasts
// com.abmateen.pi-overlay.notification-click, which the overlay listens for.
// ---------------------------------------------------------------------------

let clickNotification = NSNotification.Name("com.abmateen.pi-overlay.notification-click")
let logPath = "/tmp/pi_overlay_notifier.log"

func nlog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

let arguments = ProcessInfo.processInfo.arguments

func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func deliverClick(profile: String, tab: String) {
    DistributedNotificationCenter.default().postNotificationName(
        clickNotification,
        object: nil,
        userInfo: ["profile": profile, "tab": tab],
        deliverImmediately: true
    )
    nlog("click delivered profile='\(profile)' tab='\(tab)'")
}

final class NotifierApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        if arguments.contains("--click") {
            deliverClick(profile: argument("--profile") ?? "", tab: argument("--tab") ?? "")
            exit(0)
        }

        // Launched by a notification click: the response is delivered right
        // after launch, so wait for it instead of posting something new.
        guard arguments.contains("--post") else {
            nlog("launched without --post; waiting for a notification response")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
            return
        }

        // Do not linger if the user never answers the permission prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                nlog("authorization denied: \(String(describing: error))")
                exit(0)
            }

            let content = UNMutableNotificationContent()
            content.title = argument("--title") ?? "pi"
            content.body = argument("--body") ?? "Turn finished"
            content.sound = .default
            content.userInfo = [
                "profile": argument("--profile") ?? "",
                "tab": argument("--tab") ?? "",
            ]

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    nlog("post failed: \(error)")
                } else {
                    nlog("posted '\(content.title)' — \(content.body)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        deliverClick(
            profile: info["profile"] as? String ?? "",
            tab: info["tab"] as? String ?? ""
        )
        completionHandler()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}

let app = NSApplication.shared
let notifier = NotifierApp()
app.delegate = notifier
app.setActivationPolicy(.accessory)
app.run()
