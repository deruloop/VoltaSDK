//
//  DemoApp.swift
//  VoltaSDKDemo
//
//  macOS test app:
//      swift run VoltaSDKDemo
//
//  All the UI lives in VoltaSDKDemoUI (shared with the iOS demo in
//  Examples/iOSDemo). This is only the macOS bootstrap.
//

import SwiftUI
import VoltaSDKDemoUI
#if os(macOS)
import AppKit
#endif

@main
struct VoltaSDKDemoApp: App {
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
        WindowGroup("VoltaSDK Demo") {
            DemoRootView()
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
