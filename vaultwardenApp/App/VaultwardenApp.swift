//
//  vaultwardenAppApp.swift
//  vaultwardenApp
//
//  Created by Rendi  on 09/08/26.
//

import SwiftUI

@main
struct VaultwardenApp: App {
    @StateObject private var store: AppStore

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        BackgroundSyncManager.register {
            await store.performBackgroundRefresh()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
