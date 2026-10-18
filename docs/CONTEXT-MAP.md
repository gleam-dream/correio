# Context map

## Contexts

- [Delivery](design/delivery/CONTEXT.typ) owns message construction, transports, delivery evidence, capture, and the development mailbox.
- [Passwordless](design/passwordless/CONTEXT.typ) owns challenges, consumption, verification evidence, recovery, and challenge stores.
- [Browser demo](design/demo/CONTEXT.typ) owns the browser journey that composes delivery and verification into one login example.
- [Evidence](design/evidence/CONTEXT.typ) owns oracles, scripted peers, usage examples, benchmarks, and continuous integration.

## Relationships

- Delivery and Passwordless: separate ways. Neither imports the other, and the application composes them.
- Browser demo and Delivery: customer/supplier, with the demo as customer.
- Browser demo and Passwordless: customer/supplier, with the demo as customer.
- Evidence and Delivery: conformist. Evidence adopts the delivery contract as the behavior it judges.
- Evidence and Passwordless: conformist. Evidence adopts the passwordless contract as the behavior it judges.

## Shared terms

- Each term has one owning context. The Browser demo cites Passwordless terms and never redefines them.
