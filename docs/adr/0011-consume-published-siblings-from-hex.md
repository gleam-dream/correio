# Consume published siblings from Hex

<a id="adr-0011"></a>

Status: accepted
Date: 2026-11-25

## Decision

- The Postmark adapter depends on HTTP Gun, and the passwordless demo on
  Hellhound, through Hex version requirements in `gleam.toml`.
- Each package's `manifest.toml` locks the resolved version and checksum.
  `gleam deps update <package>` is the only way a sibling moves.

This supersedes the Git dependency declarations in
[ADR 0006](0006-unpublished-siblings-are-git-dependencies-on-main.md). Its
single lock, explicit updates, absence of a shared compiled cache and
credential limits remain.

## Rationale

- HTTP Gun and Hellhound are published on Hex, so a version range names them.
- A Git requirement for a published package would give consumers a second
  source for one library and block Correio's own publication.
