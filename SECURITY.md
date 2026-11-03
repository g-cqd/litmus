# Security

## Running project code

`plan` reads source and project files without executing a package manifest for classification. `run --trust-project` executes manifests, plugins, build scripts, and tests with the invoking user's permissions.

A copied workspace is not an operating-system sandbox. For untrusted projects, use a disposable restricted runner without credentials, signing material, production data, or unrelated workspaces. Enforce network and secret policies outside Litmus.

## Workspace safety

The default copied workspace leaves original source untouched. Persistent workspaces synchronize a separate copy. In-place execution deliberately rewrites the checkout, with backups, locking, and restoration. Avoid concurrent modification, and use `litmus restore` if an interrupted run leaves pending restoration.

Symlinks are skipped rather than followed during snapshots, and unsupported special files are refused. These checks do not protect against all hostile filesystem races or malicious scripts.

## Artifacts and result stores

Content hashes and protobuf framing detect changed or corrupt inputs. Unsigned records do not establish authenticity. Set `LITMUS_STORE_KEY` to authenticate shared result-store records and keep it unavailable to untrusted writers. Use read-only store access where appropriate.

Pin toolchains and dependencies in CI. Evidence validation does not cover every environmental input, filesystem metadata, or external service. Mutation outcomes should complement code review and other testing, not serve as the sole basis for release approval.

## Process controls

Commands have output limits and deadlines. Cancellation terminates supervised processes and preserves incomplete evidence. Simulator services have separate lifecycles; Litmus does not perform global simulator cleanup. Resource sampling is not a security boundary.

## Reporting vulnerabilities

Report security concerns privately through [GitHub security advisories](https://github.com/g-cqd/litmus/security/advisories/new) when private reporting is available. Do not include credentials or sensitive project data in public issues. If private reporting is unavailable, open a minimal issue requesting a private contact without disclosing exploit details.
