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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = AppModel.shared, model.requiresDeferredTermination else {
                return .terminateNow
            }

            if model.captureState == .recording || model.captureState == .paused {
                let alert = NSAlert()
                alert.messageText = "Stop recording and quit?"
                alert.informativeText = model.hasActiveTranscription
                    ? "Call Recorder will secure this recording and finish the active transcription before it quits."
                    : "Call Recorder will secure the audio captured so far before it quits."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Stop & Quit")
                alert.addButton(withTitle: "Keep App Open")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return .terminateCancel
                }
            } else if model.hasActiveTranscription {
                let alert = NSAlert()
                alert.messageText = "Finish transcription and quit?"
                alert.informativeText = "To avoid uploading this recording again, " +
                    "Call Recorder will quit after the active transcription finishes."
                alert.addButton(withTitle: "Finish & Quit")
                alert.addButton(withTitle: "Keep App Open")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return .terminateCancel
                }
            }

            model.prepareForTermination {
                DispatchQueue.main.async {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
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

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520)
                .frame(minHeight: 620)
        }
    }
}
