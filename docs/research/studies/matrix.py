#!/usr/bin/env python3
"""Studies 1 and 4: the kill matrix, subsumption, and per-test selection, from one Litmus run made with
`--no-fail-fast --per-test-reach --kill-confirmation none --baseline-repetitions 1`.

- Kill matrix: for each killed mutant, every Swift Testing test with a failing issue in its first (whole-suite) run.
- Subsumption: mutant A subsumes B when A's killing tests are a non-empty subset of B's (every test that kills A also
  kills B). The minimal mutants are those subsumed by no other except their duplicates; the subsumption score is the
  share of minimal mutant groups killed, the measure that redundant mutants cannot inflate (Ammann et al.).
- Tests: which kill nothing, which kill only what others kill too.
- Selection (study 4): for each reached mutant, the tests that reach it alone; the cost of running only those against
  the whole suite, from each test's duration alone (process start included) and the baseline's duration.

usage: matrix.py RUN_DIR OUT_JSON
"""
import collections, json, sys

run_dir, out = sys.argv[1:3]
run = json.load(open(f'{run_dir}/run.json'))


def test_name(identifier):
    slash = identifier.rfind('/')
    return identifier[:slash] if slash >= 0 and '.swift:' in identifier[slash:] else identifier


def failing_tests(evidence):
    tests = set()
    for path in evidence:
        # The first run only: its events file has no -rerun/-confirm/-control suffix after the mutant id.
        name = path.split('/')[-1]
        if not name.endswith('.events.jsonl') or any(s in name for s in ('-rerun', '-confirm', '-control')):
            continue
        for line in open(f'{run_dir}/{path}'):
            e = json.loads(line)
            if e.get('kind') == 'event' and e['payload'].get('kind') == 'issueRecorded':
                issue = e['payload'].get('issue', {})
                if issue.get('isKnown') or issue.get('severity') == 'warning':
                    continue
                if e['payload'].get('testID'):
                    tests.add(test_name(e['payload']['testID']))
    return frozenset(tests)


results = {r['mutation']['id']: r for r in run['results']}
killed = {i: failing_tests(r['evidence']) for i, r in results.items() if r['verdict'] == 'killed'}
no_names = [i for i, t in killed.items() if not t]
matrix = {i: t for i, t in killed.items() if t}

# Subsumption over distinct killing sets; duplicates (equal sets) form one group.
groups = collections.defaultdict(list)
for i, t in matrix.items():
    groups[t].append(i)
sets = list(groups)
minimal = [s for s in sets if not any(o < s for o in sets)]
tests_alone = run.get('testNanoseconds') or {}
all_tests = set(tests_alone)
kills_per_test = collections.Counter(t for s in matrix.values() for t in s)
never_kill = sorted(all_tests - set(kills_per_test))
# A test is necessary when some minimal group is killed only by it.
necessary = sorted({next(iter(s)) for s in minimal if len(s) == 1})

# Selection: tests reaching each mutant, alone.
reach = run.get('perTestReach') or {}
baseline_seconds = (run.get('policy') or {}).get('baselineNanoseconds', 0) / 1e9
per_mutant = []
for i, tests in reach.items():
    cost = sum(tests_alone.get(t, 0) for t in tests) / 1e9
    per_mutant.append({'id': i, 'verdict': results[i]['verdict'], 'reachingTests': len(tests), 'selectedSeconds':
                       round(cost, 3)})
reached = [r for r in run['results'] if r['verdict'] not in ('noCoverage', 'unviable', 'notRun')]
missing_reach = [r['mutation']['id'] for r in reached if r['mutation']['id'] not in reach]
# A kill by a test that does not reach the mutant alone would make selection miss it.
missed_by_selection = [i for i, t in matrix.items() if i in reach and not (t & set(reach[i]))]

summary = {
    'killed': len(killed), 'killedWithTestNames': len(matrix), 'killedWithoutTestNames': len(no_names),
    'distinctKillingSets': len(sets), 'minimalGroups': len(minimal),
    'minimalMutants': sum(len(groups[s]) for s in minimal),
    'tests': len(all_tests), 'testsThatKillNothing': len(never_kill), 'testsNecessaryForAMinimalGroup': len(necessary),
    'meanKillersPerMutant': round(sum(len(t) for t in matrix.values()) / max(1, len(matrix)), 2),
    'baselineSeconds': round(baseline_seconds, 2),
    'meanReachingTests': round(sum(m['reachingTests'] for m in per_mutant) / max(1, len(per_mutant)), 2),
    'meanSelectedSeconds': round(sum(m['selectedSeconds'] for m in per_mutant) / max(1, len(per_mutant)), 3),
    'reachedMutantsWithoutReachData': len(missing_reach),
    'killsSelectionWouldMiss': len(missed_by_selection),
}
json.dump({'summary': summary, 'neverKill': never_kill, 'necessary': necessary, 'selection': per_mutant,
           'missedBySelection': missed_by_selection, 'killedWithoutTestNames': no_names}, open(out, 'w'), indent=1)
for k, v in summary.items():
    print(f'{k:34} {v}')
