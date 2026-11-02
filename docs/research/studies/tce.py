#!/usr/bin/env python3
"""Study 2: trivial compiler equivalence (TCE) on a Litmus run's survivors.

For each mutant asked about, the mutation is applied as plain source (no schema), the target module is rebuilt in
release, and its object files, stripped of debug information and symbol names local to the object, are compared with
the original's. Identical code means the mutant cannot change behaviour: it is equivalent, proven by the compiler.
Different code proves nothing either way.

Killed mutants are run as a control: a killed mutant reported equivalent would show the comparison unsound.

usage: tce.py RUN_JSON PACKAGE_DIR TARGET OUT_JSON [--killed N]
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


def build():
    """Release build of the target; returns (ok, seconds)."""
    start = time.time()
    r = subprocess.run(['swift', 'build', '-c', 'release', '--target', target, '-j', '6'], cwd=work,
                       capture_output=True, text=True)
    return r.returncode == 0, time.time() - start, r.stdout[-2000:] + r.stderr[-2000:]


def objects():
    """The target's object files under .build, sorted."""
    found = []
    for root, _, names in os.walk(f'{work}/.build'):
        if f'/{target}.build/' in root + '/' or root.endswith(f'/{target}.build') or f'{target}-' in root:
            found += [os.path.join(root, n) for n in names if n.endswith('.o')]
    return sorted(found)


def code_digest():
    """SHA-256 over the objects' code, constant data and relocations, debug information removed."""
    h = hashlib.sha256()
    paths = objects()
    for path in paths:
        stripped = path + '.stripped'
        shutil.copy2(path, stripped)
        # Debug information only: the symbol table stays, because relocations name their targets through it.
        subprocess.run(['xcrun', 'strip', '-S', stripped], capture_output=True)
        # The section contents of the stripped object, without load-command addresses that depend on file layout.
        dump = subprocess.run(['xcrun', 'otool', '-s', '__TEXT', '__text', '-s', '__TEXT', '__cstring',
                               '-s', '__TEXT', '__const', '-s', '__DATA', '__const', '-s', '__DATA', '__data',
                               stripped], capture_output=True).stdout
        # Relocations: a call is `bl 0` plus a relocation naming the callee, so swapping two calls changes only these.
        relocations = subprocess.run(['xcrun', 'otool', '-r', stripped], capture_output=True).stdout
        h.update(os.path.basename(path).encode() + b'\0' + dump.split(b'\n', 1)[-1] + b'\0'
                 + relocations.split(b'\n', 1)[-1])
        os.remove(stripped)
    return h.hexdigest(), len(paths)


ok, seconds, log = build()
assert ok, log
original, count = code_digest()
print(f'original: {count} objects, built in {seconds:.0f} s', flush=True)

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
    open(path, 'wb').write(mutated)
    try:
        ok, seconds, log = build()
        digest = code_digest()[0] if ok else None
    finally:
        open(path, 'wb').write(source)
    verdict = 'unviable' if not ok else ('equivalent' if digest == original else 'different')
    report.append({'kind': kind, 'id': m['id'], 'operator': m['operatorID'], 'path': m['path'], 'line': m['line'],
                   'original': m['original'], 'replacement': m['replacement'], 'tce': verdict,
                   'buildSeconds': round(seconds, 1)})
    print(f"{kind:15} {verdict:10} {m['operatorID']:16} {m['path'].split('/')[-1]}:{m['line']} {m['original'][:50]!r}",
          flush=True)
# The comparison is deterministic only if the original rebuilds to the same digest.
build()
again = code_digest()[0]
json.dump({'target': target, 'originalDigest': original, 'rebuildMatches': again == original, 'cases': report},
          open(out, 'w'), indent=1)
print('rebuild of the original matches:', again == original)
shutil.rmtree(work, ignore_errors=True)
