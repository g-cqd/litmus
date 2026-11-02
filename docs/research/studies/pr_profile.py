#!/usr/bin/env python3
"""For recent PRs merged into develop: Swift lines changed, mutants on them (diff mode) and in the changed files."""
import json, os, re, shutil, subprocess, sys, collections
REPO = '/path/to/app'
LITMUS = '/Volumes/Personal/Github/g-cqd/litmus/.build-release/release/litmus'
N = int(sys.argv[1]) if len(sys.argv) > 1 else 60
git = lambda *a: subprocess.check_output(['git', '-C', REPO, *a], text=True)
merges = git('log', '--first-parent', '--merges', f'-{N}', '--format=%H %cs %s').splitlines()
out = []
for line in merges:
    sha, date, subject = line.split(' ', 2)
    parents = git('rev-list', '--parents', '-n1', sha).split()
    if len(parents) < 3: continue
    base, head = parents[1], parents[2]
    mb = git('merge-base', base, head).strip()
    diff = git('diff', '--unified=0', '--no-color', mb, head, '--', '*.swift')
    changed = collections.defaultdict(set); path = None
    for d in diff.splitlines():
        if d.startswith('+++ '):
            path = None if d.endswith('/dev/null') else d[6:]
        elif d.startswith('@@') and path:
            m = re.search(r'\+(\d+)(?:,(\d+))?', d); start, count = int(m.group(1)), int(m.group(2) or 1)
            changed[path].update(range(start, start + count))
    tests = [p for p in changed if '/Tests/' in p or p.split('/')[-1].endswith('Tests.swift')]
    tree = '/tmp/prprofile/tree'
    shutil.rmtree(tree, ignore_errors=True); os.makedirs(tree)
    subprocess.run(f'git -C {REPO} archive {head} | tar -x -C {tree}', shell=True, check=True)
    r = subprocess.run([LITMUS, 'plan', tree], capture_output=True, text=True)
    plan = json.loads(r.stdout) if r.returncode == 0 else {'mutations': []}
    in_files = [m for m in plan['mutations'] if m['path'] in changed]
    on_lines = [m for m in in_files if m['line'] in changed[m['path']]]
    modules = {p.split('/')[1] if p.startswith('Modules/') else p.split('/')[0] for p in changed}
    rec = {'pr': re.search(r'#(\d+)', subject).group(1) if '#' in subject else sha[:8], 'date': date,
           'swiftFiles': len(changed), 'testFiles': len(tests), 'linesChanged': sum(len(v) for v in changed.values()),
           'mutantsOnChangedLines': len(on_lines), 'mutantsInChangedFiles': len(in_files), 'modules': sorted(modules),
           'planMutants': len(plan['mutations'])}
    out.append(rec); print(json.dumps(rec), flush=True)
shutil.rmtree('/tmp/prprofile/tree', ignore_errors=True)
json.dump(out, open('/tmp/prprofile/profile.json', 'w'), indent=1)
