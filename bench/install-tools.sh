#!/bin/bash
# Installs the benchmark's third-party mutation-testing tools at pinned versions into a prefix (never system-wide),
# each archive checked against a pinned SHA-256, and prints the environment bench/run.py reads.
#
#   bench/install-tools.sh [PREFIX [TOOLS]] default PREFIX: bench/.tools; TOOLS: comma-separated smt,muter,mutest
#   eval "$(bench/install-tools.sh)"       then: python3 bench/run.py
#
# Litmus itself is not installed here: build it (swift build -c release) and set LITMUS_BIN, or put it on PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${1:-$here/.tools}"
tools=",${2:-smt,muter,mutest},"
wants() { [[ "$tools" == *",$1,"* ]]; }
mkdir -p "$prefix/bin" "$prefix/src"

fetch() { # url sha256 file
    local url="$1" sha="$2" file="$prefix/src/$3"
    if [ ! -f "$file" ] || ! printf '%s  %s\n' "$sha" "$file" | shasum -a 256 -c - > /dev/null 2>&1; then
        curl -fsSL "$url" -o "$file.partial"
        mv "$file.partial" "$file"
    fi
    printf '%s  %s\n' "$sha" "$file" | shasum -a 256 -c - > /dev/null || {
        echo "install-tools: SHA-256 mismatch for $url" >&2
        exit 1
    }
}

# ericodx/swift-mutation-testing: a prebuilt arm64 executable.
smt_version=1.7.1
smt_sha=5799deec1cfc2f99a40e0cefde6285a5671f780b1de65439ed4eec2585f493e7
if wants smt && [ ! -x "$prefix/smt-$smt_version/swift-mutation-testing" ]; then
    fetch "https://github.com/ericodx/swift-mutation-testing/releases/download/v$smt_version/swift-mutation-testing-v$smt_version-macos.tar.gz" \
        "$smt_sha" "smt-$smt_version.tar.gz"
    mkdir -p "$prefix/smt-$smt_version"
    tar -xzf "$prefix/src/smt-$smt_version.tar.gz" -C "$prefix/smt-$smt_version"
fi

# Muter: a prebuilt universal executable.
muter_version=17
muter_sha=77d8fd147fadb25d838e8673cfc78747bf6f17c1b73727197b77c20e3ab54210
if wants muter && [ ! -x "$prefix/muter-$muter_version/muter" ]; then
    fetch "https://github.com/muter-mutation-testing/muter/releases/download/$muter_version/muter-$muter_version-macos-universal.tar.gz" \
        "$muter_sha" "muter-$muter_version.tar.gz"
    mkdir -p "$prefix/muter-$muter_version"
    tar -xzf "$prefix/src/muter-$muter_version.tar.gz" -C "$prefix/muter-$muter_version"
fi

# j-khn/mutest-swift: a source archive, built here (its executable is also named swift-mutation-testing).
mutest_version=0.3.5
mutest_sha=0a6f4447497879aa619331e8fd5b08bd2dbac3c69296d06fd37d05d3786a6223
mutest_dir="$prefix/mutest-swift-v$mutest_version"
if wants mutest && [ ! -x "$mutest_dir/.build/release/swift-mutation-testing" ]; then
    fetch "https://github.com/j-khn/mutest-swift/releases/download/v$mutest_version/mutest-swift-v$mutest_version.tar.gz" \
        "$mutest_sha" "mutest-$mutest_version.tar.gz"
    tar -xzf "$prefix/src/mutest-$mutest_version.tar.gz" -C "$prefix"
    swift build -c release --package-path "$mutest_dir" --product swift-mutation-testing >&2
fi

if wants smt; then echo "export SMT_BIN='$prefix/smt-$smt_version/swift-mutation-testing'"; fi
if wants muter; then echo "export MUTER_BIN='$prefix/muter-$muter_version/muter'"; fi
if wants mutest; then echo "export MUTEST_BIN='$mutest_dir/.build/release/swift-mutation-testing'"; fi
