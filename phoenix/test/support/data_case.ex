defmodule Ssm.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  SQLite: database tests must be `async: false` (see `setup_sandbox/1`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Ssm.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Ssm.DataCase
    end
  end

  setup tags do
    Ssm.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox for `async: false` tests only.

  SQLite has a single writer, and every sandboxed test runs inside one
  long DEFERRED transaction. Two async tests deadlock when one holds the
  write lock and the other, after a read, upgrades to write: SQLite returns
  `Database busy` at once, without waiting `busy_timeout`. Async tests
  therefore get no connection: a database call there fails with
  `DBConnection.OwnershipError`. Use `async: false` for tests that touch
  the database.
  """
  def setup_sandbox(tags) do
    unless tags[:async] do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Ssm.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
