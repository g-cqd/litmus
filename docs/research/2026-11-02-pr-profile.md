# Pull requests of the reference app, sized in mutants — 2026-11-02

Method (`studies/pr_profile.py`): the 60 last pull requests merged into `develop` (first-parent merges, read with git,
nothing checked out). For each, the diff from the merge base to the pull request's head (Swift files, zero context), the
tree at the head archived to a temporary directory, `litmus plan` on it (current tier), and the planned mutants counted
on the changed lines and in the changed files. Data: `studies/pr-profile.json`.

| Per PR touching Swift (42 of 60) | Median | p75 | p90 | Max |
| --- | --- | --- | --- | --- |
| Swift files changed | 4 | 11 | 22 | 39 |
| Lines changed | 122 | 265 | 678 | 2653 |
| Mutants on changed lines | 1 | 4 | 9 | 52 |
| Mutants in changed files | 8 | 23 | 52 | 101 |
| Test files changed | 1 | 3 | 8 | 17 |
| Local packages touched | 1 | 2 | 3 | 7 |

- 17 of 42 create no mutant on changed lines (view code, assets, tests, configuration).
- 27 of 42 touch only local packages; 15 touch the app target.
- 186 changed-line mutants over 42 pull requests in about two months.
- Most touched: the app target (15), ModuleParts (11), ModuleUI (10), ModuleAssets (9), ModuleAPI (7), ModuleTickets (7).

Not measured: mutants of the extended tiers per pull request (scale by the census, about 8× for the extended tier);
pull requests that were closed without merging.
