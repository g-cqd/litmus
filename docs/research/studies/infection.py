#!/usr/bin/env python3
"""Study 3: infection of logical-operator survivors.

A mutant `a && b` -> `a || b` changes a value only when `a != b`. A survivor whose operands were equal every time the
tests evaluated them was reached but never infected: its tests never put the code in the state the mutation changes.
One whose operands differed was infected, and the change did not propagate to an assertion.

Only operands without calls, subscripts, closures or `try`/`await` are instrumented: the instrumented code evaluates
both operands, where `&&` and `||` skip the second, which is sound only when evaluating it has no effect. The others
are reported as not measured.

The suite runs once, unmutated, on the instrumented copy: each site writes `<id>.reached` and, when its operands
differ, `<id>.infected`, under $LITMUS_INFECTION_DIR.

usage: infection.py RUN_JSON PACKAGE_DIR MODULE_SOURCES_DIR OUT_JSON
"""
import json, os, re, shutil, subprocess, sys

run_json, package, sources, out = sys.argv[1:5]
run = json.load(open(run_json))
work = '/tmp/infection-work'
shutil.rmtree(work, ignore_errors=True)
for f in filter(None, subprocess.check_output(['git', '-C', package, 'ls-files', '-z']).decode().split('\0')):
    os.makedirs(os.path.dirname(f'{work}/{f}') or work, exist_ok=True)
    shutil.copy2(f'{package}/{f}', f'{work}/{f}', follow_symlinks=False)
mirrors = f'{package}/.swiftpm/configuration/mirrors.json'
if os.path.exists(mirrors):
    os.makedirs(f'{work}/.swiftpm/configuration', exist_ok=True)
    shutil.copy2(mirrors, f'{work}/.swiftpm/configuration/mirrors.json')

# Operands made only of names, member access, literals, comparison, arithmetic and negation.
# A force unwrap or forced cast is excluded too: guarded by the other operand, evaluating it unguarded may trap.
UNSAFE = re.compile(r'[\(\[\{]|\btry\b|\bawait\b|\$|[\w\)\]]!(?!=)|\bas!')


def split_logical(text, operator):
    """The two operands of the top-level `operator` in `text` (Litmus parenthesises them), or None."""
    depth = 0
    for i in range(len(text) - 1):
        c = text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif depth == 0 and text[i:i + 2] == operator:
            return text[:i].strip(), text[i + 2:].strip()
    return None


def unwrap(text):
    text = text.strip()
    while text.startswith('(') and text.endswith(')'):
        depth = 0
        for i, c in enumerate(text):
            depth += c == '('
            depth -= c == ')'
            if depth == 0 and i < len(text) - 1:
                return text
        text = text[1:-1].strip()
    return text


cases = []
edits = {}
for r in run['results']:
    m = r['mutation']
    if r['verdict'] != 'survived' or m['operatorID'] != 'replace-logical':
        continue
    original = m['original']
    operator = '&&' if split_logical(unwrap(original), '&&') else '||'
    parts = split_logical(unwrap(original), operator)
    if not parts or any(UNSAFE.search(unwrap(p)) for p in parts):
        cases.append({'id': m['id'], 'path': m['path'], 'line': m['line'], 'original': original, 'measured': False})
        continue
    left, right = (unwrap(p) for p in parts)
    replacement = (f'__litmusInfection("{m["id"]}", {left}, {right}) {operator} ({right})')
    # The helper returns the left operand after recording; the right is evaluated again by the operator, which
    # matches the original's own evaluation of it whenever the original evaluates it.
    edits.setdefault(m['path'], []).append((m['start'], m['end'], replacement))
    cases.append({'id': m['id'], 'path': m['path'], 'line': m['line'], 'original': original, 'measured': True})

for path, changes in edits.items():
    data = open(f'{work}/{path}', 'rb').read()
    for start, end, replacement in sorted(changes, reverse=True):
        data = data[:start] + replacement.encode() + data[end:]
    open(f'{work}/{path}', 'wb').write(data)
open(f'{work}/{sources}/__LitmusInfection.swift', 'w').write('''import Foundation

/// Records that the site ran and, when its operands differ, that a logical mutation would have changed its value.
@inline(never)
func __litmusInfection(_ id: String, _ left: Bool, _ right: Bool) -> Bool {
    if let directory = ProcessInfo.processInfo.environment["LITMUS_INFECTION_DIR"] {
        FileManager.default.createFile(atPath: directory + "/" + id + ".reached", contents: nil)
        if left != right { FileManager.default.createFile(atPath: directory + "/" + id + ".infected", contents: nil) }
    }
    return left
}
''')

markers = '/tmp/infection-markers'
shutil.rmtree(markers, ignore_errors=True)
os.makedirs(markers)
build = subprocess.run(['swift', 'build', '--build-tests', '-j', '6'], cwd=work, capture_output=True, text=True)
if build.returncode != 0:
    print(build.stdout[-3000:], build.stderr[-3000:])
    sys.exit(1)
env = dict(os.environ, LITMUS_INFECTION_DIR=markers)
test = subprocess.run(['swift', 'test', '--skip-build'], cwd=work, env=env, capture_output=True, text=True)
found = set(os.listdir(markers))
for c in cases:
    if c['measured']:
        c['reached'] = c['id'] + '.reached' in found
        c['infected'] = c['id'] + '.infected' in found
json.dump({'suitePassed': test.returncode == 0, 'cases': cases}, open(out, 'w'), indent=1)
for c in cases:
    state = ('not measured' if not c['measured'] else 'infected' if c['infected'] else
             'reached, never infected' if c['reached'] else 'not reached')
    print(f"{state:24} {c['path'].split('/')[-1]}:{c['line']} {c['original'][:70]!r}")
print('suite passed:', test.returncode == 0)
shutil.rmtree(work, ignore_errors=True)
