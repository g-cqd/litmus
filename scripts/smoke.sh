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
# The pull-request gate: a base-branch baseline holds today's survivors, so nothing is new; an empty one
# makes every survivor new. Markdown summary and Stryker's schema render from the same run.
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.pb" --write-baseline "$WORK/base.json" 2> /dev/null
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.pb" --baseline "$WORK/base.json" --gate new-survivors --format markdown > "$WORK/summary.md"
printf '{"fingerprints":[],"tool":"litmus","version":1}' > "$WORK/empty.json"
set +e
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.pb" --baseline "$WORK/empty.json" --gate new-survivors > /dev/null 2>&1
STATUS=$?
set -e
[[ "$STATUS" == 1 ]]
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.pb" --format stryker > "$WORK/stryker.json" 2> /dev/null
python3 - "$WORK/summary.md" "$WORK/stryker.json" <<'PY2'
import json,sys
md=open(sys.argv[1]).read(); st=json.load(open(sys.argv[2]))
assert md.startswith('## Litmus mutation testing') and '**Score 77.78 %**' in md, md[:300]
statuses=sorted(m['status'] for f in st['files'].values() for m in f['mutants'])
assert st['schemaVersion']=='2' and statuses.count('Killed')==5 and 'RuntimeError' in statuses and 'CompileError' in statuses, statuses
print('gate, Markdown and Stryker reports: baseline holds today\'s survivors; an empty one fails')
PY2
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
# Pull-request runs: a diff scopes the run to the changed lines; a change reaching no site costs about a
# second and builds nothing; a result store reuses every verdict of an unchanged subject; a capped run resumes.
cp -R "$ROOT/Tests/Fixtures/Example" "$WORK/pr"
git -C "$WORK/pr" init -q && git -C "$WORK/pr" add -A && git -C "$WORK/pr" -c user.name=s -c user.email=s@s commit -qm base
sed -i '' 's|{ flag ? 1 : 2 }|{ flag ? 1 : 2 } // touched|' "$WORK/pr/Sources/Example/Decisions.swift"
grep -q '// touched' "$WORK/pr/Sources/Example/Decisions.swift"
"$BIN" run "$WORK/pr" --trust-project --diff-base HEAD --output "$WORK/pr-lines" --timeout 120 > /dev/null
git -C "$WORK/pr" checkout -q -- .
printf '\n// a comment only\n' >> "$WORK/pr/Sources/Example/Decisions.swift"
START=$(python3 -c 'import time; print(time.time())')
"$BIN" run "$WORK/pr" --trust-project --diff-base HEAD --output "$WORK/pr-none" > /dev/null
python3 - "$START" "$WORK/pr-lines/run.json" "$WORK/pr-none/run.json" <<'PY2'
import json,sys,time
elapsed=time.time()-float(sys.argv[1])
lines=json.load(open(sys.argv[2])); none=json.load(open(sys.argv[3]))
assert [r['mutation']['original'] for r in lines['results']] == ['flag'], [r['mutation']['original'] for r in lines['results']]
assert lines['plan']['scope']['onChangedLines'] and lines['policy']['baselineBuild'] == 'inactive-schema', lines['policy']
assert none['complete'] and none['results'] == [] and none['cost']['builds'] == 0, none.get('cost')
assert elapsed < 5, elapsed
print('pull-request scope: one changed-line mutant; a comment-only change in %.2f s' % elapsed)
PY2
git -C "$WORK/pr" checkout -q -- .
"$BIN" run "$WORK/pr" --trust-project --result-store "$WORK/store" --max-mutants 4 --output "$WORK/pr-capped" --timeout 120 > /dev/null
"$BIN" run "$WORK/pr" --trust-project --result-store "$WORK/store" --resume "$WORK/pr-capped" --output "$WORK/pr-rest" --timeout 120 > /dev/null
"$BIN" run "$WORK/pr" --trust-project --result-store "$WORK/store" --output "$WORK/pr-again" --timeout 120 > /dev/null
python3 - "$WORK/pr-capped/run.json" "$WORK/pr-rest/run.json" "$WORK/pr-again/run.json" "$WORK/run/run.json" <<'PY2'
import json,sys,collections
capped,rest,again,full=(json.load(open(p)) for p in sys.argv[1:])
assert capped['budget']['stoppedBy']=='max-mutants' and len(capped['budget']['untested'])==len(capped['results'])-4
assert rest['reuse']['resumed']==4 and rest['cost']['builds']>=1
assert again['reuse']['fromStore']==len(again['results']) and again['cost']['builds']==0 and again['cost']['testRuns']==0
verdicts=lambda a: collections.Counter(r['verdict'] for r in a['results'])
assert verdicts(rest)==verdicts(again)==verdicts(full), (verdicts(rest), verdicts(full))
print('budget, resume and store: %d reused without building; verdicts as the full run' % len(again['results']))
PY2
# Per-test reach (t37, t38, t49): the same verdicts with each mutant running only its reaching tests; a later run
# takes the nightly's flaky tests (no probe) and its reach where keys match.
"$BIN" run "$WORK/pr" --trust-project --per-test-reach --output "$WORK/reach" --timeout 120 > /dev/null
"$BIN" run "$WORK/pr" --trust-project --reach-from "$WORK/reach/run.json" --output "$WORK/reach2" --timeout 120 > /dev/null
python3 - "$WORK/reach/run.json" "$WORK/reach2/run.json" "$WORK/run/run.json" <<'PY2'
import json,sys,collections
reach,again,full=(json.load(open(p)) for p in sys.argv[1:])
verdicts=lambda a: collections.Counter(r['verdict'] for r in a['results'])
assert verdicts(reach)==verdicts(again)==verdicts(full), (verdicts(reach), verdicts(again), verdicts(full))
assert reach['perTestReach'] and reach['testCounts']
assert any('the probe was not run' in n for n in again['notes']), again['notes']
used=[n for n in again['notes'] if n.startswith('per-test reach from')]
assert used and ' used for 0 ' not in used[0], used
print('per-test reach: verdicts as the full run;', used[0].split(' used for ')[1])
PY2
# Workspaces: in place, the checkout is restored, also after SIGINT; a persistent workspace builds
# incrementally on its second run.
"$BIN" run "$WORK/pr" --trust-project --workspace in-place --max-mutants 3 --output "$WORK/ip" --timeout 120 > /dev/null
[[ -z "$(git -C "$WORK/pr" status --porcelain --untracked-files=no)" && ! -e "$WORK/pr/.litmus" ]]
"$BIN" run "$WORK/pr" --trust-project --workspace in-place --output "$WORK/ip-int" --timeout 120 > /dev/null 2>&1 &
LITMUS_PID=$!
for _ in $(seq 1 600); do
  compgen -G "$WORK/ip-int/logs/*-build.log" > /dev/null && break
  sleep 0.2
done
sleep 1
kill -INT "$LITMUS_PID"
set +e
wait "$LITMUS_PID"
STATUS=$?
set -e
[[ "$STATUS" == 130 ]]
[[ -z "$(git -C "$WORK/pr" status --porcelain --untracked-files=no)" && ! -e "$WORK/pr/.litmus" ]]
"$BIN" run "$WORK/pr" --trust-project --workspace "persistent:$WORK/persistent" --max-mutants 3 --output "$WORK/ps1" --timeout 120 > /dev/null
"$BIN" run "$WORK/pr" --trust-project --workspace "persistent:$WORK/persistent" --max-mutants 3 --output "$WORK/ps2" --timeout 120 > /dev/null
python3 - "$WORK/ip/run.json" "$WORK/ps1/run.json" "$WORK/ps2/run.json" <<'PY2'
import json,sys
ip,ps1,ps2=(json.load(open(p)) for p in sys.argv[1:])
assert any(n.startswith('in place: ') and 'restored and verified' in n for n in ip['notes']), ip['notes']
assert any('0 changed, 0 added, 0 removed' in n for n in ps2['notes']), ps2['notes']
b1,b2=ps1['timings']['build'],ps2['timings']['build']
assert b2 < b1, (b1,b2)
print('workspaces: in place restored (also on SIGINT); persistent build %.1f s then %.1f s' % (b1,b2))
PY2
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
  compgen -G "$WORK/interrupted/logs/mutant-*" > /dev/null && break
  sleep 0.5
done
kill -INT "$LITMUS_PID"
set +e
wait "$LITMUS_PID"
STATUS=$?
set -e
[[ "$STATUS" == 130 ]]
sleep 1
if pgrep -f "swiftpm-testing-helper.*$WORK/interrupted" > /dev/null; then
  echo "test helper survived interruption" >&2
  exit 1
fi
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
LITMUS_BIN="$BIN" bash "$ROOT/scripts/smoke-nested.sh"
printf 'Smoke passed: real kill, crash, timeout, survivor, no coverage and unviable verdicts, original-source preservation, JSON/protobuf/SARIF/Markdown/Stryker, strict and new-survivor gates, stale-test refusal, pull-request scope and fast path, budget, resume and result store, in-place and persistent workspaces, per-test reach selection and reuse, flaky-test exclusion, clean interruption.\n'
