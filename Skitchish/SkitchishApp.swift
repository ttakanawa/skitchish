//
//  SkitchishApp.swift
//  Skitchish
//
//  Created by Tomonori Takanawa on 3/20/25.
//

import AppKit

@main
enum SkitchishApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: EditorWindowController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard editor == nil else { return }
        do {
            editor = try EditorWindowController()
            editor.installMenu()
            editor.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            NSApp.presentError(error)
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Capture temporarily orders out the editor and hides the application.
        // AppKit can ask to terminate when that leaves no visible windows.
        editor?.captureService.isCapturing != true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor else { return .terminateNow }
        return editor.prepareToTerminate() ? .terminateNow : .terminateCancel
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if editor == nil {
            applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        }
        for name in filenames { editor.open(URL(fileURLWithPath: name)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editor?.showWindow(nil)
        return true
    }
}
