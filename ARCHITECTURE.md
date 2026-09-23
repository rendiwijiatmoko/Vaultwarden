# Architecture

The project is organized by responsibility so the SwiftUI client does not couple presentation code to encryption or API payloads.

## Source layout

```text
vaultwardenApp/
├── App/
│   ├── VaultwardenApp.swift
│   └── ContentView.swift
├── Core/
│   ├── DesignSystem/
│   ├── Models/
│   ├── Networking/
│   ├── Security/
│   ├── Sync/
│   └── Store/
├── Features/
│   ├── Generator/
│   ├── Onboarding/
│   ├── Send/
│   ├── Settings/
│   └── Vault/
└── Resources/
    └── Assets.xcassets

VaultAutoFillExtension/
```

## Dependency direction

- `App` composes the application and injects shared dependencies.
- `Features` contain SwiftUI screens and feature-specific presentation logic.
- `Core` contains domain models, state, security utilities, networking contracts, and reusable UI primitives.
- Feature code may depend on `Core`; `Core` must not depend on a feature.
- The AutoFill extension is a separate target. Its minimal credential index is encrypted in the shared App Group and published after sync and every local CRUD projection.

## Security boundaries

- API responses remain encrypted until the crypto layer validates and decrypts them.
- Master passwords are never persisted as plain text.
- Session tokens and locally wrapped keys belong in ThisDeviceOnly Keychain items.
- Decrypted vault records belong in an encrypted local store with explicit lock-time memory cleanup.
- AutoFill receives only the minimum credential data required for the selected request.

## Synchronization model

- CRUD is optimistic: the UI and AutoFill index update first, while a prepared field-encrypted API request is persisted in a second AES-GCM, device-only envelope.
- `VaultSyncEngine` serializes replay, coalesces repeated local writes, applies exponential backoff with jitter, and keeps local projections over stale offline snapshots.
- Cipher HTTP 409/412 responses trigger a raw `/sync` revision lookup. The encrypted request body is rebased by replacing only `lastKnownRevisionDate`, then retried without exposing or re-encrypting secrets.
- Prepared requests carry stable idempotency/request IDs across retries and token refresh.
- `BGAppRefreshTask` can refresh the encrypted `/sync` cache and replay already-prepared requests after first device unlock; it never asks for or unwraps the biometric-protected vault key.
- A normal unlocked sync decrypts the newest cache/server payload and republishes AutoFill/passkey identities.

## Verification boundary

- Unit tests cover cryptographic known answers, encrypted archive integrity, queue coalescing, CRUD projections, AutoFill domain matching, passkey record selection, and timeout mapping.
- Integration tests must exercise authentication, sync payload compatibility, conflicts, and CRUD against a dedicated non-production server.
- System UI tests must exercise AutoFill/password creation/passkey registration on physical devices because AuthenticationServices owns those presentation and authorization flows.
- Release gates for licensing, privacy ownership, trademark use, and encryption export classification live outside the runtime architecture and are tracked in the repository release checklist.

## Native macOS integration

- A single multiplatform app target compiles SwiftUI with AppKit on macOS and UIKit on iOS. Mac Catalyst is disabled. Per-platform Info.plist and entitlements preserve the iOS extension and add a sandboxed native Mac credential provider.
- `PlatformUI` contains presentation adapters; platform APIs remain conditional at integration boundaries. The vault model, synchronization engine, networking, and cryptographic implementation are shared.
- Mac commands route through the same pending-action router as iOS Home Screen quick actions. The Mac uses a native sidebar and three-column selection; Settings has its own scene.
- Mac keychain queries use the data-protection keychain. The vault key retains user-presence access control; the Mac login password replaces the iOS device passcode as the fallback.
- macOS refresh is an app-lifetime task, not an iOS background task. Application/session lifecycle handling applies timeouts and removes sensitive views when the vault locks.
- The pinned Swift SDK's iOS artifact lacks macOS support. `Scripts/prepare-macos-sdk.sh` verifies source/archive checksums and builds the corresponding native Rust library into an ignored local Swift package before Xcode runs. No binary is downloaded or built by a project build phase.
