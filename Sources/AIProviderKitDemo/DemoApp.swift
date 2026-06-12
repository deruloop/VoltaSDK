//
//  DemoApp.swift
//  AIProviderKitDemo
//
//  macOS test app:
//      swift run AIProviderKitDemo
//
//  All the UI lives in AIProviderKitDemoUI (shared with the iOS demo in
//  Examples/iOSDemo). This is only the macOS bootstrap.
//

import SwiftUI
import AIProviderKitDemoUI
#if os(macOS)
import AppKit
#endif

@main
struct AIProviderKitDemoApp: App {
    init() {
        #if os(macOS)
        // Run by `swift run` (no .app bundle): needed to bring the
        // window to the foreground.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("AIProviderKit Demo") {
            DemoRootView()
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
