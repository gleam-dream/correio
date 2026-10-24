//// Conservative ASCII mailboxes with Unicode display names.
//// Quoted local parts, address literals, and SMTPUTF8 mailboxes are refused.

import gleam/option.{type Option, None, Some}

pub opaque type Address {
  Address(email: String, name: Option(String))
}

pub type AddressError {
  InvalidMailbox
  InvalidDisplayName
}

pub fn parse(value: String) -> Result(Address, AddressError) {
  case parse_mailbox(value) {
    Ok(email) -> Ok(Address(email, None))
    Error(Nil) -> Error(InvalidMailbox)
  }
}

pub fn named(address: Address, name: String) -> Result(Address, AddressError) {
  case safe_header(name) {
    True -> Ok(Address(address.email, Some(name)))
    False -> Error(InvalidDisplayName)
  }
}

pub fn email(address: Address) -> String {
  address.email
}

pub fn name(address: Address) -> Option(String) {
  address.name
}

@external(erlang, "correio_mail_ffi", "parse_mailbox")
fn parse_mailbox(value: String) -> Result(String, Nil)

@external(erlang, "correio_mail_ffi", "safe_header")
fn safe_header(value: String) -> Bool
