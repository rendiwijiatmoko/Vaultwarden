#!/bin/bash
# Build a native macOS slice for the exact Bitwarden SDK used by this app.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="${BITWARDEN_SDK_CACHE:-$repo_dir/.build/bitwarden-sdk}"
rust_toolchain="${BITWARDEN_RUST_TOOLCHAIN:-1.92.0}"
macos_archs="${MACOS_ARCHS:-arm64 x86_64}"
macos_deployment_target="26.2"
swift_revision="3dbc27249f48fcb88c56739ece52e2335701de0b"
rust_revision="10ba9cbb21cb201988b7e54e68df13678ebcaa5f"
swift_checksum="6ca566d53015633fbecde753b1a281ee93cb23e66a2bd099ea9c5f0c2f3dac6d"
rust_checksum="b5a7bc7164f26987668b99d1b6dbea34b5d5fc48207ec677444c5c1944218960"
binary_checksum="75974923073dc12f6edccfd86af825dd0cf7077b7a1f71575a9e531b132fd24d"
binary_url="https://github.com/bitwarden/sdk-swift/releases/download/v3.0.0-7302-10ba9cb/BitwardenFFI-3.0.0-10ba9cb.xcframework.zip"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Run this script on macOS with Xcode and Rust (rustup) installed." >&2
    exit 1
fi
for command in curl shasum tar ditto python3 rustup xcrun xcodebuild; do
    command -v "$command" >/dev/null || { echo "Missing required tool: $command" >&2; exit 1; }
done
xcrun --sdk macosx --show-sdk-path >/dev/null
mkdir -p "$cache_dir" "$repo_dir/Packages"
cache_dir="$(cd "$cache_dir" && pwd)"

download_verified() {
    local url="$1" destination="$2" expected="$3"
    if [[ ! -f "$destination" ]]; then
        curl --fail --location --retry 3 "$url" -o "$destination.download"
        mv "$destination.download" "$destination"
    fi
    local actual
    actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Checksum mismatch for $destination. Remove it and rerun." >&2
        exit 1
    fi
}

extract_verified_source() {
    local archive="$1" destination="$2" checksum="$3"
    if [[ ! -f "$destination/.vaultwarden-source-sha256" ]] ||
       [[ "$(cat "$destination/.vaultwarden-source-sha256")" != "$checksum" ]]; then
        # Only replace the revision-specific directory owned by this script.
        rm -rf "$destination"
        mkdir -p "$destination"
        tar -xzf "$archive" --strip-components=1 -C "$destination"
        printf '%s\n' "$checksum" > "$destination/.vaultwarden-source-sha256"
    fi
}

download_verified "https://codeload.github.com/bitwarden/sdk-swift/tar.gz/$swift_revision" \
    "$cache_dir/sdk-swift.tar.gz" "$swift_checksum"
download_verified "https://codeload.github.com/bitwarden/sdk-internal/tar.gz/$rust_revision" \
    "$cache_dir/sdk-internal.tar.gz" "$rust_checksum"
download_verified "$binary_url" "$cache_dir/BitwardenFFI.xcframework.zip" "$binary_checksum"
swift_source="$cache_dir/sdk-swift-$swift_revision"
rust_source="$cache_dir/sdk-internal-$rust_revision"
extract_verified_source "$cache_dir/sdk-swift.tar.gz" "$swift_source" "$swift_checksum"
extract_verified_source "$cache_dir/sdk-internal.tar.gz" "$rust_source" "$rust_checksum"
rust_source="$(cd "$rust_source" && pwd -P)"

if ! rustup run "$rust_toolchain" rustc --version >/dev/null 2>&1; then
    rustup toolchain install "$rust_toolchain" --profile minimal
fi
libraries=()
architectures=()
seen_architectures=" "
for architecture in $macos_archs; do
    case "$architecture" in
        arm64) target="aarch64-apple-darwin" ;;
        x86_64) target="x86_64-apple-darwin" ;;
        *) echo "Unsupported MACOS_ARCHS entry: $architecture" >&2; exit 1 ;;
    esac
    if [[ "$seen_architectures" == *" $architecture "* ]]; then
        echo "Duplicate MACOS_ARCHS entry: $architecture" >&2
        exit 1
    fi
    rustup target add --toolchain "$rust_toolchain" "$target"
    (
        cd "$rust_source"
        MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" CARGO_TARGET_DIR="$rust_source/target" \
            rustup run "$rust_toolchain" cargo build --release --locked \
            -p bitwarden-uniffi --target "$target"
    )
    libraries+=("$rust_source/target/$target/release/libbitwarden_uniffi.a")
    architectures+=("$architecture")
    seen_architectures+="$architecture "
done
if [[ ${#libraries[@]} -eq 0 ]]; then
    echo "MACOS_ARCHS must contain arm64, x86_64, or both." >&2
    exit 1
fi

stage="$(mktemp -d "$repo_dir/Packages/.BitwardenSdk.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R "$swift_source/Sources" "$stage/Sources"
ditto -x -k "$cache_dir/BitwardenFFI.xcframework.zip" "$stage"
framework="$stage/BitwardenFFI.xcframework"
slice="macos-$(IFS=_; echo "${architectures[*]}")"
mkdir -p "$framework/$slice"
cp -R "$framework/ios-arm64/Headers" "$framework/$slice/Headers"
if [[ ${#libraries[@]} -eq 1 ]]; then
    cp "${libraries[0]}" "$framework/$slice/libbitwarden_uniffi.a"
else
    xcrun lipo -create "${libraries[@]}" -output "$framework/$slice/libbitwarden_uniffi.a"
fi
python3 - "$framework/Info.plist" "$slice" "${architectures[@]}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = plistlib.loads(path.read_bytes())
data["AvailableLibraries"].append({
    "BinaryPath": "libbitwarden_uniffi.a",
    "HeadersPath": "Headers",
    "LibraryIdentifier": sys.argv[2],
    "LibraryPath": "libbitwarden_uniffi.a",
    "SupportedArchitectures": sys.argv[3:],
    "SupportedPlatform": "macos",
})
path.write_bytes(plistlib.dumps(data))
PY
cat > "$stage/Package.swift" <<'SWIFT'
// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "BitwardenSdk",
    platforms: [.iOS(.v13), .macOS("26.2")],
    products: [.library(name: "BitwardenSdk", targets: ["BitwardenSdk", "BitwardenFFI"])],
    targets: [
        .target(
            name: "BitwardenSdk",
            dependencies: ["BitwardenFFI", "BitwardenSdkSupport"],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
                .linkedLibrary("resolv", .when(platforms: [.macOS])),
            ]),
        .target(name: "BitwardenSdkSupport"),
        .binaryTarget(name: "BitwardenFFI", path: "BitwardenFFI.xcframework"),
    ]
)
SWIFT
mkdir -p "$stage/Licenses"
cp "$rust_source/LICENSE" "$rust_source/LICENSE_GPL.txt" "$rust_source/LICENSE_SDK.txt" "$stage/Licenses/"
cat > "$stage/README.md" <<EOF
# Prepared Bitwarden SDK

Generated by Scripts/prepare-macos-sdk.sh. Do not edit or commit this directory.

- Swift wrapper: https://github.com/bitwarden/sdk-swift/commit/$swift_revision
- Rust source: https://github.com/bitwarden/sdk-internal/commit/$rust_revision
- Official iOS artifact: $binary_url
- iOS artifact SHA-256: $binary_checksum
- macOS architectures: ${architectures[*]}
- macOS minimum deployment target: $macos_deployment_target
- Compiler: $(rustup run "$rust_toolchain" rustc --version)

The Swift wrapper and iOS device/simulator slices are from the pinned upstream
release. Only the native macOS static library is built locally, from its matching
Rust revision using Cargo.lock. Its UniFFI headers are identical to those in the
upstream artifact. No SDK build or download runs inside Xcode.

Upstream licensing notices and both license texts are included in Licenses/.
The SDK source is generally GPL-3.0-only OR LicenseRef-Bitwarden-SDK; files under
bitwarden_license are under the Bitwarden SDK license only, as described by the
included upstream LICENSE. Preserve these notices when redistributing the SDK.
EOF
# Replace only after the complete staged package has been produced successfully.
rm -rf "$repo_dir/Packages/BitwardenSdk"
mv "$stage" "$repo_dir/Packages/BitwardenSdk"
echo "Prepared Packages/BitwardenSdk for macOS (${architectures[*]}) and iOS."
