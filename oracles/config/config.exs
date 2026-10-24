import Config

config :logger, level: :warning
config :swoosh, :api_client, false
config :correio_oracles, ash_domains: [Oracle.Domain], ecto_repos: [Oracle.Repo]
config :ash, :read_action_after_action_hooks_in_order?, true
config :ash, :default_string_length_count, :codepoints
config :ash_authentication, :suppress_sensitive_field_warnings?, true
config :bcrypt_elixir, :log_rounds, 4
