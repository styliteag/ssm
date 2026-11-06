defmodule Ssm.Mctl.PrunerTest do
  use Ssm.DataCase, async: false

  alias MctlContract.Idempotency.Record
  alias MctlContract.Jobs.Ecto, as: Jobs
  alias MctlContract.Jobs.Job

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(:second), -n * 86_400)

  test "run/0 prunes finished jobs older than 30 days and idempotency keys older than 24 h" do
    {:ok, old} = Jobs.create("create_host", "1")

    {:ok, _} =
      old |> Ecto.Changeset.change(state: "succeeded", finished_at: days_ago(31)) |> Repo.update()

    {:ok, recent} = Jobs.create("create_host", "2")

    {:ok, _} =
      recent |> Ecto.Changeset.change(state: "failed", finished_at: days_ago(1)) |> Repo.update()

    {:ok, running} = Jobs.create("create_host", "3")

    for {key, at} <- [{"old", days_ago(2)}, {"new", DateTime.utc_now(:second)}] do
      Repo.insert!(%Record{token_id: "1", key: key, request_hash: "h", inserted_at: at})
    end

    assert %{jobs: 1, idempotency: 1} = Ssm.Mctl.Pruner.run()

    assert Repo.aggregate(Job, :count) == 2
    assert {:ok, _} = Jobs.get(running.id)
    assert [%{key: "new"}] = Repo.all(Record)
  end

  test "the periodic process ticks without crashing" do
    pid = start_supervised!({Ssm.Mctl.Pruner, interval: :timer.hours(1)})
    send(pid, :prune)
    assert %{} = :sys.get_state(pid)
  end
end
