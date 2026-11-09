import SwiftUI

/// How Vaultwarden looks and feels. On the Mac it is the General pane, which also
/// holds the menu bar item.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: AppStore
    #if os(macOS)
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    #endif

    var body: some View {
        Form {
            #if os(macOS)
            SettingsHero(
                Text("General"),
                subtitle: Text("How Vaultwarden looks, and where you can reach it."),
                systemImage: "gearshape.fill",
                tint: .gray
            )
            #else
            SettingsHero(
                Text("Appearance"),
                subtitle: Text("How Vaultwarden looks and feels."),
                systemImage: "textformat.size",
                tint: .blue
            )
            #endif

            Section {
                Picker("Appearance", selection: $store.settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(verbatim: SettingsWords.themeTitle(theme)).tag(theme)
                    }
                }
                Picker("Sort Items By", selection: $store.settings.vaultSortOrder) {
                    ForEach(VaultSortOrder.allCases) { order in
                        Text(verbatim: order.title).tag(order)
                    }
                }
            } header: {
                Text("Vault")
            } footer: {
                if store.settings.theme == .system {
                    #if os(macOS)
                    Text("Automatic follows the appearance you chose in System Settings.")
                    #else
                    Text("Automatic follows the appearance you chose in Settings.")
                    #endif
                }
            }

            Section {
                Toggle("Website Icons", isOn: $store.settings.showFavicons)
            } footer: {
                if store.settings.showFavicons {
                    Text("Icons come through your Vaultwarden server, so websites never see what’s in your vault.")
                } else {
                    Text("Vaultwarden doesn’t download website icons.")
                }
            }

            #if os(iOS)
            Section {
                Toggle("Haptics", isOn: $store.settings.haptics)
            } footer: {
                Text("A light tap confirms actions you take, like copying a password.")
            }
            #endif

            #if os(macOS)
            Section {
                SettingsDetailRow(
                    title: Text("Show in Menu Bar"),
                    detail: menuBarDetail,
                    systemImage: "menubar.rectangle",
                    tint: .blue
                ) {
                    Toggle("Show in Menu Bar", isOn: $showMenuBarExtra)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            } header: {
                Text("Menu Bar")
            }
            #endif
        }
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage(Text("Appearance"))
        #endif
    }

    #if os(macOS)
    private var menuBarDetail: Text {
        if showMenuBarExtra {
            return Text("Reach your vault from the menu bar. Close every window to hide Vaultwarden from the Dock; it keeps running until you quit.")
        }
        return Text("Open Vaultwarden from the Dock or Spotlight.")
    }
    #endif
}
