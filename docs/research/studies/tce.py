#!/usr/bin/env python3
"""Study 2: trivial compiler equivalence (TCE) on a Litmus run's survivors.

For each mutant asked about, the mutation is applied as plain source (no schema), the target module is rebuilt in
release, and its object files, stripped of debug information and symbol names local to the object, are compared with
the original's. Identical code means the mutant cannot change behaviour: it is equivalent, proven by the compiler.
Different code proves nothing either way.

Killed mutants are run as a control: a killed mutant reported equivalent would show the comparison unsound.

usage: tce.py RUN_JSON PACKAGE_DIR DEFAULT_TARGET OUT_JSON [--killed N]
"""
import hashlib, json, os, random, shutil, subprocess, sys, time

run_json, package, target, out = sys.argv[1:5]
killed_sample = int(sys.argv[sys.argv.index('--killed') + 1]) if '--killed' in sys.argv else 10
run = json.load(open(run_json))
work = f'/tmp/tce-{target}'
shutil.rmtree(work, ignore_errors=True)
files = subprocess.check_output(['git', '-C', package, 'ls-files', '-z']).decode().split('\0')
for f in filter(None, files):
    os.makedirs(os.path.dirname(f'{work}/{f}') or work, exist_ok=True)
    shutil.copy2(f'{package}/{f}', f'{work}/{f}', follow_symlinks=False)
mirrors = f'{package}/.swiftpm/configuration/mirrors.json'
if os.path.exists(mirrors):
    os.makedirs(f'{work}/.swiftpm/configuration', exist_ok=True)
    shutil.copy2(mirrors, f'{work}/.swiftpm/configuration/mirrors.json')


def build(target):
    """Release build of `target`; returns (ok, seconds, log tail)."""
    start = time.time()
    r = subprocess.run(['swift', 'build', '-c', 'release', '--target', target, '-j', '6'], cwd=work,
                       capture_output=True, text=True)
    return r.returncode == 0, time.time() - start, r.stdout[-2000:] + r.stderr[-2000:]


def objects(target):
    """The target's object files under .build, sorted."""
    found = []
    for root, _, names in os.walk(f'{work}/.build'):
        # `<Target>.build` (native build system) or `<Target>-t.build` (Swift Build).
        if f'/{target}.build/' in root + '/' or f'/{target}-t.build/' in root + '/':
            found += [os.path.join(root, n) for n in names if n.endswith('.o')]
    # No object found would make every digest the empty one, and every mutant "equivalent".
    assert found, f'no object files for {target} under {work}/.build'
    return sorted(found)


def code_digest(target):
    """SHA-256 over the target's whole object files with debug information stripped (`strip -S`): code, data,
    symbols and relocations all count, so a difference anywhere means "not proven equivalent"."""
    h = hashlib.sha256()
    paths = objects(target)
    for path in paths:
        stripped = path + '.stripped'
        shutil.copy2(path, stripped)
        subprocess.run(['xcrun', 'strip', '-S', stripped], capture_output=True, check=True)
        h.update(os.path.basename(path).encode() + b'\0' + open(stripped, 'rb').read())
        os.remove(stripped)
    return h.hexdigest(), len(paths)


def target_of(path):
    """`Sources/<Target>/…` -> `<Target>`."""
    parts = path.split('/')
    return parts[1] if len(parts) > 2 and parts[0] == 'Sources' else target


originals = {}


def original_digest(name):
    if name not in originals:
        ok, seconds, log = build(name)
        assert ok, log
        originals[name] = code_digest(name)
        print(f'original {name}: {originals[name][1]} objects, built in {seconds:.0f} s', flush=True)
    return originals[name][0]


results = [r for r in run['results']]
survivors = [r for r in results if r['verdict'] == 'survived']
killed = [r for r in results if r['verdict'] == 'killed']
random.Random(20261102).shuffle(killed)
cases = [('survived', r) for r in survivors] + [('killed-control', r) for r in killed[:killed_sample]]
report = []
for kind, r in cases:
    m = r['mutation']
    path = f"{work}/{m['path']}"
    source = open(path, 'rb').read()
    mutated = source[:m['start']] + m['replacement'].encode() + source[m['end']:]
    name = target_of(m['path'])
    reference = original_digest(name)
    open(path, 'wb').write(mutated)
    try:
        ok, seconds, log = build(name)
        digest = code_digest(name)[0] if ok else None
    finally:
        open(path, 'wb').write(source)
    verdict = 'unviable' if not ok else ('equivalent' if digest == reference else 'different')
    report.append({'kind': kind, 'id': m['id'], 'operator': m['operatorID'], 'path': m['path'], 'line': m['line'],
                   'original': m['original'], 'replacement': m['replacement'], 'tce': verdict,
                   'buildSeconds': round(seconds, 1)})
    print(f"{kind:15} {verdict:10} {m['operatorID']:16} {m['path'].split('/')[-1]}:{m['line']} {m['original'][:50]!r}",
          flush=True)
# The comparison is deterministic only if each original rebuilds to the same digest (the sources were restored).
matches = {}
for name in originals:
    build(name)
    matches[name] = code_digest(name)[0] == originals[name][0]
json.dump({'originalDigests': {k: v[0] for k, v in originals.items()}, 'rebuildMatches': matches, 'cases': report},
          open(out, 'w'), indent=1)
print('rebuild of the originals matches:', matches)
shutil.rmtree(work, ignore_errors=True)
