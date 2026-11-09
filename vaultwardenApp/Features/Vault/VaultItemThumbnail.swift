import SwiftUI

/// Whether rows show website icons, and which server provides them. Set once at
/// the root so rows don't each observe the whole store.
struct VaultIconContext: Equatable {
    var showsWebsiteIcons = true
    var serverURL: URL?
}

private struct VaultIconContextKey: EnvironmentKey {
    static let defaultValue = VaultIconContext()
}

extension EnvironmentValues {
    var vaultIconContext: VaultIconContext {
        get { self[VaultIconContextKey.self] }
        set { self[VaultIconContextKey.self] = newValue }
    }
}

/// An item's tile, as Passwords draws it: the website's icon on a white rounded
/// square, the name's first letter on a tint when the site has no icon, or the
/// item type's symbol. The frame never changes when an icon arrives.
struct VaultItemThumbnail: View {
    let item: VaultItem
    private let explicitContext: VaultIconContext?
    var size: CGFloat

    @Environment(\.vaultIconContext) private var environmentContext
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loaded: LoadedIcon?

    private struct LoadedIcon {
        let request: WebsiteIconRequest
        let image: WebsiteIconImage?
    }

    init(item: VaultItem, showsWebsiteIcon: Bool, serverURL: URL?, size: CGFloat = 40) {
        self.item = item
        explicitContext = VaultIconContext(showsWebsiteIcons: showsWebsiteIcon, serverURL: serverURL)
        self.size = size
    }

    init(item: VaultItem, size: CGFloat = 40) {
        self.item = item
        explicitContext = nil
        self.size = size
    }

    private var context: VaultIconContext { explicitContext ?? environmentContext }
    private var cornerRadius: CGFloat { size * 0.225 }

    var body: some View {
        let request = iconRequest
        let icon = displayedIcon(for: request)

        ZStack {
            VaultTileFace(item: item, side: size, hosts: websiteHosts)
            if let icon {
                WebsiteIconTile(image: icon, side: size, displayScale: displayScale)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            // Keeps white icons from dissolving into a white page.
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1 / max(displayScale, 1))
        }
        .animation(reduceMotion ? nil : VaultMotion.fade, value: icon != nil)
        .task(id: request) { await load(request) }
        .accessibilityHidden(true)
    }

    private var websiteHosts: WebsiteIconHostLookup.Hosts? {
        guard item.type == .login else { return nil }
        return item.websiteURIs.lazy.compactMap(WebsiteIconHostLookup.hosts(for:)).first
    }

    private var iconRequest: WebsiteIconRequest? {
        guard context.showsWebsiteIcons, item.type == .login,
              let serverURL = context.serverURL,
              let hosts = websiteHosts else { return nil }
        return WebsiteIconRequest(
            host: hosts.icon,
            storageHost: hosts.storage,
            serverURL: serverURL,
            pixelSize: Self.pixelSize(points: size, scale: displayScale)
        )
    }

    private func displayedIcon(for request: WebsiteIconRequest?) -> WebsiteIconImage? {
        guard let request else { return nil }
        if let loaded, loaded.request == request { return loaded.image }
        return WebsiteIconMemoryCache.image(for: request)
    }

    private func load(_ request: WebsiteIconRequest?) async {
        guard let request, WebsiteIconMemoryCache.image(for: request) == nil else { return }
        let image = await WebsiteIconRepository.shared.icon(for: request)
        guard !Task.isCancelled else { return }
        loaded = LoadedIcon(request: request, image: image)
    }

    static func pixelSize(points: CGFloat, scale: CGFloat) -> Int {
        Int((points * max(scale, 1)).rounded(.up))
    }

    /// Starts icons for the first rows of a list as it appears. Rows further
    /// down load their own when they scroll into view.
    static func prefetch(_ items: some Sequence<VaultItem>, context: VaultIconContext, points: CGFloat, scale: CGFloat) {
        guard context.showsWebsiteIcons, let serverURL = context.serverURL else { return }
        let pixels = pixelSize(points: points, scale: scale)
        let requests = items.compactMap { item -> WebsiteIconRequest? in
            guard item.type == .login else { return nil }
            return item.websiteURIs.lazy
                .compactMap { WebsiteIconHostLookup.request(for: $0, serverURL: serverURL, pixelSize: pixels) }
                .first
        }
        WebsiteIconRepository.shared.prefetch(requests)
    }
}

/// The tile underneath an icon: a letter on a tint for websites, a symbol otherwise.
private struct VaultTileFace: View {
    let item: VaultItem
    let side: CGFloat
    let hosts: WebsiteIconHostLookup.Hosts?

    var body: some View {
        let letter = item.type == .login
            ? VaultMonogram.letter(name: item.name, host: hosts?.icon)
            : nil
        ZStack {
            Rectangle().fill(tint(hasLetter: letter != nil).gradient)
            if let letter {
                Text(letter)
                    .font(.system(size: side * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: item.type.icon)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: side * 0.5, height: side * 0.5)
            }
        }
    }

    private func tint(hasLetter: Bool) -> Color {
        if hasLetter {
            return VaultMonogram.tint(for: VaultMonogram.tintSeed(name: item.name, host: hosts?.icon))
        }
        return switch item.type {
        case .login: .blue
        case .secureNote: .brown
        case .card: .cyan.mix(with: .black, by: 0.2)
        case .identity: .teal.mix(with: .black, by: 0.2)
        case .sshKey: .indigo
        }
    }
}

private struct WebsiteIconTile: View {
    let image: WebsiteIconImage
    let side: CGFloat
    let displayScale: CGFloat

    var body: some View {
        if image.fillsTile {
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: side, height: side)
                // Logos with transparent gaps (Microsoft's) must not show the letter tile through them.
                .background(Color.white)
        } else {
            // A small favicon is drawn at no more than twice its own size, so it stays sharp.
            let natural = CGFloat(image.cgImage.width) / max(displayScale, 1)
            let inner = min(side * 0.72, max(natural * 2, side * 0.42))
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: inner, height: inner)
                .frame(width: side, height: side)
                .background(Color.white)
        }
    }
}
