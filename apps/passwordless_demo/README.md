# Passwordless browser consumer

[![CI](https://github.com/gleam-dream/correio/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/correio/actions/workflows/ci.yml)
[![correio on Hex](https://img.shields.io/hexpm/v/correio?label=Hex%3A%20correio)](https://hex.pm/packages/correio)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

- A local executable example of email login that composes Correio delivery and verification. It is not a deployed authentication application.
- The application owns its native `AccountId`, account policy, browser state, sessions, and session publication.
- `src/usage` holds one runnable example per usage topic, run by `test/usage_test.gleam`. `identity.gleam` maps Correio email evidence and Hellhound OIDC identity into distinct principal variants. `readme_examples.gleam` compiles the root README examples.
- Browser behavior, bounds, and ownership are specified in the [browser demo design](../../docs/design/design-layer.pdf).

## Run

```sh
# From the Correio repository root.
nix develop -c scripts/with-postgres.sh sh -c 'cd apps/passwordless_demo && gleam test'
```

## Try it

```sh
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```

- The entry point uses memory storage, enables the development mailbox, and prints both local URLs. It needs no database or credentials.
- Request a link for `alice@example.com`, open the mailbox in another tab, copy the plain-text URL into the same browser, and confirm the form.
- Stop with Ctrl-C. All local mail, challenges, and sessions disappear.

## Browser check

```sh
nix develop -c scripts/browser-e2e
```
