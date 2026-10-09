# Design coverage

| Repository part                                            | Classification | Design owner                                                                               |
| ---------------------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------ |
| Message values, address parsing, MIME, delivery adapters   | captured       | [Messages and delivery](design/design.typ#messages-and-delivery)                           |
| Capture checkpoints, flow helpers, development mailbox     | captured       | [Development mailbox and flow tests](design/design.typ#development-mailbox-and-flow-tests) |
| Challenge values, verification, attempt budgets, recovery  | captured       | [Passwordless verification](design/design.typ#passwordless-verification)                   |
| Memory and PostgreSQL stores, migrations, cleanup          | captured       | [Storage and runtime ownership](design/design.typ#storage-and-runtime-ownership)           |
| Separate consumer, browser flow, Warden recipe             | captured       | [Application and Warden composition](design/design.typ#application-and-warden-composition) |
| Unit, oracle, transport, database, and benchmark harnesses | captured       | [Evidence and measurement](design/design.typ#evidence-and-measurement)                     |
| Nix, direnv, hooks, formatter, package manifests           | standard       | Conventional development infrastructure                                                    |

- Captured identifies intended ownership. It does not claim that implementation or validation has completed.
