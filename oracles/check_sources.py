"""Verify exact upstream checkout identities and fetch the pinned template files.

Template files are downloaded from the pinned upstream revision into the
git-ignored `.cache` directory and checked against the SHA-256 recorded in the
manifest. Nothing downloaded is committed.
"""

import hashlib
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

CACHE = Path(".cache")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def download(url: str) -> bytes:
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt == 2:
                raise AssertionError(f"cannot fetch {url}: {error}") from error
            time.sleep(2**attempt)
    raise AssertionError("unreachable")


def fetch_files(name: str, source: dict) -> None:
    raw = source["source"].replace(
        "https://github.com/", "https://raw.githubusercontent.com/"
    )
    target = CACHE / name
    target.mkdir(parents=True, exist_ok=True)
    for path, expected in source["files"].items():
        destination = target / Path(path).name
        if destination.is_file() and sha256(destination.read_bytes()) == expected:
            continue
        data = download(f"{raw}/{source['revision']}/{path}")
        actual = sha256(data)
        if actual != expected:
            raise AssertionError(
                f"{name} {path} at {source['revision']}: expected {expected}, got {actual}"
            )
        destination.write_bytes(data)


def main() -> None:
    manifest = json.loads(Path("manifest.json").read_text())
    for name, source in manifest.items():
        if "files" in source:
            fetch_files(name, source)
            continue
        actual = subprocess.check_output(
            ["git", "-C", f"deps/{name}", "rev-parse", "HEAD"], text=True
        ).strip()
        if actual != source["revision"]:
            raise AssertionError(f"{name} revision mismatch: {actual}")
        if subprocess.check_output(
            [
                "git",
                "-C",
                f"deps/{name}",
                "status",
                "--porcelain",
                "--untracked-files=all",
            ],
            text=True,
        ):
            raise AssertionError(f"{name} source contains modifications")
    print(
        "Oracle revisions, unchanged source trees, and fetched template hashes verified."
    )


if __name__ == "__main__":
    main()
