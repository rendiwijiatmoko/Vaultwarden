# Vaultwarden for iOS and macOS

A native SwiftUI client for connecting to a user-selected, self-hosted Vaultwarden server.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or supported by Bitwarden, Inc. or the Vaultwarden project. The app is under active development and is not yet recommended for production use.

## Highlights

- Native SwiftUI interface for iPhone, iPad, and Mac (AppKit, not Mac Catalyst)
- Mac sidebar, three-column vault, keyboard navigation, menu commands, and Settings window
- Login and encrypted synchronization with a self-hosted Vaultwarden server
- Login, secure note, card, identity, SSH key, folder, collection, and custom-field support
- Create, edit, trash, restore, and permanently delete vault items
- Native password and verification-code AutoFill extension
- Passkey registration and authentication through AuthenticationServices
- Text and file Sends with password, expiration, and deletion options
- Password and username generators with local history
- Biometric or device authentication and configurable automatic locking
- Encrypted, device-only offline cache and mutation queue
- Password-protected AES-256-GCM vault exports
- English and Indonesian localization
- No analytics, advertising SDKs, or tracking domains

## Requirements

- macOS with Xcode 26.2 or newer
- macOS 26.2 or newer to run the native Mac app
- Rust via rustup to prepare the pinned native Bitwarden SDK
- iOS or iPadOS 26.2 or newer
- An Apple development team for code signing
- A self-hosted Vaultwarden server available over HTTPS

## Getting started

1. Clone the repository:

   ```sh
   git clone https://github.com/rendiwijiatmoko/iOS-Vaultwarden.git
   cd iOS-Vaultwarden
   ```

2. Prepare the SDK before opening Xcode. The pinned upstream artifact has only iOS slices; this builds matching native macOS slices and keeps the original iOS slices:

   ```sh
   ./Scripts/prepare-macos-sdk.sh
   ```

   The default contains Apple Silicon and Intel. For a faster Apple Silicon development build, use `MACOS_ARCHS=arm64 ./Scripts/prepare-macos-sdk.sh`. Downloaded sources and generated binaries are ignored by Git. See [Packages/README.md](Packages/README.md) for checksums, source pins, and compiler details.

3. Open `vaultwardenApp.xcodeproj` in Xcode.
4. Replace the existing development team and bundle identifiers with your own values.
5. Configure matching App Group and Keychain Sharing identifiers for both the main app and `VaultAutoFillExtension`.
6. Select the `vaultwardenApp` scheme and **My Mac** for the native macOS app, or an iOS device for iOS, then build and run.
7. Enter the HTTPS URL of your Vaultwarden server during onboarding.

The app and AutoFill extension must use the same App Group and shared Keychain access group. AutoFill and passkey flows require signed builds with matching provisioning on each platform. Validate them on a Mac and an iOS device because AuthenticationServices controls their presentation. The Mac entitlements are in `Config/macOS` and `VaultAutoFillExtension/VaultAutoFillExtension-macOS.entitlements`.

## Native Mac behavior

- The resizable vault window has a native sidebar, item list, and detail column. Arrow keys navigate items; Command/Shift selection supports bulk actions.
- **⌘N** creates a password, **⌘F** focuses search, **⌘R** syncs, **⇧⌘L** locks, and **⌘,** opens Settings.
- Touch ID or the Mac login password protects device authentication. Vault keys and tokens use the macOS data-protection Keychain, with matching sharing groups for AutoFill.
- Copying a secret clears that clipboard item after 30 seconds without deleting a newer copy. Copied secrets are marked concealed for clipboard managers.
- QR setup imports an image through a native file picker and decodes it locally. iOS retains camera scanning.
- Encrypted exports use a Save dialog; Send supports native file selection. The Mac sandbox allows outbound networking and user-selected files.
- Background refresh runs while the app is running and stops when it quits. Sleep, screen lock, and user-session switching lock the vault; switching apps follows the selected vault timeout.
- macOS AutoFill supports passwords, passkeys, and verification codes. Apple's iOS-only system password-save/generation callbacks are omitted on Mac; manual creation and the in-app generator remain available.

## Testing

Build and test on the current Mac:

```sh
xcodebuild -project vaultwardenApp.xcodeproj \
  -scheme vaultwardenApp \
  -destination 'platform=macOS' \
  test
```

Run the shared scheme's test action in Xcode, or use:

```sh
xcodebuild -project vaultwardenApp.xcodeproj \
  -scheme vaultwardenApp \
  -destination 'platform=iOS,id=DEVICE_ID' \
  test
```

Signing is required for Keychain-backed tests and for a usable account/AutoFill installation on macOS. An unsigned build can verify compilation and the SDK tests, but the mutation-queue test returns Keychain error `-34018` without the required entitlement. Add the development account in Xcode Settings → Accounts and enable automatic signing for both targets before running the full suite.

Automated tests cover native SDK PBKDF2/Argon2 known answers, vault-key unwrap and wrong-password rejection, cipher round trips, OTP imports, encrypted archive integrity, mutation queue behavior, CRUD projections, AutoFill domain matching, passkey selection, and lock timeout mapping.

## Project structure

```text
vaultwardenApp/
├── App/                 Application entry point and composition
├── Core/                Models, networking, security, sync, and storage
├── Features/            Vault, Generator, Send, Settings, and onboarding
└── Resources/           Assets and localized strings
VaultAutoFillExtension/  Credential Provider extension
vaultwardenAppTests/     Security and data-flow tests
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the dependency direction, security boundaries, and synchronization model.

## Security notes

- Master passwords are not persisted as plain text.
- Session tokens and locally wrapped keys are stored in device-only Keychain items.
- Cached vault data and queued mutations are encrypted at rest.
- Decrypted vault records are cleared from application memory when the vault locks.
- AutoFill receives a minimal encrypted credential index through the shared App Group.

Security-sensitive software deserves independent review. Do not rely on this project as your only copy of important credentials, and test it against a dedicated non-production server before using real data.

## Current status

The core client experience is implemented, but public binary distribution remains blocked pending final review of:

- Bitwarden SDK and FFI binary licensing and corresponding-source obligations
- Product naming and trademark usage
- Privacy-policy ownership and contact information
- Encryption export classification
- Production signing, provisioning, and physical-device validation

Issues and pull requests are welcome, especially for reproducible bugs, interoperability fixes, accessibility, localization, and security improvements. Please do not include real credentials, vault exports, server logs containing tokens, or other sensitive data in reports.

## Dependency notice

The preparation script pins [Bitwarden SDK for Swift](https://github.com/bitwarden/sdk-swift) at revision `3dbc27249f48fcb88c56739ece52e2335701de0b`. The local package combines its prebuilt iOS `BitwardenFFI` artifact with macOS libraries built from Rust SDK revision `10ba9cbb21cb201988b7e54e68df13678ebcaa5f`. Its exact distribution terms and corresponding source must be verified before distributing compiled builds of this application.

Vaultwarden server software is not bundled with this repository. Users provide and control their own server.

## License

The original source code in this repository is licensed under the [GNU General Public License v3.0 only](LICENSE), identified as `GPL-3.0-only`.

Third-party components remain subject to their respective licenses. The GPL license for this repository does not grant permission to use Bitwarden trademarks, logos, or branding.
