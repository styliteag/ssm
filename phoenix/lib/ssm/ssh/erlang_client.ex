defmodule Ssm.Ssh.ErlangClient do
  @moduledoc """
  Production SSH client on stdlib Erlang `:ssh`/`:ssh_sftp` with one cached
  connection per host_id — port of ssh/asyncssh_client.py, architecture per
  the M0 spike (docs/elixir-phoenix-rewrite.md):

    * direct hosts: pure `:ssh.connect/4`
    * jump chains (`host.jump_via`): a supervised OpenSSH `ssh -N -L` local
      forwarder per destination host (multi-hop via `-J`), because OTP's
      native `tcpip_tunnel_to_server` cannot carry a nested SSH handshake
      (verified broken on OTP 27 and 29)
    * passphrase-protected keys: decrypted once at boot into a private
      tmp dir via `ssh-keygen -p` (OTP cannot decode encrypted
      openssh-key-v1 material natively)

  Host keys are accepted silently — parity with the python stack, which ran
  asyncssh with `known_hosts=None`.

  The GenServer owns only the connection/forwarder registry; channel work
  (exec/sftp) runs in the caller's process against the checked-out
  connection, so concurrent operations against different hosts don't
  serialize. Connects DO serialize through the registry — acceptable for
  SSM's fleet sizes and the price of a race-free cache.
  """

  @behaviour Ssm.Ssh.Client

  use GenServer
  require Logger

  alias Ssm.Ssh.{RemoteFile, Result, Target}

  @gregorian_epoch_offset 62_167_219_200

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## Ssm.Ssh.Client implementation (caller side)

  @impl Ssm.Ssh.Client
  def connect(%Target{} = target) do
    case checkout(target) do
      {:ok, _conn} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl Ssm.Ssh.Client
  def exec(%Target{} = target, command, opts) do
    with {:ok, conn} <- checkout(target) do
      case do_exec(conn, command, Keyword.get(opts, :input), timeout_ms()) do
        {:ok, %Result{}} = ok ->
          ok

        {:error, reason} ->
          invalidate(target.host_id)
          {:error, {:ssh_connect_failed, "ssh exec failed on #{target.name}: #{inspect(reason)}"}}
      end
    end
  end

  @impl Ssm.Ssh.Client
  def read_file(%Target{} = target, path) do
    with_sftp(target, fn sftp ->
      charlist_path = String.to_charlist(path)

      with {:ok, data} <- :ssh_sftp.read_file(sftp, charlist_path, timeout_ms()) do
        mtime =
          case :ssh_sftp.read_file_info(sftp, charlist_path, timeout_ms()) do
            {:ok, info} -> file_info_mtime(info)
            _ -> nil
          end

        {:ok, %RemoteFile{content: to_utf8(data), mtime: mtime}}
      end
    end)
  end

  @impl Ssm.Ssh.Client
  def write_file(%Target{} = target, path, content) do
    with_sftp(target, fn sftp ->
      case :ssh_sftp.write_file(sftp, String.to_charlist(path), content, timeout_ms()) do
        :ok -> :ok
        {:error, _} = error -> error
      end
    end)
  end

  @impl Ssm.Ssh.Client
  def close do
    GenServer.call(__MODULE__, :close, :infinity)
  end

  @doc "Drop the cached connection (and forwarder) for a host."
  def invalidate(host_id) do
    GenServer.call(__MODULE__, {:invalidate, host_id}, :infinity)
  end

  defp checkout(target) do
    GenServer.call(__MODULE__, {:checkout, target}, checkout_timeout())
  catch
    :exit, reason ->
      {:error, {:ssh_connect_failed, "ssh registry unavailable: #{inspect(reason)}"}}
  end

  defp with_sftp(target, fun) do
    with {:ok, conn} <- checkout(target) do
      case :ssh_sftp.start_channel(conn, timeout: timeout_ms()) do
        {:ok, sftp} ->
          try do
            case fun.(sftp) do
              {:error, reason} ->
                {:error,
                 {:ssh_connect_failed, "ssh sftp failed on #{target.name}: #{inspect(reason)}"}}

              other ->
                other
            end
          after
            :ssh_sftp.stop_channel(sftp)
          end

        {:error, reason} ->
          invalidate(target.host_id)

          {:error,
           {:ssh_connect_failed, "ssh sftp channel failed on #{target.name}: #{inspect(reason)}"}}
      end
    end
  end

  ## GenServer (connection registry)

  @impl GenServer
  def init(opts) do
    ssh_config = Application.get_env(:ssm, :ssh, [])
    :ok = ensure_ssh_started()

    key_dir =
      Keyword.get_lazy(opts, :key_dir, fn ->
        prepare_key_dir(
          Keyword.get(ssh_config, :key_file, "keys/id_ssm"),
          Keyword.get(ssh_config, :key_passphrase)
        )
      end)

    state = %{
      key_dir: key_dir,
      conns: %{},
      forwarders: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:checkout, target}, _from, state) do
    case fetch_live(state.conns, target.host_id) do
      {:ok, conn} ->
        {:reply, {:ok, conn}, state}

      :error ->
        case open_connection(target, state) do
          {:ok, conn, state} ->
            {:reply, {:ok, conn}, put_in(state.conns[target.host_id], conn)}

          {:error, reason, state} ->
            {:reply,
             {:error,
              {:ssh_connect_failed, "ssh connect failed for #{target.name}: #{inspect(reason)}"}},
             state}
        end
    end
  end

  def handle_call({:invalidate, host_id}, _from, state) do
    {:reply, :ok, drop_host(state, host_id)}
  end

  def handle_call(:close, _from, state) do
    state =
      state.conns
      |> Map.keys()
      |> Enum.reduce(state, &drop_host(&2, &1))

    {:reply, :ok, state}
  end

  # Forwarder OS processes report exits here; drop their host entry.
  @impl GenServer
  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Enum.find(state.forwarders, fn {_id, fwd} -> fwd.port == port end) do
      {host_id, _fwd} ->
        Logger.warning("ssh.forwarder_exited host_id=#{host_id} status=#{status}")
        {:noreply, drop_host(state, host_id)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fetch_live(conns, host_id) do
    with {:ok, conn} <- Map.fetch(conns, host_id),
         true <- connection_alive?(conn) do
      {:ok, conn}
    else
      _ -> :error
    end
  end

  defp connection_alive?(conn) do
    match?([_ | _], :ssh.connection_info(conn, [:client_version]))
  catch
    _kind, _reason -> false
  end

  defp open_connection(%Target{jump_target: nil} = target, state) do
    case ssh_connect(target.address, target.port, target.username, state.key_dir) do
      {:ok, conn} -> {:ok, conn, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open_connection(%Target{} = target, state) do
    with {:ok, local_port, state} <- ensure_forwarder(target, state),
         {:ok, conn} <- ssh_connect("127.0.0.1", local_port, target.username, state.key_dir) do
      {:ok, conn, state}
    else
      {:error, reason} -> {:error, reason, drop_host(state, target.host_id)}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp ssh_connect(address, port, username, key_dir) do
    :ssh.connect(
      String.to_charlist(address),
      port,
      [
        user: String.to_charlist(username),
        user_dir: String.to_charlist(key_dir),
        silently_accept_hosts: true,
        user_interaction: false,
        auth_methods: ~c"publickey",
        connect_timeout: timeout_ms()
      ],
      timeout_ms()
    )
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  ## OpenSSH local forwarder for jump chains

  defp ensure_forwarder(target, state) do
    case state.forwarders[target.host_id] do
      %{local_port: local_port, port: port} ->
        if port_alive?(port) do
          {:ok, local_port, state}
        else
          ensure_forwarder(target, drop_host(state, target.host_id))
        end

      nil ->
        start_forwarder(target, state)
    end
  end

  defp start_forwarder(target, state) do
    # jump_target is the innermost hop; walking jump_target links yields the
    # chain inner→outer. OpenSSH wants the FINAL -J list outer→inner and the
    # innermost hop as the command's destination host.
    [innermost | rest_outer] = jump_chain(target.jump_target)

    with {:ok, ssh_bin} <- find_openssh(),
         {:ok, local_port} <- free_local_port() do
      jump_args =
        case rest_outer do
          [] ->
            []

          outer ->
            list =
              outer
              |> Enum.reverse()
              |> Enum.map_join(",", &"#{&1.username}@#{&1.address}:#{&1.port}")

            ["-J", list]
        end

      args =
        [
          "-N",
          "-L",
          "127.0.0.1:#{local_port}:#{target.address}:#{target.port}",
          "-i",
          key_file_path(state.key_dir),
          "-p",
          Integer.to_string(innermost.port),
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "-o",
          "BatchMode=yes",
          "-o",
          "ExitOnForwardFailure=yes",
          "-o",
          "ConnectTimeout=#{max(div(timeout_ms(), 1000), 1)}"
        ] ++ jump_args ++ ["#{innermost.username}@#{innermost.address}"]

      port = Port.open({:spawn_executable, ssh_bin}, [:binary, :exit_status, args: args])

      case await_forwarder(local_port, timeout_ms()) do
        :ok ->
          state = put_in(state.forwarders[target.host_id], %{port: port, local_port: local_port})
          {:ok, local_port, state}

        {:error, reason} ->
          safe_port_close(port)
          {:error, {:forwarder_not_ready, reason}, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp jump_chain(nil), do: []
  defp jump_chain(%Target{} = jump), do: [jump | jump_chain(jump.jump_target)]

  defp find_openssh do
    case System.find_executable("ssh") do
      nil -> {:error, :openssh_client_not_installed}
      path -> {:ok, path}
    end
  end

  defp free_local_port do
    with {:ok, socket} <- :gen_tcp.listen(0, ip: {127, 0, 0, 1}),
         {:ok, {_addr, port}} <- :inet.sockname(socket) do
      :gen_tcp.close(socket)
      {:ok, port}
    end
  end

  defp await_forwarder(local_port, budget_ms) when budget_ms <= 0,
    do: {:error, {:listen_timeout, local_port}}

  defp await_forwarder(local_port, budget_ms) do
    case :gen_tcp.connect({127, 0, 0, 1}, local_port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(250)
        await_forwarder(local_port, budget_ms - 250)
    end
  end

  defp port_alive?(port), do: Port.info(port) != nil

  defp safe_port_close(port) do
    if port_alive?(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp drop_host(state, host_id) do
    case state.conns[host_id] do
      nil -> :ok
      conn -> catch_all(fn -> :ssh.close(conn) end)
    end

    case state.forwarders[host_id] do
      nil -> :ok
      %{port: port} -> safe_port_close(port)
    end

    %{
      state
      | conns: Map.delete(state.conns, host_id),
        forwarders: Map.delete(state.forwarders, host_id)
    }
  end

  defp catch_all(fun) do
    fun.()
  catch
    _kind, _reason -> :ok
  end

  ## Key material

  # Copy (and, when a passphrase is configured, decrypt via ssh-keygen -p)
  # the operator's key into a private dir laid out the way Erlang's
  # ssh_file expects (id_ed25519 / id_rsa / id_ecdsa).
  defp prepare_key_dir(key_file, passphrase) do
    dir = Path.join(System.tmp_dir!(), "ssm-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    source = Path.expand(key_file)

    case File.read(source) do
      {:ok, _} ->
        work = Path.join(dir, "key.work")
        File.cp!(source, work)
        File.chmod!(work, 0o600)
        maybe_decrypt!(work, passphrase)

        material = File.read!(work)

        for name <- standard_key_names(material) do
          dest = Path.join(dir, name)
          File.write!(dest, material)
          File.chmod!(dest, 0o600)
        end

        File.rm!(work)

      {:error, reason} ->
        Logger.warning(
          "ssh.key_unreadable file=#{source} reason=#{inspect(reason)} — " <>
            "SSH operations will fail until SSH_KEY points at a readable key"
        )
    end

    dir
  end

  defp maybe_decrypt!(_path, nil), do: :ok
  defp maybe_decrypt!(_path, ""), do: :ok

  defp maybe_decrypt!(path, passphrase) do
    case System.cmd("ssh-keygen", ["-p", "-P", passphrase, "-N", "", "-f", path],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, status} ->
        raise "ssh-keygen -p failed (status #{status}) decrypting SSH_KEY: #{String.trim(out)}"
    end
  end

  # Erlang's ssh_file only probes the conventional file names; pick them from
  # the key material (openssh-key-v1 blobs embed the algorithm string).
  defp standard_key_names(material) do
    decoded =
      material
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "-----"))
      |> Enum.join()
      |> Base.decode64()
      |> case do
        {:ok, bin} -> bin
        :error -> ""
      end

    haystack = material <> decoded

    cond do
      String.contains?(haystack, "ssh-ed25519") -> ["id_ed25519"]
      String.contains?(material, "BEGIN RSA PRIVATE KEY") -> ["id_rsa"]
      String.contains?(haystack, "ssh-rsa") -> ["id_rsa"]
      String.contains?(haystack, "ecdsa-sha2") -> ["id_ecdsa"]
      String.contains?(material, "BEGIN EC PRIVATE KEY") -> ["id_ecdsa"]
      true -> ["id_ed25519", "id_rsa", "id_ecdsa"]
    end
  end

  defp key_file_path(key_dir) do
    ["id_ed25519", "id_rsa", "id_ecdsa"]
    |> Enum.map(&Path.join(key_dir, &1))
    |> Enum.find(&File.exists?/1)
    |> Kernel.||(Path.join(key_dir, "id_ed25519"))
  end

  ## exec plumbing (caller side)

  defp do_exec(conn, command, input, timeout) do
    with {:ok, chan} <- :ssh_connection.session_channel(conn, timeout),
         :success <- :ssh_connection.exec(conn, chan, String.to_charlist(command), timeout),
         :ok <- send_input(conn, chan, input, timeout) do
      collect(conn, chan, timeout, [], [], 0)
    else
      :failure -> {:error, :channel_exec_failure}
      {:error, _} = error -> error
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp send_input(_conn, _chan, nil, _timeout), do: :ok

  defp send_input(conn, chan, input, timeout) do
    with :ok <- :ssh_connection.send(conn, chan, input, timeout) do
      :ssh_connection.send_eof(conn, chan)
    end
  end

  defp collect(conn, chan, timeout, stdout, stderr, status) do
    receive do
      {:ssh_cm, ^conn, {:data, ^chan, 0, data}} ->
        collect(conn, chan, timeout, [stdout, data], stderr, status)

      {:ssh_cm, ^conn, {:data, ^chan, 1, data}} ->
        collect(conn, chan, timeout, stdout, [stderr, data], status)

      {:ssh_cm, ^conn, {:exit_status, ^chan, exit_status}} ->
        collect(conn, chan, timeout, stdout, stderr, exit_status)

      {:ssh_cm, ^conn, {:eof, ^chan}} ->
        collect(conn, chan, timeout, stdout, stderr, status)

      {:ssh_cm, ^conn, {:exit_signal, ^chan, _signal, _msg, _lang}} ->
        collect(conn, chan, timeout, stdout, stderr, status)

      {:ssh_cm, ^conn, {:closed, ^chan}} ->
        {:ok,
         %Result{
           stdout: to_utf8(IO.iodata_to_binary(stdout)),
           stderr: to_utf8(IO.iodata_to_binary(stderr)),
           exit_code: status
         }}
    after
      timeout -> {:error, :exec_timeout}
    end
  end

  defp file_info_mtime(info) when is_tuple(info) do
    case elem(info, 5) do
      {{_, _, _}, {_, _, _}} = datetime ->
        :calendar.datetime_to_gregorian_seconds(datetime) - @gregorian_epoch_offset

      seconds when is_integer(seconds) ->
        seconds

      _ ->
        nil
    end
  end

  defp to_utf8(data) when is_binary(data) do
    if String.valid?(data), do: data, else: inspect(data)
  end

  defp to_utf8(data), do: to_string(data)

  defp ensure_ssh_started do
    case :ssh.start() do
      :ok -> :ok
      {:error, {:already_started, :ssh}} -> :ok
    end
  end

  defp timeout_ms do
    seconds =
      Application.get_env(:ssm, :ssh, [])
      |> Keyword.get(:timeout_seconds, 120)

    seconds * 1000
  end

  defp checkout_timeout, do: timeout_ms() + 5_000
end
