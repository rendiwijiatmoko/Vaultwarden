# Local Bitwarden SDK

Run `./Scripts/prepare-macos-sdk.sh` from the repository root before opening the
Xcode project. Install Xcode and Rust using rustup first. The script downloads
checksum-verified, pinned SDK sources and the official iOS binary, builds native
macOS libraries, and creates the ignored `BitwardenSdk` Swift package used by both
app targets. Preparation may take several minutes and needs internet access.

The default build contains Apple Silicon and Intel Mac slices plus the original
iOS device and simulator slices. For a faster Apple Silicon development build:

```sh
MACOS_ARCHS=arm64 ./Scripts/prepare-macos-sdk.sh
```

Use the default universal build before distributing a Mac release. Rust 1.92.0
is the default compiler; `BITWARDEN_RUST_TOOLCHAIN` can select an already installed
toolchain. `BITWARDEN_SDK_CACHE` changes the download/build cache location from
`.build/bitwarden-sdk`. Keep cached sources unmodified; delete that cache to
recreate it from verified upstream archives.

The exact source revisions, compiler, and license texts are recorded inside the
generated package. Sources come from Bitwarden's SDK repositories. The original
release only contains iOS binaries, so a native macOS slice is built from the
matching Rust source. This does not use Mac Catalyst. No SDK build is performed
by an Xcode build phase.
