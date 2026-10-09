"""Identify tested repository bytes, including uncommitted source."""

import hashlib
from pathlib import Path


def source_digest(root: Path, artifacts: tuple[Path, ...] = ()) -> dict:
    excluded = {
        ".git",
        "build",
        "_build",
        "deps",
        ".render",
        "results",
        ".direnv",
        "__pycache__",
        ".ruff_cache",
        ".aws",
        ".ssh",
        ".codex",
        ".agents",
    }
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if (
            excluded.intersection(relative.parts)
            or any(path.is_relative_to(directory.resolve()) for directory in artifacts)
            or path.is_symlink()
            or not path.is_file()
            or path.suffix == ".pdf"
            or path.name.startswith(".env")
            and path.name != ".envrc"
        ):
            continue
        digest.update(str(relative).encode() + b"\0" + path.read_bytes() + b"\0")
        count += 1
    return {
        "algorithm": "sha256-path-nul-bytes-nul",
        "digest": digest.hexdigest(),
        "files": count,
        "excluded_directories": sorted(excluded),
        "excluded_suffixes": [".pdf"],
        "excluded_names": [".env* except .envrc"],
        "artifact_directories": [str(directory.resolve()) for directory in artifacts],
        "symlinks": "excluded",
    }
