//
//  iOSDemoApp.swift
//  iOSDemo
//
//  iPhone/iPad demo for VoltaSDK. All the UI is shared with the macOS
//  demo: it lives in the package's VoltaSDKDemoUI target.
//
//  On a device with Apple Intelligence the on-device provider is real;
//  on the simulator (or ineligible devices) the provider list shows the
//  unavailability reason and the developer-key fallback can be tested.
//

import SwiftUI
import VoltaSDKDemoUI

@main
struct iOSDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}
