defmodule Ssm.Ssh.MockClient do
  @moduledoc """
  Scriptable in-memory `Ssm.Ssh.Client` for tests — port of ssh/mock.py.
  Start per test with `start_supervised!(Ssm.Ssh.MockClient)`, script
  files/exec responses, then assert on the recorded calls.
  """

  @behaviour Ssm.Ssh.Client

  use Agent

  alias Ssm.Ssh.{HostKey, RemoteFile, Result}

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
  end

  defp initial_state do
    %{
      files: %{},
      exec_responses: %{},
      default_exec: nil,
      connect_failures: MapSet.new(),
      host_keys: %{},
      default_host_keys: [],
      probe_auth_failures: 0,
      probe_calls: [],
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

  @doc "Script the public host keys (OpenSSH lines) a host offers to probes."
  def set_host_keys(host_id, public_keys) when is_list(public_keys) do
    Agent.update(__MODULE__, &put_in(&1, [:host_keys, host_id], public_keys))
  end

  @doc "Host keys offered by every host without its own `set_host_keys/2`."
  def set_default_host_keys(public_keys) when is_list(public_keys) do
    Agent.update(__MODULE__, &%{&1 | default_host_keys: public_keys})
  end

  @doc """
  The next `count` probes that pass the host-key check fail authentication
  (any host), as a real probe does until ssm's key is authorized on the
  host. `0` clears it.
  """
  def fail_probe_auth(count) when is_integer(count) and count >= 0 do
    Agent.update(__MODULE__, &%{&1 | probe_auth_failures: count})
  end

  def fail_connect(host_id) do
    Agent.update(__MODULE__, &%{&1 | connect_failures: MapSet.put(&1.connect_failures, host_id)})
  end

  def calls do
    Agent.get(__MODULE__, fn state ->
      %{
        connect: Enum.reverse(state.connect_calls),
        probe: Enum.reverse(state.probe_calls),
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
  def probe_host_key(target, opts) do
    with :ok <- connect(target) do
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | probe_calls: [{target.host_id, opts} | state.probe_calls]}
        keys = Map.get(state.host_keys, target.host_id, state.default_host_keys)
        target |> probe_answer(keys, opts) |> probe_auth(state)
      end)
    end
  end

  defp probe_answer(target, [], _opts),
    do: {:error, {:ssh_connect_failed, "mock: no host key scripted for host #{target.host_id}"}}

  defp probe_answer(_target, keys, opts) do
    prefer = Keyword.get(opts, :prefer)
    line = Enum.find(keys, hd(keys), &String.starts_with?(&1, "#{prefer} "))
    {:ok, public_key} = HostKey.public_key(line)
    {:ok, fingerprint} = HostKey.fingerprint(public_key)
    offered = %{public_key: public_key, fingerprint: fingerprint}
    expect = Keyword.get(opts, :expect)

    if HostKey.pinned?(expect) and not HostKey.matches?(expect, fingerprint),
      do: {:error, {:host_key_mismatch, offered}},
      else: {:ok, offered}
  end

  # Like the real handshake: the host key is checked before authentication.
  defp probe_auth({:ok, _offered}, %{probe_auth_failures: n} = state) when n > 0 do
    {{:error,
      {:ssh_connect_failed, "mock: Unable to connect using the available authentication methods"}},
     %{state | probe_auth_failures: n - 1}}
  end

  defp probe_auth(answer, state), do: {answer, state}

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
            Map.get(state.exec_responses, {target.host_id, listing_base(command)}) ||
            state.default_exec ||
            %Result{}

        {{:ok, result}, state}
      end)
    end
  end

  # a listing stub ("… get_ssh_keyfiles") also answers the listing that
  # names logins to check ("… get_ssh_keyfiles a b")
  defp listing_base(command) do
    case String.split(command, " get_ssh_keyfiles ", parts: 2) do
      [base, _logins] -> base <> " get_ssh_keyfiles"
      _ -> command
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
