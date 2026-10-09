defmodule Oracle.Repo do
  use AshPostgres.Repo, otp_app: :correio_oracles, warn_on_missing_ash_functions?: false
  def installed_extensions, do: ["citext"]
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
