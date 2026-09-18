# Vaultwarden for iOS

A native SwiftUI client for connecting to a user-selected, self-hosted Vaultwarden server.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or supported by Bitwarden, Inc. or the Vaultwarden project. The app is under active development and is not yet recommended for production use.

## Highlights

- Native SwiftUI interface for iPhone and iPad
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
- iOS or iPadOS 26.2 or newer
- An Apple development team for code signing
- A self-hosted Vaultwarden server available over HTTPS

## Getting started

1. Clone the repository:

   ```sh
   git clone https://github.com/rendiwijiatmoko/iOS-Vaultwarden.git
   cd iOS-Vaultwarden
   ```

2. Open `vaultwardenApp.xcodeproj` in Xcode.
3. Replace the existing development team and bundle identifiers with your own values.
4. Configure matching App Group and Keychain Sharing identifiers for both the main app and `VaultAutoFillExtension`.
5. Select the `vaultwardenApp` scheme and an iOS device, then build and run.
6. Enter the HTTPS URL of your Vaultwarden server during onboarding.

The app and AutoFill extension must use the same App Group and shared Keychain access group. AutoFill and passkey flows should be tested on a physical device because their presentation is controlled by iOS.

## Testing

Run the shared scheme's test action in Xcode, or use:

```sh
xcodebuild -project vaultwardenApp.xcodeproj \
  -scheme vaultwardenApp \
  -destination 'platform=iOS,id=DEVICE_ID' \
  test
```

Automated tests cover cryptographic known answers, encrypted archive integrity, mutation queue behavior, CRUD projections, AutoFill domain matching, passkey selection, and lock timeout mapping.

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

This project currently pins [Bitwarden SDK for Swift](https://github.com/bitwarden/sdk-swift) at revision `3dbc27249f48fcb88c56739ece52e2335701de0b`. That package references a prebuilt `BitwardenFFI` artifact. Its exact distribution terms and corresponding source must be verified before distributing compiled builds of this application.

Vaultwarden server software is not bundled with this repository. Users provide and control their own server.

## License

The original source code in this repository is licensed under the [GNU General Public License v3.0 only](LICENSE), identified as `GPL-3.0-only`.

Third-party components remain subject to their respective licenses. The GPL license for this repository does not grant permission to use Bitwarden trademarks, logos, or branding.
