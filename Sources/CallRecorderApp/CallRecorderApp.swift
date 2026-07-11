import AppKit
import CallRecorderCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared?.stopImmediatelyForTermination()
        }
    }

    @objc private func workspaceWillSleep() {
        Task { @MainActor in
            AppModel.shared?.handleSystemSleep()
        }
    }
}

@main
struct CallRecorderApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabelView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("Recordings", id: "recordings") {
            HistoryView()
                .environmentObject(model)
        }
        .defaultSize(width: 720, height: 440)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520)
                .frame(minHeight: 620)
        }
        .defaultSize(width: 560, height: 660)
        .windowResizability(.contentSize)
    }
}
