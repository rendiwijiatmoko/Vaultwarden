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
- Local SSH key generation with Ed25519 (default), RSA 2048, and RSA 4096, plus public key and SHA-256 fingerprint display
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
- The menu bar opens a compact panel with vault search, username/password copying, a password generator, and SSH agent controls. Incoming SSH requests open this panel for unlock and approval without opening the main vault window. If the menu bar is hidden, requests use the main window instead. Enable or hide the icon in **Settings → Appearance → Show in Menu Bar** (enabled by default). Closing the vault window keeps the app and enabled SSH agent running while the icon is enabled; use Quit Vaultwarden to exit.
- Touch ID or the Mac login password protects device authentication. Vault keys and tokens use the macOS data-protection Keychain, with matching sharing groups for AutoFill.
- Copying a secret clears that clipboard item after 30 seconds without deleting a newer copy. Copied secrets are marked concealed for clipboard managers.
- QR setup imports an image through a native file picker and decodes it locally. iOS retains camera scanning.
- Encrypted exports use a Save dialog; Send supports native file selection. The Mac sandbox allows outbound networking and user-selected files.
- Background refresh runs while the app is running and stops when it quits. Sleep, screen lock, and user-session switching lock the vault. **Settings → Security → Vault timeout** offers Immediately, 1, 5, 10, or 15 minutes, and Never. Timed options measure Mac input inactivity, including while Vaultwarden is focused; switching to Terminal does not itself lock the vault. Immediately locks when leaving the app or dismissing the menu bar panel. New macOS settings default to 5 minutes; existing saved choices are preserved.
- macOS AutoFill supports passwords, passkeys, and verification codes. Apple's iOS-only system password-save/generation callbacks are omitted on Mac; manual creation and the in-app generator remain available.

## macOS SSH agent

Open **Settings → SSH Agent**, enable the agent, and select the SSH keys that
may be used. No keys are selected by default. Copy the exact shell configuration
shown in Settings into `~/.zshrc`, then open a new terminal. This changes only
that shell's agent selection; the app does not edit your shell configuration.

Register the selected public key with GitHub, GitLab, or your SSH server, then test:

```sh
ssh-add -L
ssh -T git@github.com
```

Use SSH repository URLs such as `git@github.com:OWNER/REPO.git`. Keep the app
running. Listing keys while locked prompts for vault unlock. For signing, choose
**Approve Once** or **Always Approve**. Always Approve remembers permission for
that account, vault item, and public-key fingerprint on this Mac, including after
restarting the app. It allows all local SSH clients to use that key while the
vault is unlocked; it does not identify a specific client or destination host.
Use **Require Approval Again** in Settings → SSH Agent to revoke permission.
Deselecting a key also revokes its remembered approval. Replacing its public key
requires fresh approval. Locked vaults must still be unlocked before any use.
Requests awaiting approval expire after 60 seconds. Denial,
locking, account changes, key changes, and disabling the agent invalidate pending
authorization. Deleted, archived, and restricted keys cannot be used.

The agent supports Ed25519 and existing RSA keys from 2048 through 4096 bits,
using RSA-SHA2-256 or RSA-SHA2-512 signatures. Encrypted standalone private keys
must first be imported into the vault in a format supported by the app's SDK.
Private keys are never exported to the socket or written to temporary files.
Key management through `ssh-add`, forwarding extensions, and automatic Git signing
configuration are not implemented.

API requests include the minimum Bitwarden compatibility version required for SSH
key synchronization (`2024.12.0`). This is independent of the app's bundle version;
Vaultwarden otherwise omits SSH keys from `/sync` even when they exist on the server.

The socket lives in a private directory inside the configured App Group container
with user-only permissions. The macOS target needs its existing App Group and
sandbox entitlements plus the server network entitlement for the listener. No TCP
or UDP port is opened. A correctly signed build is required to validate App Group
access and Terminal interoperability under the actual macOS sandbox. An unsigned
unit-test build verifies protocol and signing behavior but cannot verify deployment
entitlements. If the agent cannot start, Settings shows an error and a Retry action;
another running instance, missing App Group access, or an overlong socket path can
prevent startup.

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

Automated tests cover native SDK PBKDF2/Argon2 known answers, vault-key unwrap and wrong-password rejection, cipher round trips, OTP imports, encrypted archive integrity, mutation queue behavior, CRUD projections, AutoFill domain matching and selected credential resolution, passkey selection, and lock timeout mapping.

For AutoFill request routing, validate a signed build on a physical iPhone:

- With the vault locked, tap a specific keyboard login suggestion. Authenticate and verify it fills without another login selection. Repeat with multiple accounts on the same website.
- Open the password picker without selecting a specific suggestion. Verify the list still appears and the selected login fills.
- On a website with an active passkey request (such as Facebook), open the keyboard key/password picker. Verify Passwords opens first and fills a saved username/password. Switch to Passkeys and back without another unlock; verify the switch remains available when either list is empty. Only passkeys matching the requested relying party and allowed credential IDs should appear, including when the page uses a subdomain.
- Select a passkey directly from the keyboard suggestion and verify it still follows the passkey sign-in flow. In the picker, verify New Password is available only under Passwords.
- Retry an interrupted authentication and verify the original suggestion is retained. Cancel during authentication and verify no credential is filled afterward.
- Exercise a stale suggestion whose record is absent from the shared vault. Verify the request fails instead of filling a different account.
- Repeat with an OTP suggestion; verify the selected item's current code fills. Check passkey selection still works.

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
- Locking drops the app store’s decrypted vault records and organization keys, removes vault views, and schedules removal of the in-memory account key. Results from operations started before locking are rejected when updating vault state.
- Unlocking restores vault data from the encrypted local cache after authentication. This reference cleanup does not guarantee zeroization of every sensitive byte or temporary copy in process memory.
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
