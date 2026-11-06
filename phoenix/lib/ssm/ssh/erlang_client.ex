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

  Host keys are pinned (ADR-0008). Every connect verifies the server's key
  against the target's `host_key_fingerprint` inside `Ssm.Ssh.HostKeyCb`
  during key exchange — a different key aborts the handshake before
  authentication, an unpinned host is refused without connecting.
  `probe_host_key/2` is the only path that accepts an unknown key (trust on
  first use); it never registers its connection. Jump hops are verified by
  OpenSSH itself: each forwarder gets a generated `ssh_config` +
  `known_hosts` (the hops' pinned public keys, `StrictHostKeyChecking yes`).

  The GenServer owns only the connection/forwarder registry; channel work
  (exec/sftp) AND the connect handshakes run in the caller's process, so
  neither operations nor connects serialize across hosts — a dead host
  timing out (up to SSH_TIMEOUT) must not stall the whole status sweep.
  The registry only answers lookups, spawns forwarder ports (cheap), and
  registers finished connections; when two callers race to connect the same
  host, the second registration loses and its connection is closed.
  """

  @behaviour Ssm.Ssh.Client

  use GenServer
  require Logger

  alias Ssm.Hosts.SshFields
  alias Ssm.Ssh.{HostKey, HostKeyCb, RemoteFile, Result, Target}

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
  def probe_host_key(%Target{} = target, opts) do
    expect = Keyword.get(opts, :expect)
    key_mode = if HostKey.pinned?(expect), do: {:verify, expect}, else: :capture
    prefer = Keyword.get(opts, :prefer) || expect

    with :ok <- SshFields.check_target(target),
         :ok <- ensure_jump_chain_pinned(target),
         {:connect, key_dir, address, port, mode} <- probe_spec(target),
         :ok <- maybe_await_forwarder(mode, port) do
      address
      |> handshake(port, target.username, key_dir, key_mode, prefer)
      |> probe_result(target)
    else
      {:error, {:ssh_connect_failed, _}} = error -> error
      {:error, reason} -> {:error, connect_error(target, reason)}
    end
  end

  defp probe_spec(target) do
    GenServer.call(__MODULE__, {:probe_spec, target}, registry_timeout())
  catch
    :exit, reason -> {:error, {:registry_unavailable, reason}}
  end

  defp probe_result({{:ok, conn}, {:accepted, offered}}, _target) do
    catch_all(fn -> :ssh.close(conn) end)
    {:ok, offered}
  end

  defp probe_result({{:ok, conn}, nil}, target) do
    catch_all(fn -> :ssh.close(conn) end)
    {:error, connect_error(target, :host_key_never_offered)}
  end

  defp probe_result({{:error, _}, {:rejected, offered}}, _target),
    do: {:error, {:host_key_mismatch, offered}}

  defp probe_result({{:error, reason}, _report}, target),
    do: {:error, connect_error(target, reason)}

  @impl Ssm.Ssh.Client
  def close do
    GenServer.call(__MODULE__, :close, :infinity)
  end

  @doc "Drop the cached connection (and forwarder) for a host."
  def invalidate(host_id) do
    GenServer.call(__MODULE__, {:invalidate, host_id}, :infinity)
  end

  # Fast registry round-trips; the actual handshake happens in this process.
  # Unpinned targets (or jump hops OpenSSH cannot verify) never get that far.
  defp checkout(target) do
    with :ok <- SshFields.check_target(target),
         :ok <- ensure_pinned(target) do
      lookup(target)
    end
  end

  defp lookup(target) do
    case GenServer.call(__MODULE__, {:lookup, target}, registry_timeout()) do
      {:ok, conn} ->
        {:ok, conn}

      {:connect, key_dir, address, port, mode} ->
        connect_in_caller(target, key_dir, address, port, mode)

      {:error, reason} ->
        {:error, connect_error(target, reason)}
    end
  catch
    :exit, reason ->
      {:error, {:ssh_connect_failed, "ssh registry unavailable: #{inspect(reason)}"}}
  end

  defp ensure_pinned(target) do
    if HostKey.pinned?(target.host_key_fingerprint) do
      ensure_jump_chain_pinned(target)
    else
      {:error,
       {:ssh_connect_failed,
        "host key for #{target.name} is not pinned — refusing to connect unverified " <>
          "(pin it first: Hosts → Pin host keys)"}}
    end
  end

  # OpenSSH verifies jump hops against known_hosts, which needs the full
  # public key — a fingerprint alone is not enough.
  defp ensure_jump_chain_pinned(%Target{jump_target: nil}), do: :ok

  defp ensure_jump_chain_pinned(%Target{jump_target: jump}) do
    case Enum.find(jump_chain(jump), &(not verifiable_hop?(&1))) do
      nil ->
        :ok

      hop ->
        {:error,
         {:ssh_connect_failed,
          "jump host #{hop.name} cannot be verified by OpenSSH: it needs a pinned " <>
            "public key matching its fingerprint (pin its host key first) and a plain address"}}
    end
  end

  # The address goes into known_hosts verbatim: no whitespace or pattern
  # characters that could add or widen an entry.
  defp verifiable_hop?(%Target{host_key: key, host_key_fingerprint: pinned, address: address}) do
    is_binary(key) and Regex.match?(~r/^[^\s,\[\]*?!]+$/, address) and
      case HostKey.fingerprint(key) do
        {:ok, fingerprint} -> HostKey.matches?(pinned, fingerprint)
        {:error, _} -> false
      end
  end

  defp connect_in_caller(target, key_dir, address, port, mode) do
    with :ok <- maybe_await_forwarder(mode, port),
         {:ok, conn} <- verified_connect(address, port, target, key_dir) do
      GenServer.call(__MODULE__, {:register, target.host_id, conn}, registry_timeout())
    else
      {:error, reason} ->
        # Drop any half-started forwarder so the next attempt starts clean.
        GenServer.cast(__MODULE__, {:drop, target.host_id})
        {:error, connect_error(target, reason)}
    end
  catch
    :exit, reason ->
      {:error, {:ssh_connect_failed, "ssh registry unavailable: #{inspect(reason)}"}}
  end

  defp maybe_await_forwarder(:direct, _port), do: :ok

  defp maybe_await_forwarder(:forwarded, local_port) do
    case await_forwarder(local_port, connect_timeout_ms()) do
      :ok -> :ok
      {:error, reason} -> {:error, {:forwarder_not_ready, reason}}
    end
  end

  defp verified_connect(address, port, target, key_dir) do
    pinned = target.host_key_fingerprint

    case handshake(address, port, target.username, key_dir, {:verify, pinned}, pinned) do
      {{:ok, conn}, _report} -> {:ok, conn}
      {{:error, _}, {:rejected, offered}} -> {:error, {:host_key_changed, pinned, offered}}
      {{:error, reason}, _report} -> {:error, reason}
    end
  end

  # One handshake plus the HostKeyCb verdict it produced. The callback runs in
  # the connection process and reports to us before :ssh.connect returns, so
  # a zero-timeout receive collects it (and keeps the caller's mailbox clean).
  defp handshake(address, port, username, key_dir, key_mode, prefer) do
    result = ssh_connect(address, port, username, key_dir, key_mode, prefer)

    report =
      receive do
        {:ssm_host_key, verdict, offered} -> {verdict, offered}
      after
        0 -> nil
      end

    {result, report}
  end

  defp connect_error(target, {:host_key_changed, pinned, offered}) do
    {:ssh_connect_failed,
     "host key changed for #{target.name}: pinned #{pinned}, offered #{offered.fingerprint} — " <>
       "refusing to connect (possible man-in-the-middle; if the host was re-installed, " <>
       "accept the new key explicitly)"}
  end

  defp connect_error(target, reason),
    do: {:ssh_connect_failed, "ssh connect failed for #{target.name}: #{inspect(reason)}"}

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

    keys = init_keys(opts, ssh_config)

    state = %{
      key_dir: keys.dir,
      key_source: keys.source,
      key_passphrase: keys.passphrase,
      key_stamp: keys.stamp,
      conns: %{},
      forwarders: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:lookup, target}, _from, state) do
    case fetch_live(state.conns, target.host_id) do
      {:ok, conn} ->
        {:reply, {:ok, conn}, state}

      :error ->
        connect_spec(target, state)
    end
  end

  # A probe always handshakes afresh (never reuses or registers a
  # connection); jump targets still need their forwarder.
  def handle_call({:probe_spec, target}, _from, state), do: connect_spec(target, state)

  def handle_call({:register, host_id, conn}, _from, state) do
    case fetch_live(state.conns, host_id) do
      {:ok, existing} ->
        # Lost a connect race — keep the registered connection.
        catch_all(fn -> :ssh.close(conn) end)
        {:reply, {:ok, existing}, state}

      :error ->
        {:reply, {:ok, conn}, put_in(state.conns[host_id], conn)}
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

  @impl GenServer
  def handle_cast({:drop, host_id}, state) do
    {:noreply, drop_host(state, host_id)}
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

  # What the caller must do to obtain a connection: direct handshake, or
  # handshake against a local forwarder port (spawned here — cheap; the
  # caller awaits its readiness and performs the handshake itself).
  defp connect_spec(target, state), do: do_connect_spec(target, refresh_keys(state))

  defp do_connect_spec(%Target{jump_target: nil} = target, state) do
    {:reply, {:connect, state.key_dir, target.address, target.port, :direct}, state}
  end

  defp do_connect_spec(%Target{} = target, state) do
    case ensure_forwarder(target, state) do
      {:ok, local_port, state} ->
        {:reply, {:connect, state.key_dir, "127.0.0.1", local_port, :forwarded}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The host-key algorithm order is fixed with the pinned type first, so a
  # host with several keys always presents the one we can verify. It must be
  # `modify_algorithms prepend` (reorder only): replacing the public_key list
  # via preferred_algorithms would also restrict user-auth key algorithms.
  defp ssh_connect(address, port, username, key_dir, key_mode, prefer) do
    :ssh.connect(
      String.to_charlist(address),
      port,
      [
        user: String.to_charlist(username),
        user_dir: String.to_charlist(key_dir),
        key_cb: {HostKeyCb, mode: key_mode, reply_to: self()},
        modify_algorithms: [prepend: [public_key: HostKey.algorithm_preference(prefer)]],
        silently_accept_hosts: false,
        save_accepted_host: false,
        user_interaction: false,
        quiet_mode: true,
        auth_methods: ~c"publickey",
        connect_timeout: connect_timeout_ms()
      ],
      connect_timeout_ms()
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
    with {:ok, ssh_bin} <- find_openssh(),
         {:ok, local_port} <- free_local_port(),
         {:ok, config_path} <- write_forwarder_files(target, state.key_dir) do
      args = forwarder_args(target, config_path, key_file_path(state.key_dir), local_port)

      # Spawn only — readiness is awaited by the caller (await_forwarder),
      # so a slow jump host cannot stall the registry.
      port = Port.open({:spawn_executable, ssh_bin}, [:binary, :exit_status, args: args])
      state = put_in(state.forwarders[target.host_id], %{port: port, local_port: local_port})
      {:ok, local_port, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp write_forwarder_files(target, key_dir) do
    known_hosts = Path.join(key_dir, "known_hosts-#{target.host_id}")
    config = Path.join(key_dir, "ssh_config-#{target.host_id}")

    with :ok <- File.write(known_hosts, known_hosts_content(target.jump_target)),
         :ok <- File.write(config, forwarder_config(key_file_path(key_dir), known_hosts)) do
      {:ok, config}
    end
  end

  defp remove_forwarder_files(state, host_id) do
    for name <- ["known_hosts-#{host_id}", "ssh_config-#{host_id}"] do
      _ = File.rm(Path.join(state.key_dir, name))
    end

    :ok
  end

  @doc false
  # known_hosts for a jump chain: one line per hop (innermost first) with the
  # hop's pinned public key, matched by OpenSSH on `address` / `[address]:port`.
  @spec known_hosts_content(Target.t()) :: String.t()
  def known_hosts_content(%Target{} = innermost_hop) do
    innermost_hop
    |> jump_chain()
    |> Enum.map_join(&(HostKey.known_hosts_line(&1.address, &1.port, &1.host_key) <> "\n"))
  end

  @doc false
  # ssh_config for the forwarder and every ProxyJump hop: strict checking
  # against the generated known_hosts only; no user/global files consulted.
  @spec forwarder_config(String.t(), String.t()) :: String.t()
  def forwarder_config(key_file, known_hosts) do
    """
    Host *
      IdentityFile "#{key_file}"
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      UserKnownHostsFile "#{known_hosts}"
      GlobalKnownHostsFile /dev/null
      CheckHostIP no
      UpdateHostKeys no
      BatchMode yes
      ConnectTimeout #{max(div(connect_timeout_ms(), 1000), 1)}
    """
  end

  @doc false
  # argv of the OpenSSH forwarder. jump_target is the innermost hop; walking
  # jump_target links yields the chain inner→outer. OpenSSH wants the -J
  # list outer→inner and the innermost hop as the destination. User and port
  # of the destination go as -l/-p, and `--` ends the options, so no host
  # field is ever parsed as an ssh option (SshFields also refuses them).
  # -F (unlike -o) is passed on to the ProxyJump child processes, so the
  # generated config verifies every hop, not just the innermost one.
  @spec forwarder_args(Target.t(), String.t(), String.t(), :inet.port_number()) :: [String.t()]
  def forwarder_args(%Target{} = target, config_path, key_file, local_port) do
    [innermost | rest_outer] = jump_chain(target.jump_target)

    jump_args =
      case rest_outer do
        [] ->
          []

        outer ->
          list =
            outer
            |> Enum.reverse()
            |> Enum.map_join(",", &"#{&1.username}@#{bracket(&1.address)}:#{&1.port}")

          ["-J", list]
      end

    [
      "-F",
      config_path,
      "-N",
      "-L",
      "127.0.0.1:#{local_port}:#{bracket(target.address)}:#{target.port}",
      "-i",
      key_file,
      "-l",
      innermost.username,
      "-p",
      Integer.to_string(innermost.port),
      "-o",
      "ExitOnForwardFailure=yes"
    ] ++ jump_args ++ ["--", innermost.address]
  end

  # IPv6 literals need brackets inside -L and -J specs.
  defp bracket(address) do
    if String.contains?(address, ":"), do: "[#{address}]", else: address
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

    remove_forwarder_files(state, host_id)

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

  # An explicit `:key_dir` (tests) is used as is. Otherwise the operator's key
  # is copied into a private temp dir at boot and again whenever the source
  # file changes (`refresh_keys/1`), so a key created or replaced after boot
  # works without a restart.
  defp init_keys(opts, ssh_config) do
    case Keyword.fetch(opts, :key_dir) do
      {:ok, dir} ->
        %{dir: dir, source: nil, passphrase: nil, stamp: nil}

      :error ->
        source = Path.expand(key_opt(opts, ssh_config, :key_file, "keys/id_ssm"))
        passphrase = key_opt(opts, ssh_config, :key_passphrase, nil)

        dir = Path.join(System.tmp_dir!(), "ssm-ssh-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        File.chmod!(dir, 0o700)

        stamp = install_key(dir, source, passphrase, nil)
        %{dir: dir, source: source, passphrase: passphrase, stamp: stamp}
    end
  end

  defp key_opt(opts, ssh_config, key, default),
    do: Keyword.get_lazy(opts, key, fn -> Keyword.get(ssh_config, key, default) end)

  defp refresh_keys(%{key_source: nil} = state), do: state

  defp refresh_keys(state) do
    stamp = install_key(state.key_dir, state.key_source, state.key_passphrase, state.key_stamp)
    %{state | key_stamp: stamp}
  end

  # Content hash, not mtime: a same-size rewrite within one second must count.
  defp source_stamp(source) do
    case File.read(source) do
      {:ok, content} -> :crypto.hash(:sha256, content)
      {:error, _} -> :missing
    end
  end

  # Returns the stamp now in effect. Unchanged source: no-op. Vanished
  # source: the last installed key stays usable.
  defp install_key(dir, source, passphrase, previous) do
    case source_stamp(source) do
      ^previous ->
        previous

      :missing ->
        if previous == nil, do: log_key_unreadable(source, :enoent)
        previous

      stamp ->
        case copy_key(dir, source, passphrase) do
          :ok ->
            stamp

          {:error, reason} ->
            log_key_unreadable(source, reason)
            previous
        end
    end
  end

  defp log_key_unreadable(source, reason) do
    Logger.warning(
      "ssh.key_unreadable file=#{source} reason=#{inspect(reason)} — " <>
        "SSH operations will fail until SSH_KEY points at a readable key"
    )
  end

  defp copy_key(dir, source, passphrase) do
    with {:ok, _} <- File.read(source) do
      work = Path.join(dir, "key.work")
      File.cp!(source, work)
      File.chmod!(work, 0o600)

      try do
        maybe_decrypt!(work, passphrase)
        material = File.read!(work)

        for name <- ~w(id_ed25519 id_rsa id_ecdsa), do: File.rm(Path.join(dir, name))

        for name <- standard_key_names(material) do
          dest = Path.join(dir, name)
          File.write!(dest, material)
          File.chmod!(dest, 0o600)
        end

        :ok
      after
        File.rm(work)
      end
    end
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

  # SSH_CONNECT_TIMEOUT (default 10s): TCP + handshake budget. Dead or
  # firewalled hosts must fail fast; only exec/sftp get the long SSH_TIMEOUT.
  defp connect_timeout_ms do
    seconds =
      Application.get_env(:ssm, :ssh, [])
      |> Keyword.get(:connect_timeout_seconds, 10)

    seconds * 1000
  end

  # Registry calls are bookkeeping only (no IO beyond a port spawn).
  defp registry_timeout, do: 15_000
end
