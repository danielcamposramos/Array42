#!/bin/sh -e
# Build and package Array42 release binaries for Linux, macOS, and Windows.
#
# Produces, under zig-out/release/:
#   array42-linux-x86_64.tar.gz
#   array42-macos-x86_64.tar.gz
#   array42-macos-arm64.tar.gz
#   array42-windows-x86_64.zip
#
# Each archive contains the MCP server (array42-mcp) and the RPN core demo
# (array42), with a .exe suffix on Windows. Cross-compilation uses cgm-zig's
# bundled libc (glibc, mingw, and the macOS SDK), so no per-OS toolchain is
# needed beyond a single Linux host.

cd "$(dirname "$0")"

VERSION=0.1.0
OPT=ReleaseSafe

rm -rf zig-out/release
mkdir -p zig-out/release

# build <zig-target> <os> <arch>
build() {
    target=$1; os=$2; arch=$3
    prefix="zig-out/release/${os}-${arch}"
    echo "==> building ${os}-${arch} (${target})"
    zig build -Dtarget="$target" -Doptimize="$OPT" --prefix "$prefix"
    if [ "$os" = "linux" ]; then
        strip "$prefix/bin/array42" "$prefix/bin/array42-mcp"
    fi
}

build x86_64-linux-gnu linux x86_64
build x86_64-windows-gnu windows x86_64
build x86_64-macos macos x86_64
build aarch64-macos macos arm64

# package <os> <arch>
package() {
    os=$1; arch=$2
    src="zig-out/release/${os}-${arch}/bin"
    stage="zig-out/release/array42-${os}-${arch}"
    rm -rf "$stage"
    mkdir -p "$stage"
    if [ "$os" = "windows" ]; then
        cp "$src/array42.exe" "$stage/array42.exe"
        cp "$src/array42-mcp.exe" "$stage/array42-mcp.exe"
    else
        cp "$src/array42" "$stage/array42"
        cp "$src/array42-mcp" "$stage/array42-mcp"
    fi
    cp README.md "$stage/README.md"
    if [ "$os" = "windows" ]; then
        (cd zig-out/release && zip -qr "array42-${os}-${arch}.zip" "array42-${os}-${arch}")
    else
        tar -C zig-out/release -czf "zig-out/release/array42-${os}-${arch}.tar.gz" "array42-${os}-${arch}"
    fi
    rm -rf "$stage"
}

package linux x86_64
package macos x86_64
package macos arm64
package windows x86_64

echo "==> done. artifacts:"
ls -la zig-out/release/*.tar.gz zig-out/release/*.zip
