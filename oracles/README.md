# Oracle comparisons

- Run `nix develop -c scripts/oracles` from the package root.
- The command creates disposable PostgreSQL, executes pinned upstream implementations, executes Correio, and fails on semantic differences.
- The Mix lock retains all transitive dependency versions. Swoosh and AshAuthentication use exact Git revisions. Phoenix templates remain byte-for-byte copies of the pinned source and are checked against `manifest.json`.
- `CORREIO_ORACLE_RESULTS` selects the output directory. `receipt.json` includes the platform, source revisions, Correio repository source digest, and scenario counts. Raw authentication answers are never serialized.

## Compared behavior

- Swoosh constructs and submits the retained JSON email fixtures through its actual SMTP adapter and `mimemail`. A loopback peer records actual MAIL FROM, RCPT TO, and DATA commands; the harness does not reimplement Swoosh envelope selection. Python's standard MIME parser independently normalizes both implementations. Recipient roles, custom headers, subject, charset, multipart topology, decoded body and attachment bytes, disposition, filename, and content identifiers remain significant.
- Structured List-Unsubscribe fields retain their raw unfolded syntax. RFC 2047 decoding cannot hide malformed URL-list headers. Other custom fields retain their parsed values.
- The SMTP capture removes dot stuffing and exactly one CRLF appended by pinned `gen_smtp` before its DATA terminator. It preserves authored trailing bytes. The MIME comparison judges renderer output; this framing rule does not claim that downstream storage preserves message bytes unchanged.
- Generated dates, message identifiers, boundaries, header folding, recipient ordering, and equivalent transfer encodings are ignored. CRLF and LF are equivalent in decoded text bodies. An absent body-part disposition is equivalent to inline when no attachment filename or content identifier exists.
- Phoenix's actual generated schema, token schema, and context execute against PostgreSQL. Comparison includes acceptance, sequential reuse refusal, expiry, wrong purpose, and destination mismatch. Correio's configurable expiry is not required to equal Phoenix's fifteen-minute default.
- AshAuthentication's actual magic-link strategy runs three races of twenty-four redemptions. Every worker holds a separate PostgreSQL connection before the barrier opens. Exactly one succeeds. At least one losing Ash worker must report an actual revocation conflict. Backend identifiers are retained as connection evidence.

## Limits

- Phoenix account confirmation, password-registration interactions, browser policy, session publication, and account linking are application policy outside the comparison.
- Ash registration and password strategies are outside the comparison. Its upstream success does not establish Correio correctness; Correio must independently pass the same observable single-use result.
- Email fixtures exercise message semantics. They do not establish SMTP reliability, inbox delivery, all provider options, internationalized envelope support, or all MIME media types.
- Correio and Swoosh use different MIME encoders. SMTP transport may share `gen_smtp`; transport fault tests remain separate evidence.
- Authentication random values are never compared. Only outcomes and connection counts are compared. No real provider or existing user database is used.
- The pinned Ash 3.33.4 dependency has published advisories affecting bulk private action arguments and unsafe atom filtering. This isolated oracle uses neither path. These Elixir dependencies are absent from Correio's runtime dependency graph.
