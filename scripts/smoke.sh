#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${LITMUS_BIN:-$ROOT/.build/debug/litmus}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/litmus-smoke.XXXXXX")"
cleanup() {
  STATUS=$?
  if [[ "$STATUS" == 0 ]]; then rm -rf "$WORK"; else printf 'Smoke failed; evidence retained at %s\n' "$WORK" >&2; fi
}
trap cleanup EXIT
cp -R "$ROOT/Tests/Fixtures/Example" "$WORK/subject"
BEFORE="$(shasum -a 256 "$WORK/subject/Sources/Example/Decisions.swift")"
"$BIN" plan "$WORK/subject" --output "$WORK/plan.json"
"$BIN" run "$WORK/subject" --trust-project --output "$WORK/run" --timeout 120 > "$WORK/stdout.json"
AFTER="$(shasum -a 256 "$WORK/subject/Sources/Example/Decisions.swift")"
[[ "$BEFORE" == "$AFTER" ]]
python3 - "$WORK/run/run.json" <<'PY'
import json,sys,collections
r=json.load(open(sys.argv[1]))
assert r['complete']
c=collections.Counter(x['verdict'] for x in r['results'])
assert c == {'killed':2, 'survived':1}, c
print('real execution:', dict(c))
PY
set +e
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.pb" --format json --strict > "$WORK/report.json"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]]
python3 - "$WORK/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['successfulExecution'] and r['schemaVersion']==1 and r['tool']=='litmus'
assert len(r['findings'])==1 and r['findings'][0]['rule']=='litmus/survived'
PY
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.json" --format sarif > "$WORK/report.sarif"
python3 - "$WORK/report.sarif" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r['version']=='2.1.0'
assert r['runs'][0]['invocations'][0]['executionSuccessful']
PY
printf '\n// changed after execution\n' >> "$WORK/subject/Tests/ExampleTests/DecisionsTests.swift"
set +e
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.json" --format json > "$WORK/stale.json"
STATUS=$?
set -e
[[ "$STATUS" == 70 ]]
python3 - "$WORK/stale.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert not r['successfulExecution'] and r['degradedFiles']
PY
if [[ -n "${LITMUS_EVIDENCE_DIR:-}" ]]; then
  [[ ! -e "$LITMUS_EVIDENCE_DIR" ]]
  mkdir -p "$LITMUS_EVIDENCE_DIR/run"
  cp "$WORK/plan.json" "$WORK/report.json" "$WORK/report.sarif" "$WORK/stale.json" "$LITMUS_EVIDENCE_DIR/"
  cp "$WORK/run/"*.json "$WORK/run/"*.pb "$WORK/run/"*.xml "$WORK/run/"*.log "$LITMUS_EVIDENCE_DIR/run/"
fi
printf 'Smoke passed: real kills/survivor, original-source preservation, JSON/protobuf/SARIF, strict gate, stale-test refusal.\n'
