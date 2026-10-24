"""Guard the normalization boundaries that could otherwise hide corruption."""

import base64
import unittest
from email import policy
from email.message import EmailMessage

from compare import normalize_email


def observation(message: EmailMessage) -> dict:
    return {
        "raw_base64": base64.b64encode(message.as_bytes(policy=policy.SMTP)).decode(),
        "envelope": {
            "sender": "sender@example.test",
            "recipients": ["reader@example.test"],
        },
    }


class NormalizationTest(unittest.TestCase):
    def test_encoded_words_do_not_hide_structured_header_changes(self):
        def mail(header):
            wire = f"List-Unsubscribe: {header}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBody".encode()
            return normalize_email(
                {
                    "raw_base64": base64.b64encode(wire).decode(),
                    "envelope": {"sender": "sender@example.test", "recipients": []},
                }
            )

        raw = "<https://example.test/unsubscribe>"
        encoded = "=?UTF-8?B?" + base64.b64encode(raw.encode()).decode() + "?="
        self.assertNotEqual(mail(raw), mail(encoded))

    def test_text_attachment_bytes_remain_significant(self):
        def mail(payload):
            value = EmailMessage()
            value.set_content("Body")
            value.add_attachment(
                payload,
                maintype="text",
                subtype="plain",
                filename="notes.txt",
                cte="base64",
            )
            return normalize_email(observation(value))

        self.assertNotEqual(mail(b"line\r\n"), mail(b"line\n"))

    def test_body_transfer_encoding_is_not_significant(self):
        left = EmailMessage()
        right = EmailMessage()
        left.set_content("Ol\u00e1", cte="base64")
        right.set_content("Ol\u00e1", cte="quoted-printable")
        self.assertEqual(
            normalize_email(observation(left)), normalize_email(observation(right))
        )

    def test_multipart_structure_remains_significant(self):
        left = EmailMessage()
        left.set_content("Body")
        right = EmailMessage()
        right.set_content("Body")
        right.make_mixed()
        self.assertNotEqual(
            normalize_email(observation(left)), normalize_email(observation(right))
        )

    def test_nested_parser_defect_is_rejected(self):
        wire = b"Content-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain\r\n\r\nbody\r\n--outer--\r\n"
        value = {
            "raw_base64": base64.b64encode(wire).decode(),
            "envelope": {"sender": "a@example.test", "recipients": []},
        }
        with self.assertRaises(ValueError):
            normalize_email(value)


if __name__ == "__main__":
    unittest.main()
