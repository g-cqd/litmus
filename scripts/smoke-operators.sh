#!/bin/bash
# Real execution of the standard and experimental operators on Tests/Fixtures/Operators: planning per tier, the
# verdict of every mutant, and the subject's sources untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${LITMUS_BIN:-$ROOT/.build/debug/litmus}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/litmus-operators.XXXXXX")"
cleanup() {
  STATUS=$?
  if [[ "$STATUS" == 0 ]]; then rm -rf "$WORK"; else printf 'Operator smoke failed; evidence retained at %s\n' "$WORK" >&2; fi
}
trap cleanup EXIT
cp -R "$ROOT/Tests/Fixtures/Operators" "$WORK/subject"
SOURCE="$WORK/subject/Sources/Operators/Operators.swift"
BEFORE="$(shasum -a 256 "$SOURCE")"
count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["mutations"]))' "$1"; }
"$BIN" plan "$WORK/subject" --output "$WORK/plan-default.json" 2> /dev/null
"$BIN" plan "$WORK/subject" --operator-tier standard --output "$WORK/plan-standard.json" 2> /dev/null
"$BIN" plan "$WORK/subject" --operator-tier experimental --output "$WORK/plan-all.json" 2> /dev/null
[[ "$(count "$WORK/plan-default.json")" == 0 ]]
[[ "$(count "$WORK/plan-standard.json")" == 7 ]]
[[ "$(count "$WORK/plan-all.json")" == 12 ]]
"$BIN" run "$WORK/subject" --trust-project --operator-tier experimental --output "$WORK/run" --timeout 120 > /dev/null
[[ "$(shasum -a 256 "$SOURCE")" == "$BEFORE" ]]
python3 - "$WORK/run/run.json" <<'PY'
import json,sys,collections
r=json.load(open(sys.argv[1]))
assert r['complete']
c=collections.Counter(x['verdict'] for x in r['results'])
assert c == {'killed': 8, 'survived': 3, 'noCoverage': 1}, c
by={}
for x in r['results']:
    m=x['mutation']; by.setdefault((m['original'], m['operatorID']), []).append((m['replacement'], x['verdict']))
def verdicts(original, operator): return sorted(by[(original, operator)])
assert verdicts('price * count','replace-arithmetic') == [('price / count','killed')], by
assert verdicts('sum / count','replace-arithmetic') == [('sum * count','killed')], by
assert verdicts('value + 0','replace-arithmetic') == [('value - 0','survived')], by
assert verdicts('value <= limit','replace-relational') == [('value < limit','survived'), ('value > limit','killed')], by
assert verdicts('true','flip-boolean') == [('false','killed')], by
assert verdicts('recorder.record("ping")','remove-call') == [('()','killed')], by
assert verdicts('recorder.record("pong")','remove-call') == [('()','killed')], by
assert verdicts('recorder.record("warm")','remove-call') == [('()','survived')], by
assert verdicts('items.append(item)','remove-call') == [('()','killed')], by
assert verdicts('recorder.record("noisy")','remove-call') == [('()','killed')], by
assert verdicts('value * 2','replace-arithmetic') == [('value / 2','noCoverage')], by
assert not any('print' in o for o,_ in by), 'logging must not be removed'
assert sorted(r['policy']['operators']) == sorted(['negate-condition','swap-ternary','replace-logical','replace-relational','flip-boolean','replace-arithmetic','replace-range','remove-negation','replace-nil-coalescing','remove-call'])
print('operators:', dict(c))
PY
# Score gates: the run scored 8 of 12 mutants (66.67 %).
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.json" --minimum-score 66 > /dev/null 2>&1
set +e
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.json" --minimum-score 80 > /dev/null 2> "$WORK/gate.err"; BELOW=$?
set -e
[[ "$BELOW" != 0 ]] && grep -q "below the minimum 80 %" "$WORK/gate.err"
set +e
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.json" --maximum-score-drop 5 --baseline-run "$WORK/run/run.json" > /dev/null 2>&1; SAME=$?
"$BIN" analyze "$WORK/subject" --results "$WORK/run/run.json" --maximum-score-drop 5 > /dev/null 2>&1; NOBASE=$?
set -e
[[ "$SAME" == 0 && "$NOBASE" != 0 ]]
printf 'Operator smoke passed: tiers plan as documented; every standard and experimental verdict is as expected; sources untouched.\n'
