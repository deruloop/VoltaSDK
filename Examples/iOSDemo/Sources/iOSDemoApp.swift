//
//  iOSDemoApp.swift
//  iOSDemo
//
//  Demo iPhone/iPad di AIProviderKit. Tutta la UI è condivisa con la demo
//  macOS: vive nel target AIProviderKitDemoUI del package.
//
//  Su un device con Apple Intelligence il provider on-device è reale;
//  sul simulatore (o su device non idonei) la lista provider mostra il
//  motivo di indisponibilità e si può testare il fallback sulla developer key.
//

import SwiftUI
import AIProviderKitDemoUI

@main
struct iOSDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}
