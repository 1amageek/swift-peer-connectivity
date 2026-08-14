#!/usr/bin/env bash
set -euo pipefail

snapshot="swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a"
expected_commit="ef761e567dc94ee"
toolchain_identifier="org.swift.64202607231a"
download_root="https://download.swift.org/swift-6.4.x-branch"
temporary_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
temporary_directory="$(mktemp -d "$temporary_parent/swift-toolchain.XXXXXX")"

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

verify_compiler() {
  local swift_binary="$1"
  local version
  version="$("$swift_binary" --version)"
  if [[ "$version" != *"Swift $expected_commit"* ]]; then
    echo "Unexpected Swift compiler. Required commit: $expected_commit" >&2
    echo "$version" >&2
    exit 1
  fi
  echo "$version"
}

append_github_path() {
  local directory="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$directory" >> "$GITHUB_PATH"
  fi
}

install_macos_toolchain() {
  local toolchain_root="$HOME/Library/Developer/Toolchains/$snapshot.xctoolchain"
  if [[ ! -x "$toolchain_root/usr/bin/swift" ]]; then
    local package_path="$temporary_directory/$snapshot-osx.pkg"
    local package_url="$download_root/xcode/$snapshot/$snapshot-osx.pkg"
    curl --fail --location --show-error "$package_url" --output "$package_path"

    local signature
    signature="$(pkgutil --check-signature "$package_path")"
    if [[ "$signature" != *"Developer ID Installer: Swift Open Source (V9AUD2URP3)"* ]]; then
      echo "Swift toolchain package signature verification failed." >&2
      echo "$signature" >&2
      exit 1
    fi

    installer -pkg "$package_path" -target CurrentUserHomeDirectory
  fi

  local toolchain_linker="$toolchain_root/usr/bin/ld"
  if [[ ! -x "$toolchain_linker" ]]; then
    local xcode_linker
    xcode_linker="$(xcrun --toolchain XcodeDefault --find ld)"
    if [[ ! -x "$xcode_linker" ]]; then
      echo "The active Xcode toolchain does not provide an executable linker: $xcode_linker" >&2
      exit 1
    fi
    if [[ -L "$toolchain_linker" ]]; then
      unlink "$toolchain_linker"
    elif [[ -e "$toolchain_linker" ]]; then
      echo "The Swift toolchain linker path exists but is not executable: $toolchain_linker" >&2
      exit 1
    fi
    ln -s "$xcode_linker" "$toolchain_linker"
  fi

  local swift_binary
  swift_binary="$(xcrun --toolchain "$toolchain_identifier" --find swift)"
  verify_compiler "$swift_binary"
  append_github_path "${swift_binary%/swift}"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'TOOLCHAINS=%s\n' "$toolchain_identifier" >> "$GITHUB_ENV"
  fi
}

case "$(uname -s)" in
  Darwin)
    install_macos_toolchain
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac
