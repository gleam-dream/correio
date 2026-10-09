defmodule Oracle.Ash do
  @moduledoc "Real, separately committed PostgreSQL magic-link redemptions."
  @count 24

  def run do
    Enum.map(1..3, &run_round/1)
  end

  defp run_round(round) do
    user =
      Oracle.User
      |> Ash.Changeset.for_create(:create, %{email: "race#{round}@example.test"})
      |> Ash.create!()

    strategy = AshAuthentication.Info.strategy!(Oracle.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
    parent = self()

    tasks =
      for _ <- 1..@count do
        Task.async(fn ->
          Oracle.Repo.checkout(fn ->
            %{rows: [[backend]]} = Oracle.Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), backend})

            receive do
              :go ->
                AshAuthentication.Strategy.MagicLink.Actions.sign_in(
                  strategy,
                  %{"token" => token},
                  []
                )
            after
              30_000 -> raise "race barrier timed out"
            end
          end)
        end)
      end

    backends =
      for _ <- 1..@count do
        receive do
          {:ready, _pid, backend} -> backend
        after
          30_000 -> raise "database checkout barrier timed out"
        end
      end

    true = length(Enum.uniq(backends)) == @count
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 60_000)
    successes = Enum.count(results, &match?({:ok, _}, &1))
    errors = for {:error, error} <- results, do: error
    conflicts = Enum.count(errors, &conflict?/1)
    1 = successes
    23 = length(errors)
    true = conflicts > 0

    {:error, _} =
      AshAuthentication.Strategy.MagicLink.Actions.sign_in(strategy, %{"token" => token}, [])

    %{
      round: round,
      attempts: @count,
      successes: successes,
      rejections: length(errors),
      revocation_conflicts: conflicts,
      backend_ids: backends
    }
  end

  defp conflict?(%AshAuthentication.Errors.InvalidToken{type: :revocation}), do: true

  defp conflict?(error) when is_map(error) do
    (List.wrap(Map.get(error, :errors)) ++ List.wrap(Map.get(error, :caused_by)))
    |> Enum.any?(&conflict?/1)
  end

  defp conflict?(_), do: false
end
