# Workspace restoration

**Property.** After any run, finished, failed, cancelled or killed at any instruction, every file of the subject holds the bytes it held before the run, or the run reports which file it could not restore and keeps that file's original for `litmus restore`.

## Assumptions

- A1. `AtomicFile.replace` replaces a file by rename on the same file system: a reader sees the old bytes or the new, never a mix. With `.barrier` durability the new bytes are on storage before it returns.
- A2. SHA-256 has no practical collisions.
- A3. One run at a time holds a subject's workspace lock (`WorkspaceLock`).

## Copy and persistent modes (`--workspace copy`, the default, and `persistent:<dir>`)

**I0.** No byte under the subject root is written. Schemas are written into the run's snapshot: under the run's output directory, or in the persistent directory. `RunSession.init` refuses an output directory inside the root, and the workspace preparation refuses a persistent directory inside it. A copy-mode run therefore has nothing to restore.

## In-place mode (`--workspace in-place`)

`InPlaceJournal.rewrite(path, original, schema)` performs, in order:

1. If missing, write the backup `<sha(original)>.orig` (barrier).
2. Write the record `{path, original: sha(original), schema: sha(schema)}` (barrier).
3. Write the file with the schema.

`InPlaceJournal.restoreAll` handles each record as follows, where `current = sha(file)`:

- `current == schema`: replace the file with the backup, after checking `sha(backup) == original`, then drop the record.
- `current == original`: drop the record. The file was never rewritten, or was already restored.
- Anything else: leave the file and keep its record and backup. The run fails and names the file.

**I1. Recoverability.** Before a file's bytes change (step 3), its record and original are on storage (steps 1–2, A1).

**I2. Only Litmus's own write is undone.** A file is written back only when it holds exactly the schema Litmus wrote (A2), and only with bytes whose digest is the recorded original.

**I3. No silent loss.** A file edited during the run holds neither digest. It is left as it is, and its original stays in the journal.

**I4. Crash at any point.** By A1 the file is always the original or the schema, so a crash leaves one of three states:

| Crash | State left | Next `restoreAll` / `litmus restore` |
| --- | --- | --- |
| before step 2 | no record; file = original | nothing to do |
| after step 2, before step 3 | record; file = original | record dropped |
| during or after step 3 | record; file = schema | original written back |

**I5. Confinement.** A record whose path is absolute or contains `..` is rejected, so restoration writes only under the root.

## Tests

- `an in-place run decides the same verdicts and leaves the subject as it was` (`SnapshotAndRunnerTests`)
- `an in-place run that fails restores the subject before it reports` (`SnapshotAndRunnerTests`)
- `in place, a package depending on one outside the root is never reused` (`SnapshotAndRunnerTests`)
