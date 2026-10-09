"""Compare independently parsed MIME and bounded authentication observations."""

import base64
import json
import os
import platform
import sys
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses
from pathlib import Path


def mime_node(message) -> dict:
    """Discard wire choices while preserving MIME structure and decoded bytes."""
    if message.defects:
        raise ValueError(f"Malformed MIME part: {message.defects}")
    filename = message.get_filename()
    cid = message.get("Content-ID")
    disposition = message.get_content_disposition()
    node = {
        "media_type": message.get_content_type(),
        "charset": message.get_content_charset(),
    }
    if message.is_multipart():
        node["parts"] = [mime_node(part) for part in message.iter_parts()]
    else:
        payload = message.get_payload(decode=True)
        if (
            message.get_content_maintype() == "text"
            and not filename
            and not cid
            and disposition != "attachment"
        ):
            payload = payload.replace(b"\r\n", b"\n")
        node["body_base64"] = base64.b64encode(payload).decode("ascii")
    # Inline is the default for body alternatives; an absent explicit inline
    # disposition is equivalent only when no filename or CID is attached.
    if filename or cid or disposition == "attachment":
        node.update(disposition=disposition, filename=filename, content_id=cid)
    return node


def normalize_email(value: dict) -> dict:
    raw = base64.b64decode(value["raw_base64"], validate=True)
    message = BytesParser(policy=policy.default).parsebytes(raw)
    if message.defects:
        raise ValueError(f"Malformed MIME: {message.defects}")
    headers = {}
    for name in ("from", "to", "cc", "reply-to"):
        headers[name] = sorted(
            getaddresses([str(v) for v in message.get_all(name, [])])
        )
    headers["subject"] = str(message.get("subject", ""))
    headers["bcc_present"] = "bcc" in message
    represented = {
        "from",
        "to",
        "cc",
        "reply-to",
        "subject",
        "bcc",
        "date",
        "message-id",
        "mime-version",
        "content-type",
        "content-transfer-encoding",
    }
    headers["custom"] = sorted(
        (name.lower(), str(value))
        for name, value in message.items()
        if name.lower() not in represented and not name.lower().startswith("list-")
    )
    # RFC2369 URL-list fields are structured ASCII, not unstructured encoded
    # words. Decoding RFC2047 here would conceal a broken unsubscribe header.
    headers["list_commands"] = sorted(
        (name.lower(), " ".join(value.split()))
        for name, value in message.raw_items()
        if name.lower().startswith("list-")
    )
    envelope = value["envelope"]
    return {
        "envelope": {
            "sender": envelope["sender"],
            "recipients": sorted(envelope["recipients"]),
        },
        "headers": headers,
        "mime": mime_node(message),
    }


def compare(upstream: dict, correio: dict) -> None:
    fixtures = json.loads(Path("fixtures/email.json").read_text())
    fixture_names = {fixture["id"] for fixture in fixtures}
    if not fixture_names or len(fixture_names) != len(fixtures):
        raise AssertionError("Email fixture names must be unique and nonempty")
    if (
        set(upstream["swoosh"]) != fixture_names
        or set(correio["email"]) != fixture_names
    ):
        raise AssertionError("Email output names differ from retained input fixtures")
    scenarios = {"valid", "reuse", "expired", "wrong_purpose", "wrong_destination"}
    if set(upstream["phoenix"]) != scenarios or set(correio["phoenix"]) != scenarios:
        raise AssertionError(
            "Sequential output must include all five required scenarios"
        )
    expected = {
        name: normalize_email(value) for name, value in upstream["swoosh"].items()
    }
    actual = {name: normalize_email(value) for name, value in correio["email"].items()}
    directory = Path(os.environ.get("CORREIO_ORACLE_RESULTS", "results"))
    (directory / "swoosh-normalized.json").write_text(
        json.dumps(expected, ensure_ascii=False, indent=2) + "\n"
    )
    (directory / "correio-normalized.json").write_text(
        json.dumps(actual, ensure_ascii=False, indent=2) + "\n"
    )
    if expected != actual:
        differences = [
            name
            for name in expected.keys() | actual.keys()
            if expected.get(name) != actual.get(name)
        ]
        raise AssertionError(
            f"Email oracle differences: {differences}; inspect results/*-normalized.json"
        )
    if upstream["phoenix"] != correio["phoenix"]:
        raise AssertionError(
            f"Phoenix comparison differs: {upstream['phoenix']} != {correio['phoenix']}"
        )
    for provider, rounds in (("ash", upstream["ash"]), ("correio", correio["ash"])):
        if len(rounds) < 3:
            raise AssertionError(f"{provider}: fewer than three contention rounds")
        for observation in rounds:
            if (
                observation["attempts"],
                observation["successes"],
                observation["rejections"],
            ) != (24, 1, 23):
                raise AssertionError(
                    f"{provider}: failed single-use comparison: {observation}"
                )
            if len(set(observation["backend_ids"])) != 24:
                raise AssertionError(
                    f"{provider}: contention did not use 24 separate connections"
                )
            if provider == "ash" and observation["revocation_conflicts"] < 1:
                raise AssertionError("Ash: no observed revocation conflict")
    from source_digest import source_digest

    receipt = {
        "status": "passed",
        "platform": platform.platform(),
        "python": platform.python_version(),
        "correio_source": source_digest(Path("..").resolve(), (directory,)),
        "sources": json.loads(Path("manifest.json").read_text()),
        "email_fixtures": len(expected),
        "sequential_cases": len(upstream["phoenix"]),
        "contention_rounds": 3,
        "concurrent_connections": 24,
    }
    (directory / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(
        f"Matched {len(expected)} Swoosh MIME fixtures, {len(upstream['phoenix'])} Phoenix cases, and three 24-connection Ash/correio races."
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: compare.py upstream.json correio.json")
    compare(*(json.loads(Path(path).read_text()) for path in sys.argv[1:]))
