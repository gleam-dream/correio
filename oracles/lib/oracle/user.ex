defmodule Oracle.User do
  use Ash.Resource,
    domain: Oracle.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  postgres do
    table("ash_users")
    repo(Oracle.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:email, :ci_string, allow_nil?: false, public?: true)
  end

  identities do
    identity(:email, [:email])
  end

  actions do
    defaults([:read, create: [:email]])
  end

  authentication do
    session_identifier(:jti)

    tokens do
      enabled?(true)
      store_all_tokens?(true)
      token_resource(Oracle.Token)
      signing_secret(fn _, _ -> {:ok, "local-oracle-only-not-a-deployment-secret-0123456789"} end)
    end

    strategies do
      magic_link do
        identity_field(:email)
        registration_enabled?(false)
        single_use_token?(true)
        require_interaction?(true)
        sender(fn _, _, _ -> :ok end)
      end
    end
  end
end
