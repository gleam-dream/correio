Application.put_env(:correio_oracles, Oracle.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: 30,
  log: false,
  queue_target: 10_000,
  queue_interval: 10_000,
  timeout: 60_000
)

{:ok, _} = Oracle.Repo.start_link()

for statement <- [
      "CREATE EXTENSION IF NOT EXISTS citext",
      "CREATE TABLE users (id bigserial PRIMARY KEY, email text NOT NULL, hashed_password text, confirmed_at timestamp(0), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL)",
      "CREATE UNIQUE INDEX users_email_index ON users(email)",
      "CREATE TABLE users_tokens (id bigserial PRIMARY KEY, user_id bigint NOT NULL REFERENCES users(id), token bytea NOT NULL, context text NOT NULL, sent_to text, authenticated_at timestamp(0), inserted_at timestamp(0) NOT NULL)",
      "CREATE UNIQUE INDEX users_tokens_context_token_index ON users_tokens(context, token)",
      "CREATE TABLE ash_users (id uuid PRIMARY KEY, email citext NOT NULL UNIQUE)",
      "CREATE TABLE ash_tokens (jti text PRIMARY KEY, subject text NOT NULL, expires_at timestamp(6) NOT NULL, purpose text NOT NULL, extra_data jsonb, created_at timestamp(6) NOT NULL DEFAULT now(), updated_at timestamp(6) NOT NULL DEFAULT now())"
    ] do
  Oracle.Repo.query!(statement)
end

fixtures = "fixtures/email.json" |> File.read!() |> Jason.decode!()

result = %{
  swoosh: Oracle.Email.run(fixtures),
  phoenix: Oracle.Phoenix.run(),
  ash: Oracle.Ash.run()
}

directory = System.get_env("CORREIO_ORACLE_RESULTS", Path.expand("results"))
File.mkdir_p!(directory)
File.write!(Path.join(directory, "upstream.json"), Jason.encode!(result, pretty: true))
IO.puts("Executed Swoosh MIME, Phoenix generated context, and Ash PostgreSQL oracle cases.")
