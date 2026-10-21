"""Verify exact upstream dependency checkout revisions before comparison."""

import json
import subprocess
from pathlib import Path


def main() -> None:
    manifest = json.loads(Path("manifest.json").read_text())
    for name, source in manifest.items():
        if "files" in source:
            continue
        actual = subprocess.check_output(
            ["git", "-C", f"deps/{name}", "rev-parse", "HEAD"], text=True
        ).strip()
        if actual != source["revision"]:
            raise AssertionError(f"{name} revision mismatch: {actual}")
    print("Oracle dependency revisions verified.")


if __name__ == "__main__":
    main()
