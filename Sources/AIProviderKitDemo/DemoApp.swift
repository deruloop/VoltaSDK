//
//  DemoApp.swift
//  AIProviderKitDemo
//
//  App di prova macOS:
//      swift run AIProviderKitDemo
//
//  Tutta la UI vive in AIProviderKitDemoUI (condivisa con la demo iOS in
//  Examples/iOSDemo). Qui c'è solo il bootstrap macOS.
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
        // Eseguita da `swift run` (nessun bundle .app): serve per far
        // comparire la finestra in primo piano.
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
