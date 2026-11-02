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
[[ -n "${LITMUS_KEEP_SMOKE:-}" ]] && trap - EXIT
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
expected = {'killed': 5, 'crashed': 1, 'timeout': 1, 'survived': 1, 'noCoverage': 1, 'unviable': 1}
assert c == expected, c
by = {(x['mutation']['original'], x['mutation']['operatorID']): x['verdict'] for x in r['results']}
assert by[('index < items.count', 'negate-condition')] == 'crashed', by
assert by[('value > 0 && value < 100', 'replace-logical')] == 'timeout', by
assert by[('first && second', 'replace-logical')] == 'unviable', by
assert by[('flag', 'swap-ternary')] == 'noCoverage', by
assert by[('false', 'swap-ternary')] == 'killed', by
assert by[('value >= 0', 'swap-ternary')] == 'killed', by
assert r['policy']['harness'] == 'swiftpm-direct', r['policy']
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
assert sorted(f['rule'] for f in r['findings']) == ['litmus/noCoverage', 'litmus/survived', 'litmus/unviable'], r['findings']
assert r['score']['percent'] == 77.78, r['score']
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
# A flaky test is found by the baseline repetitions and left out; SIGINT mid-run ends the run (130), writes its
# checkpoint as incomplete, and leaves no test helper behind.
cp -R "$WORK/subject" "$WORK/flaky"
cat > "$WORK/flaky/Tests/ExampleTests/FlakyTests.swift" <<'SWIFT'
import Example
import Testing

nonisolated(unsafe) var flakyRuns = 0

/// Passes alone, fails on its second run in one process: flaky under repetition.
@Test func `a flaky check`() {
    flakyRuns += 1
    #expect(flakyRuns != 2)
    #expect(gated(true, true))
}
SWIFT
"$BIN" run "$WORK/flaky" --trust-project --output "$WORK/interrupted" > /dev/null 2> "$WORK/interrupted.err" &
LITMUS_PID=$!
for _ in $(seq 1 600); do
  ls "$WORK/interrupted/logs" 2>/dev/null | grep -q '^mutant-' && break
  sleep 0.5
done
kill -INT "$LITMUS_PID"
set +e
wait "$LITMUS_PID"
STATUS=$?
set -e
[[ "$STATUS" == 130 ]]
sleep 1
! pgrep -f "swiftpm-testing-helper.*$WORK/interrupted" > /dev/null
python3 - "$WORK/interrupted/run.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1]))
assert not a['complete'] and a['policy']['flakyTests'] == ['ExampleTests.`a flaky check`()'], a.get('policy')
PY
if [[ -n "${LITMUS_EVIDENCE_DIR:-}" ]]; then
  [[ ! -e "$LITMUS_EVIDENCE_DIR" ]]
  mkdir -p "$LITMUS_EVIDENCE_DIR/run"
  cp "$WORK/plan.json" "$WORK/report.json" "$WORK/report.sarif" "$WORK/stale.json" "$LITMUS_EVIDENCE_DIR/"
  cp "$WORK/run/"*.json "$WORK/run/"*.pb "$WORK/run/"*.xml "$WORK/run/"*.log "$LITMUS_EVIDENCE_DIR/run/"
fi
printf 'Smoke passed: real kill, crash, timeout, survivor, no coverage and unviable verdicts, original-source preservation, JSON/protobuf/SARIF, strict gate, stale-test refusal, flaky-test exclusion, clean interruption.\n'
