//// The application owns account mapping. These evidence kinds stay distinct.

import correio/passwordless
import warden

pub type AccountId {
  AccountId(Int)
}

pub type Principal {
  EmailPrincipal(account: AccountId, verified_at_ms: Int)
  OidcPrincipal(issuer: String, subject: String)
}

pub fn from_email(evidence: passwordless.Verified(AccountId)) -> Principal {
  EmailPrincipal(
    passwordless.subject(evidence),
    passwordless.authenticated_at(evidence),
  )
}

pub fn from_oidc(evidence: warden.VerifiedIdentity) -> Principal {
  OidcPrincipal(warden.issuer(evidence), warden.subject(evidence))
}
