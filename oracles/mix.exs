defmodule CorreioOracles.MixProject do
  use Mix.Project

  def project do
    [
      app: :correio_oracles,
      version: "0.1.0",
      elixir: "~> 1.17",
      consolidate_protocols: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :ssl]]

  defp deps do
    [
      {:swoosh,
       git: "https://github.com/swoosh/swoosh.git",
       ref: "13f10492615cbb9c29cc974f14e18e1c26a551b5"},
      {:ash_authentication,
       git: "https://github.com/team-alembic/ash_authentication.git",
       ref: "d6b2be35cf8f0b8ab84e7a934cfb0d91de0a3c17"},
      {:ash_postgres, "== 2.13.0"},
      {:ash, "== 3.33.4", override: true},
      {:gen_smtp, "== 1.3.0"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:bcrypt_elixir, "~> 3.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
