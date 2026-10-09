defmodule Oracle.Phoenix do
  @moduledoc "Executes unmodified Phoenix authentication templates against PostgreSQL."

  def load_templates do
    schema = %{
      module: Oracle.Accounts.User,
      alias: User,
      table: "users",
      singular: "user",
      human_singular: "User",
      route_prefix: "/users",
      binary_id: false,
      timestamp_type: :utc_datetime,
      repo: Oracle.Repo
    }

    bindings = [
      schema: schema,
      context: %{module: Oracle.Accounts},
      datetime_module: DateTime,
      datetime_now: "DateTime.utc_now(:second)",
      hashing_library: %{name: :bcrypt, module: Bcrypt}
    ]

    for file <- ["schema.ex.eex", "schema_token.ex.eex"] do
      file |> template(bindings) |> Code.compile_string(file)
    end

    context = template("context_functions.ex.eex", bindings)

    Code.compile_string("""
    defmodule Oracle.Accounts do
      import Ecto.Query
      alias Oracle.Repo
      #{context}
    end
    """)
  end

  def run do
    load_templates()
    cases = ["valid", "reuse", "expired", "wrong_purpose", "wrong_destination"]
    Map.new(cases, &{&1, run_case(&1)})
  end

  defp template(file, bindings) do
    EEx.eval_file(Path.join("vendor/phoenix", file), bindings)
  end

  defp run_case(name) do
    user =
      Oracle.Repo.insert!(
        struct(Oracle.Accounts.User,
          email: name <> "@example.test",
          confirmed_at: DateTime.utc_now(:second)
        )
      )

    purpose = if name == "wrong_purpose", do: "change:old@example.test", else: "login"
    {answer, token} = apply(Oracle.Accounts.UserToken, :build_email_token, [user, purpose])
    token = Oracle.Repo.insert!(token)

    case name do
      "expired" ->
        Oracle.Repo.query!(
          "UPDATE users_tokens SET inserted_at = now() - interval '16 minutes' WHERE id = $1",
          [token.id]
        )

      "wrong_destination" ->
        Oracle.Repo.query!("UPDATE users SET email = 'changed@example.test' WHERE id = $1", [
          user.id
        ])

      "reuse" ->
        {:ok, _} = apply(Oracle.Accounts, :login_user_by_magic_link, [answer])

      _ ->
        :ok
    end

    case apply(Oracle.Accounts, :login_user_by_magic_link, [answer]) do
      {:ok, _} -> "accepted"
      {:error, :not_found} -> "rejected"
    end
  end
end
