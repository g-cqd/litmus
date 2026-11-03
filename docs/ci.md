# CI and incremental runs

## Changed-line checks

Fetch enough Git history to resolve the chosen base revision, then run:

```sh
litmus run . --trust-project --diff-base origin/main --budget 600 \
  --result-store /tmp/litmus-store --output /tmp/litmus-pr --report json
```

For a merge commit, `HEAD^1` can identify its target parent if the checkout includes that parent. Choose the base explicitly for other checkout strategies.

## Workspaces

- `--workspace copy` creates a fresh copy and leaves the original source unchanged.
- `--workspace persistent:DIR` synchronizes a reusable copy and retains its build output.
- `--workspace in-place` backs up originals before rewriting the checkout and restores them after each batch, on handled errors, and on termination signals.

A workspace lock prevents simultaneous runs from sharing a persistent or in-place workspace. Use `litmus restore DIR` after an interruption if restoration is still required. Do not run builds or editors that rewrite files concurrently with in-place mutation.

Copied workspaces must include required local package dependencies. Copying only a package with sibling path dependencies does not copy those siblings. Use the containing repository as root with `--package-path relative/package` to preserve siblings and run from the package directory, or use in-place execution. `--build-directory DIR` retains Xcode DerivedData separately.

## Verdict reuse

`--result-store DIR` stores verified verdict records outside the source root. The default `--reuse closure` keys results on the package and its local dependencies, toolchain, and execution options. External dependencies outside an in-place subject root conservatively disable reuse. `--reuse declaration` provides narrower reuse and should be evaluated against the project's dependency model.

Set `LITMUS_STORE_KEY` to authenticate records with HMAC-SHA256. Keep the key private to trusted jobs. Use `--store-read-only` for jobs that must not modify a shared store. Unsigned records detect corruption, not an attacker controlling the store. The default size limit is 1024 MiB; `--store-limit` changes it.

`--resume RUN` reuses matching verdicts from a prior run. `--reach-from RUN` imports flaky-test information and matching per-test reach evidence. Neither option makes incompatible verdicts reusable.

## Baselines

Generate a baseline from a completed run on the target branch:

```sh
litmus analyze . --results /tmp/litmus-full/run.pb --write-baseline /tmp/litmus-baseline.json
```

Compare a pull request against it:

```sh
litmus run . --trust-project --diff-base origin/main \
  --baseline /tmp/litmus-baseline.json --gate new-survivors \
  --output /tmp/litmus-pr --report json
```

Keep baselines separated by project and update them only from trusted runs. A baseline suppresses known findings; it does not prove those behaviors are correct.

## Budgets and sharding

`--budget SECONDS` stops starting new work after the budget, rather than killing work already running. `--max-mutants N` limits mutations tested. Both report untested mutations explicitly.

`--shard k/n` assigns whole-module units to workers. Combine compatible shard results with `litmus merge`; incompatible runs are rejected.
