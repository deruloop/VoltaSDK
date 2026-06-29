//
//  macOSDemoApp.swift
//  macOSDemo
//
//  macOS demo for VoltaSDK — the signed counterpart to Examples/iOSDemo.
//  All the UI is shared with the iOS demo: it lives in the package's
//  VoltaSDKDemoUI target. This file is only the macOS bootstrap.
//
//  Because it is a signed app (unlike a `swift run` executable), it can carry
//  the Private Cloud Compute entitlement and exercise PCC live on macOS 27 —
//  see the opt-in note in project.yml and the repo README.
//

import SwiftUI
import VoltaSDKDemoUI
import AppKit

@main
struct macOSDemoApp: App {
    init() {
        // Bring the window to the foreground when launched outside a full
        // app activation context.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("VoltaSDK Demo") {
            DemoRootView()
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
