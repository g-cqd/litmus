#!/bin/bash
# Installs the benchmark's tools from the latest release each publishes on GitHub, into a prefix (never system-wide),
# and prints the environment bench/run.py reads. A release binary is used where there is one; a tool that publishes
# only source (mutest-swift) is built from its latest release's source archive with SwiftPM, on macOS only.
#
#   bench/install-tools.sh [PREFIX [TOOLS]]   PREFIX: bench/.tools; TOOLS: comma-separated ids (default: all)
#   eval "$(bench/install-tools.sh)"          then: python3 bench/run.py
#
# A release that publishes a .sha256 next to its archive is checked against it; otherwise the archive's SHA-256 is
# recorded as downloaded. A source build resolves exactly the dependencies its Package.resolved pins.
# Build output goes to stderr: stdout is only the environment. Either way, PREFIX/versions.tsv lists tool, release tag, asset, SHA-256 and how it was
# checked. GITHUB_TOKEN, when set, authenticates the GitHub API calls (CI's rate limit).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${1:-$here/.tools}"
tools=",${2:-litmus,smt,muter,xcmutate,dlitmus,mutest},"
mkdir -p "$prefix"
versions="$prefix/versions.tsv"
printf 'tool\ttag\tasset\tsha256\tchecked\n' > "$versions"

api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 3 -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$1"
    else
        curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" "$1"
    fi
}

# install <id> <repo> <asset regex> <executable> <environment variable>
install() {
    local id="$1" repo="$2" pattern="$3" executable="$4" variable="$5"
    [[ "$tools" == *",$id,"* ]] || return 0
    local release tag url name sums
    release="$(api "https://api.github.com/repos/$repo/releases/latest")"
    read -r tag url name sums < <(
        PATTERN="$pattern" python3 -c '
import json, os, re, sys
release = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
match = next((n for n in sorted(assets) if re.fullmatch(os.environ["PATTERN"], n)), None)
sums = assets.get(f"{match}.sha256", "-") if match else "-"
print(release["tag_name"], assets.get(match, "-"), match or "-", sums)
' <<< "$release"
    )
    if [ "$url" = "-" ]; then
        echo "install-tools: $id ($repo $tag) publishes no macOS binary; skipped (nothing is built)" >&2
        printf '%s\t%s\t-\t-\tno release binary\n' "$id" "$tag" >> "$versions"
        echo "# $id: no release binary in $repo $tag"
        return 0
    fi
    local home="$prefix/$id-$tag"
    local archive="$prefix/$name"
    if [ ! -f "$archive" ]; then
        curl -fsSL --retry 3 "$url" -o "$archive.partial"
        mv "$archive.partial" "$archive"
    fi
    local digest checked
    digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    if [ "$sums" != "-" ]; then
        local expected
        expected="$(curl -fsSL --retry 3 "$sums" | tr -s ' \t' ' ' | cut -d' ' -f1)"
        if [ "$expected" != "$digest" ]; then
            echo "install-tools: $id: SHA-256 mismatch for $name (published $expected, got $digest)" >&2
            rm -f "$archive"
            exit 1
        fi
        checked="published .sha256"
    else
        checked="recorded (no published checksum)"
    fi
    if [ ! -d "$home" ]; then
        mkdir -p "$home.partial"
        tar -xzf "$archive" -C "$home.partial"
        mv "$home.partial" "$home"
    fi
    local binary
    binary="$(find "$home" -type f -name "$executable" -perm -u+x | head -1)"
    if [ -z "$binary" ]; then
        echo "install-tools: $id: no executable $executable in $name" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$tag" "$name" "$digest" "$checked" >> "$versions"
    echo "export $variable='$binary'"
}

# build <id> <repo> <product> <environment variable>: the latest release's source archive, built with
# `swift build -c release`; the executable alone is kept.
build() {
    local id="$1" repo="$2" product="$3" variable="$4"
    [[ "$tools" == *",$id,"* ]] || return 0
    local tag
    tag="$(api "https://api.github.com/repos/$repo/releases/latest" | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
    if [ "$(uname -s)" != Darwin ]; then
        echo "install-tools: $id ($repo $tag) is built from source, which needs macOS; skipped" >&2
        printf '%s\t%s\t-\t-\tneeds macOS to build\n' "$id" "$tag" >> "$versions"
        echo "# $id: needs macOS to build from source"
        return 0
    fi
    local home="$prefix/$id-$tag" name="$id-$tag-source.tar.gz"
    local archive="$prefix/$name"
    if [ ! -f "$archive" ]; then
        curl -fsSL --retry 3 "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" -o "$archive.partial"
        mv "$archive.partial" "$archive"
    fi
    local digest
    digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    if [ ! -x "$home/$product" ]; then
        local source
        source="$(mktemp -d "$prefix/.source.XXXXXX")"
        tar -xzf "$archive" -C "$source" --strip-components 1
        echo "install-tools: building $id $tag from source…" >&2
        (cd "$source" && swift build -c release --product "$product" --force-resolved-versions) >&2
        mkdir -p "$home"
        cp "$(cd "$source" && swift build -c release --show-bin-path)/$product" "$home/$product"
        rm -rf "$source"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$tag" "$name" "$digest" "built from source (archive recorded)" >> "$versions"
    echo "export $variable='$home/$product'"
}

install litmus g-cqd/litmus 'litmus-.*-macos-arm64\.tar\.gz' litmus LITMUS_BIN
install smt ericodx/swift-mutation-testing 'swift-mutation-testing-.*-macos\.tar\.gz' swift-mutation-testing SMT_BIN
install muter muter-mutation-testing/muter 'muter-.*-macos-.*\.tar\.gz' muter MUTER_BIN
install xcmutate RyoHirota68/xcmutate 'xcmutate-.*-macos-.*\.tar\.gz' xcmutate XCMUTATE_BIN
install dlitmus debugholic/litmus 'litmus-.*-macos-.*\.tar\.gz' litmus DLITMUS_BIN
# j-khn/mutest-swift publishes source only.
build mutest j-khn/mutest-swift swift-mutation-testing MUTEST_BIN
