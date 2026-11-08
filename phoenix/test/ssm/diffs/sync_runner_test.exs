defmodule Ssm.Diffs.SyncRunnerTest.RaisingClient do
  @moduledoc false
  def connect(_target), do: raise("boom")
  def exec(_target, _command, _opts), do: raise("boom")
  def read_file(_target, _path), do: raise("boom")
  def write_file(_target, _path, _content), do: raise("boom")
  def probe_host_key(_target, _opts), do: raise("boom")
  def close, do: :ok
end

defmodule Ssm.Diffs.SyncRunnerTest do
  @moduledoc """
  `Ssm.Diffs.SyncRunner` beyond the diff page (see `SsmWeb.DiffLiveTest`
  "manual sync lifecycle"): a crashing sync is still audited and frees its
  host.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs.SyncRunner
  alias Ssm.Diffs.SyncRunnerTest.RaisingClient

  test "a sync that crashes is audited as failed and the host is idle again" do
    host = host_fixture(%{name: "crashy"})

    assert {:ok, %{results: [{%{id: id}, {:error, {:crashed, "boom"}}}], busy: []}} =
             SyncRunner.run([host], "tester", client: RaisingClient)

    assert id == host.id
    assert SyncRunner.status(host.id) == :idle

    assert [entry] = Enum.filter(Ssm.Activity.list(), &(&1.target == "crashy"))
    assert {entry.action, entry.actor_username} == {"sync_failed", "tester"}
    assert Ssm.Activity.details(entry)["error"] == "boom"
  end

  test "no hosts: nothing runs" do
    assert SyncRunner.run([], "tester") == {:ok, %{results: [], busy: []}}
  end
end
