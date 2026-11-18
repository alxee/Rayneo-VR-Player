// main.swift — RayNeo Cinema app bootstrap (AppKit, unbundled-friendly).

import AppKit
import AVFoundation
import Metal
import RayNeoCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let alert = NSAlert()
            alert.messageText = "Rayneo VR Player"
            alert.informativeText = "No Metal device available on this Mac."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let controller = PlayerController(metalDevice: device)
        self.controller = controller
        controller.makeUI()
        installMenus(controller: controller)

        // A file passed on the command line (or `open … -a`) starts playback.
        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1]
            let url = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            if let url {
                controller.load(url: url)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle opening a video file at launch — both fresh launch
        // (Apple event) and file dropped on an already-running instance.
        for url in urls where url.isFileURL {
            controller?.load(url: url)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        controller?.load(url: URL(fileURLWithPath: filename))
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the panel in SBS.
        controller?.exitVR()
    }

    private func installMenus(controller: PlayerController) {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Rayneo VR Player", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Rayneo VR Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openFile(_:)), keyEquivalent: "o").target = self

        // View/VR menu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "VR")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Enter / Exit VR Mode (F)", action: #selector(AppDelegate.toggleVR(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: "Cycle Video Mode (C)", action: #selector(AppDelegate.cycleMode(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: "Mirror Eyes (M)", action: #selector(AppDelegate.toggleMirror(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: "Head Tracking (T)", action: #selector(AppDelegate.toggleTracking(_:)), keyEquivalent: "").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Recenter View (R)", action: #selector(AppDelegate.recenter(_:)), keyEquivalent: "").target = self

        NSApp.mainMenu = main
    }

    @objc func openFile(_ sender: Any) { controller?.openPanel() }
    @objc func toggleVR(_ sender: Any) { controller?.toggleVR() }
    @objc func cycleMode(_ sender: Any) { controller?.cycleMode() }
    @objc func toggleMirror(_ sender: Any) { controller?.toggleMirror() }
    @objc func toggleTracking(_ sender: Any) { controller?.toggleTracking() }
    @objc func recenter(_ sender: Any) { controller?.recenter() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
