"""Parse one message with Python's standard-library parser, independent of
Correio, and print each decoded field as `name<TAB>base64(value)`.

The message arrives base64-encoded as the only argument. Tests pass fixed
public fixtures only.
"""

import base64
import sys
from email import message_from_bytes, policy


def emit(name: str, value) -> None:
    data = value if isinstance(value, bytes) else str(value).encode()
    print(name + "\t" + base64.b64encode(data).decode())


raw = base64.b64decode(sys.argv[1])
message = message_from_bytes(raw, policy=policy.default)
defects = list(message.defects)
emit("subject", message["subject"])
for field in ("from", "to", "cc", "reply-to"):
    header = message[field]
    if header is None:
        continue
    defects += list(header.defects)
    for index, mailbox in enumerate(header.addresses):
        emit(f"{field}.{index}.name", mailbox.display_name)
        emit(f"{field}.{index}.address", mailbox.addr_spec)
emit("header-names", ",".join(sorted({name.lower() for name in message.keys()})))
leaves = [part for part in message.walk() if not part.is_multipart()]
for index, part in enumerate(leaves):
    defects += list(part.defects)
    emit(f"part.{index}.type", part.get_content_type())
    emit(f"part.{index}.encoding", part["content-transfer-encoding"])
    emit(f"part.{index}.filename", part.get_filename() or "")
    emit(f"part.{index}.body", part.get_payload(decode=True))
emit("defects", len(defects))
emit("longest-line", max(len(line) for line in raw.split(b"\r\n")))
emit(
    "bare-line-breaks",
    raw.replace(b"\r\n", b"").count(b"\n") + raw.replace(b"\r\n", b"").count(b"\r"),
)
