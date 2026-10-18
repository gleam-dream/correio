# Unpublished sibling packages are Git dependencies on main, locked by the manifest

<a id="adr-0006"></a>

## Decision

- The Postmark adapter and the browser demo depend on the unpublished HTTP Gun and Warden packages as Git dependencies on `main`. No `gleam.toml` names a commit.
- Each package's `manifest.toml` records the resolved commit. It is the only place that holds a sibling revision, and `gleam update <package>` is the only way it moves.
- No script, workflow, or file duplicates a sibling revision. No job updates siblings on a schedule.
- CI restores no shared compiled dependency cache, and every checkout keeps no persisted credentials.

## Rationale

- The siblings are unpublished, so a version range cannot name them. A branch reference plus a committed lock names a reproducible revision without repeating it by hand in several files.
- A hand-edited revision in `gleam.toml`, a pin file, and the lock held the same fact three times and drifted out of date on every sibling change.
- A shared compiled cache could hide a stale dependency behind a passing build.
- Persisted checkout credentials in artifacts or caches would leak access.

## Consequences

- A change to a sibling's public contract reaches Correio only when a maintainer runs `gleam update` for that sibling and commits the new lock.
- CI records the locked sibling commits beside the Correio commit in its native evidence.
- Native and oracle artifacts expire after fourteen days and benchmark observations after thirty. No credential, database data, or authentication answer enters an artifact.
