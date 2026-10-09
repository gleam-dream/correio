defmodule Oracle.Token do
  use Ash.Resource,
    domain: Oracle.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table("ash_tokens")
    repo(Oracle.Repo)
  end
end
