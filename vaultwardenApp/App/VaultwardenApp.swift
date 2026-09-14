//
//  vaultwardenAppApp.swift
//  vaultwardenApp
//
//  Created by Rendi  on 09/08/26.
//

import SwiftUI

@main
struct VaultwardenApp: App {
    @UIApplicationDelegateAdaptor(VaultwardenApplicationDelegate.self) private var applicationDelegate
    @StateObject private var store: AppStore
    @StateObject private var quickActions: HomeQuickActionRouter

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _quickActions = StateObject(wrappedValue: .shared)
        BackgroundSyncManager.register {
            await store.performBackgroundRefresh()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environmentObject(quickActions)
        }
    }
}
