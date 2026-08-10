# Vaultwarden App for iOS

Native SwiftUI client for a user-selected, self-hosted Vaultwarden server.

## Structure

- `vaultwardenApp/App`: app entry point and lifecycle composition.
- `vaultwardenApp/Core`: models, API/crypto boundaries, encrypted persistence, sync, AutoFill, and passkey support.
- `vaultwardenApp/Features`: Vault, Generator, Send, Settings, and onboarding screens.
- `vaultwardenApp/Resources`: assets and localized resources.
- `VaultAutoFillExtension`: native Credential Provider Extension.
- `vaultwardenAppTests`: deterministic security and data-flow tests.

See `ARCHITECTURE.md` for dependency and security boundaries. Release/legal gates are tracked in `../APP_STORE_RELEASE_CHECKLIST.md` and `../THIRD_PARTY_NOTICES.md`.

## Run

1. Open `vaultwardenApp.xcodeproj` in Xcode 26.2 or newer.
2. Select the `vaultwardenApp` scheme and an iOS 26.2 device.
3. Configure the same App Group and shared Keychain access group for the app and extension.
4. Configure a development team, build, and sign in to an HTTPS Vaultwarden server.

## Implemented

- Vaultwarden login, Bitwarden SDK crypto initialization, encrypted sync, and device-only offline cache.
- Optimistic CRUD with an encrypted offline mutation queue, retry, revision conflict rebase, and background refresh.
- Login, secure note, card, identity, SSH key, folder, collection, trash, TOTP, and custom-field UI.
- Native AutoFill for passwords and verification codes, credential search, password creation, and save-password flows.
- Passkey registration and assertion through the Credential Provider Extension.
- Encrypted text/file Sends, password protection, sharing, download, and attachment decryption.
- Biometric/device authentication, automatic timed lock, and master-password recovery.
- Password-protected AES-256-GCM vault archives for personal non-passkey items.
- English/Indonesian localization foundation and privacy manifests for both executables.

## Test

Run the shared scheme's test action in Xcode, or:

```sh
xcodebuild -project vaultwardenApp.xcodeproj -scheme vaultwardenApp \
  -destination 'platform=iOS,id=DEVICE_ID' test
```

Automated tests cover PBKDF2, encrypted archive authentication/tamper handling, CRUD projection reduction, encrypted queue coalescing, AutoFill domain matching, passkey selection, and timeout values. The manual production matrix is in `../APP_STORE_RELEASE_CHECKLIST.md`.

## Release status

The app is not ready for public distribution until the pinned Bitwarden SDK/FFI license, trademark use, privacy-policy owner/contact details, and encryption export classification are resolved. Do not remove these release gates without documented review.
