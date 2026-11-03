#!/bin/bash
# Real nested-package execution, including sibling inputs and repository-relative evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${LITMUS_BIN:-$ROOT/.build/debug/litmus}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/litmus-nested.XXXXXX")"
trap 'status=$?; if [ "$status" = 0 ]; then rm -rf "$WORK"; else echo "Nested smoke failed; evidence retained at $WORK" >&2; fi' EXIT
cp -R "$ROOT/Tests/Fixtures/Nested" "$WORK/subject"
BEFORE="$(shasum -a 256 "$WORK/subject/Library/Sources/Library/Value.swift" "$WORK/subject/Sibling/Sources/Sibling/Value.swift")"
"$BIN" check "$WORK/subject" --package-path Library
"$BIN" run "$WORK/subject" --package-path Library --trust-project --baseline-repetitions 1 \
  --kill-confirmation none --output "$WORK/host" > /dev/null
python3 - "$WORK/host/run.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['complete']
assert r['results'] and all(x['mutation']['path'].startswith('Library/') for x in r['results'])
assert all(x['verdict']=='killed' for x in r['results']),r['results']
assert any(x['path'].startswith('Sibling/') for x in r['provenance']['inputs'])
assert r['provenance']['driver']['packagePath']=='Library'
PY
AFTER="$(shasum -a 256 "$WORK/subject/Library/Sources/Library/Value.swift" "$WORK/subject/Sibling/Sources/Sibling/Value.swift")"
[[ "$BEFORE" == "$AFTER" ]]
# Existing output must fail before running, and retain prior evidence.
if "$BIN" run "$WORK/subject" --package-path Library --trust-project --output "$WORK/host" > "$WORK/existing.log" 2>&1; then
  echo 'Existing output unexpectedly accepted' >&2; exit 1
fi
grep -q -- '--resume' "$WORK/existing.log"
# Optional real Xcode execution (macOS or simulator); do not allocate or alter simulators here.
if [[ -n "${LITMUS_XCODE_DESTINATION:-}" ]]; then
  "$BIN" run "$WORK/subject" --package-path Library --scheme Library \
    --destination "$LITMUS_XCODE_DESTINATION" --trust-project --baseline-repetitions 1 \
    --kill-confirmation none --output "$WORK/xcode" > /dev/null
  python3 - "$WORK/xcode/run.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['complete'] and r['results']
assert all(x['verdict']=='killed' for x in r['results']),r['results']
PY
fi
printf 'Nested package smoke passed: sibling dependencies, scoped mutations, source preservation and output refusal.\n'
