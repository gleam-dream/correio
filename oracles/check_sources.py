"""Verify retained template bytes and exact upstream checkout identities."""

import hashlib
import json
import subprocess
from pathlib import Path


def main() -> None:
    manifest = json.loads(Path("manifest.json").read_text())
    for name, source in manifest.items():
        if name != "phoenix":
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
        for filename, expected in source.get("files", {}).items():
            actual = hashlib.sha256(Path(filename).read_bytes()).hexdigest()
            if actual != expected:
                raise AssertionError(f"{filename} checksum mismatch: {actual}")
        if not Path(source["license_file"]).is_file():
            raise AssertionError(f"{name} license missing")
    print(
        "Oracle revisions, unchanged source trees, and Phoenix template hashes verified."
    )


if __name__ == "__main__":
    main()
