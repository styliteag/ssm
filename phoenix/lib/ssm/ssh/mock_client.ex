defmodule Ssm.Ssh.MockClient do
  @moduledoc """
  Scriptable in-memory `Ssm.Ssh.Client` for tests — port of ssh/mock.py.
  Start per test with `start_supervised!(Ssm.Ssh.MockClient)`, script
  files/exec responses, then assert on the recorded calls.
  """

  @behaviour Ssm.Ssh.Client

  use Agent

  alias Ssm.Ssh.{RemoteFile, Result}

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
  end

  defp initial_state do
    %{
      files: %{},
      exec_responses: %{},
      default_exec: nil,
      connect_failures: MapSet.new(),
      connect_calls: [],
      exec_calls: [],
      exec_inputs: [],
      read_calls: [],
      write_calls: [],
      closed: false
    }
  end

  ## Scripting API

  def set_file(host_id, path, content, mtime \\ nil) do
    file = %RemoteFile{content: content, mtime: mtime}
    Agent.update(__MODULE__, &put_in(&1, [:files, {host_id, path}], file))
  end

  def set_exec(host_id, command, %Result{} = result) do
    Agent.update(__MODULE__, &put_in(&1, [:exec_responses, {host_id, command}], result))
  end

  def set_default_exec(%Result{} = result) do
    Agent.update(__MODULE__, &%{&1 | default_exec: result})
  end

  def fail_connect(host_id) do
    Agent.update(__MODULE__, &%{&1 | connect_failures: MapSet.put(&1.connect_failures, host_id)})
  end

  def calls do
    Agent.get(__MODULE__, fn state ->
      %{
        connect: Enum.reverse(state.connect_calls),
        exec: Enum.reverse(state.exec_calls),
        exec_inputs: Enum.reverse(state.exec_inputs),
        read: Enum.reverse(state.read_calls),
        write: Enum.reverse(state.write_calls),
        closed: state.closed
      }
    end)
  end

  ## Ssm.Ssh.Client implementation

  @impl true
  def connect(target) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | connect_calls: [target.host_id | state.connect_calls]}

      if MapSet.member?(state.connect_failures, target.host_id) do
        {{:error, {:ssh_connect_failed, "mock: connect failed for host #{target.host_id}"}},
         state}
      else
        {:ok, state}
      end
    end)
  end

  @impl true
  def exec(target, command, opts) do
    with :ok <- connect(target) do
      input = Keyword.get(opts, :input)

      Agent.get_and_update(__MODULE__, fn state ->
        state = %{
          state
          | exec_calls: [{target.host_id, command} | state.exec_calls],
            exec_inputs: [{target.host_id, command, input} | state.exec_inputs]
        }

        result =
          Map.get(state.exec_responses, {target.host_id, command}) ||
            state.default_exec ||
            %Result{}

        {{:ok, result}, state}
      end)
    end
  end

  @impl true
  def read_file(target, path) do
    with :ok <- connect(target) do
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | read_calls: [{target.host_id, path} | state.read_calls]}

        case Map.fetch(state.files, {target.host_id, path}) do
          {:ok, file} ->
            {{:ok, file}, state}

          :error ->
            {{:error,
              {:ssh_connect_failed,
               "mock: no file scripted for host=#{target.host_id} path=#{inspect(path)}"}}, state}
        end
      end)
    end
  end

  @impl true
  def write_file(target, path, content) do
    with :ok <- connect(target) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | write_calls: [{target.host_id, path, content} | state.write_calls],
            files: Map.put(state.files, {target.host_id, path}, %RemoteFile{content: content})
        }
      end)
    end
  end

  @impl true
  def close do
    Agent.update(__MODULE__, &%{&1 | closed: true})
  end
end
