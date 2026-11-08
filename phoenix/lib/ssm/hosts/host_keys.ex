defmodule Ssm.Hosts.HostKeys do
  @moduledoc """
  Host-key pinning policy (ADR-0008). The SSH client only verifies or
  captures; this module decides what gets stored.

    * `pin/2` — the only trust-on-first-use path. An unpinned host is probed
      once and its key stored. A pre-seeded or legacy fingerprint is never
      overwritten by TOFU: the probe must present a matching key, which then
      fills the missing public key (and the key type of a bare legacy hash).
    * `accept/3` — the explicit operator action after a host key changed:
      stores the new key only if the host presents exactly the fingerprint
      the operator confirmed. Audited with old and new fingerprint.
    * `pin_all/1` — "Pin host keys now": every enabled host that is not
      fully pinned, jump hosts before the hosts behind them.

  Every function refuses disabled hosts before any SSH.
  """

  import Ecto.Query

  alias Ssm.Activity
  alias Ssm.Hosts
  alias Ssm.Hosts.{Host, MachineId}
  alias Ssm.Repo
  alias Ssm.Ssh.HostKey

  # Key types tried, in order, to resolve a bare legacy `SHA256:` pin.
  @legacy_types ~w(ssh-ed25519 ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 ssh-rsa)

  @type pin_status :: :pinned | :verified | :already_pinned
  @type changed :: {:host_key_changed, %{pinned: String.t(), offered: map()}}

  @doc "Pin (or complete the pin of) one host. See the moduledoc."
  @spec pin(Host.t(), keyword()) ::
          {:ok, pin_status(), Host.t()} | {:error, changed() | term()}
  def pin(%Host{} = host, opts \\ []) do
    with :ok <- ensure_enabled(host) do
      do_pin(host, opts)
    end
  end

  defp do_pin(host, opts) do
    cond do
      fully_pinned?(host) -> {:ok, :already_pinned, host}
      HostKey.pinned?(host.key_fingerprint) -> verify_existing_pin(host, opts)
      true -> first_use(host, opts)
    end
  end

  defp first_use(host, opts) do
    with {:ok, offered} <- probe(host, opts, []),
         {:ok, pinned} <- store_key(host, offered) do
      audit(opts, "pin_host_key", pinned, %{fingerprint: offered.fingerprint})
      {:ok, :pinned, pinned}
    end
  end

  defp verify_existing_pin(host, opts) do
    pinned = host.key_fingerprint

    case probe_candidates(host, opts, pinned, candidate_types(pinned), nil) do
      {:ok, offered} ->
        with {:ok, verified} <- store_key(host, offered) do
          audit(opts, "pin_host_key", verified, %{fingerprint: offered.fingerprint})
          {:ok, :verified, verified}
        end

      {:mismatch, offered} ->
        {:error, {:host_key_changed, %{pinned: pinned, offered: offered}}}

      {:error, _} = error ->
        error
    end
  end

  # Try each candidate key type until the host presents the pinned key.
  defp probe_candidates(_host, _opts, _pinned, [], first_offered),
    do: {:mismatch, first_offered}

  defp probe_candidates(host, opts, pinned, [type | rest], first_offered) do
    case probe(host, opts, expect: pinned, prefer: type) do
      {:ok, offered} ->
        {:ok, offered}

      {:error, {:host_key_mismatch, offered}} ->
        probe_candidates(host, opts, pinned, rest, first_offered || offered)

      {:error, _} = error ->
        error
    end
  end

  defp candidate_types(pinned) do
    case String.split(pinned, " ") do
      [type, _hash] -> [type]
      _bare -> @legacy_types
    end
  end

  @doc """
  Accept a changed host key: `fingerprint` is the new fingerprint the
  operator confirmed (as shown in the "host key changed" error).
  """
  @spec accept(Host.t(), String.t(), keyword()) ::
          {:ok, Host.t()} | {:error, :invalid_fingerprint | changed() | term()}
  def accept(%Host{} = host, fingerprint, opts \\ []) do
    with :ok <- ensure_enabled(host),
         {:ok, expected} <- HostKey.normalize_fingerprint(fingerprint),
         {:ok, offered} <- probe_expected(host, opts, expected),
         {:ok, accepted} <- store_key(host, offered) do
      audit(opts, "accept_host_key", accepted, %{
        old_fingerprint: host.key_fingerprint,
        new_fingerprint: offered.fingerprint
      })

      {:ok, accepted}
    end
  end

  defp probe_expected(host, opts, expected) do
    prefer = expected |> String.split(" ") |> then(&if(length(&1) == 2, do: hd(&1)))

    case probe(host, opts, expect: expected, prefer: prefer) do
      {:error, {:host_key_mismatch, offered}} ->
        {:error, {:host_key_changed, %{pinned: expected, offered: offered}}}

      other ->
        other
    end
  end

  @doc """
  "Pin host keys now" (ADR-0008 §7): pin every enabled host that is not
  fully pinned yet. Jump hosts go first so the hosts behind them can be
  reached through a verified chain. Returns host names per outcome.
  """
  @spec pin_all(keyword()) :: %{
          pinned: [String.t()],
          already: [String.t()],
          failed: [{String.t(), term()}]
        }
  def pin_all(opts \\ []) do
    hosts = Repo.all(from h in Host, where: h.disabled == false)
    by_id = Map.new(hosts, &{&1.id, &1})

    hosts
    |> Enum.sort_by(&{jump_depth(&1, by_id, 0), &1.id})
    |> Enum.reduce(%{pinned: [], already: [], failed: []}, fn host, acc ->
      # Re-read: an earlier iteration may have pinned this host's jump hop.
      result = pin(Hosts.get_host(host.id) || host, opts)
      record(acc, host.name, learn_machine_id(result, opts))
    end)
    |> Map.new(fn {key, names} -> {key, Enum.reverse(names)} end)
  end

  # identity-claims-v1: a host just probed is reachable; learn its machine id.
  defp learn_machine_id({:ok, status, host}, opts) when status != :already_pinned,
    do: {:ok, status, MachineId.refresh(host, opts)}

  defp learn_machine_id(result, _opts), do: result

  defp record(acc, name, {:ok, :already_pinned, _}), do: %{acc | already: [name | acc.already]}
  defp record(acc, name, {:ok, _status, _}), do: %{acc | pinned: [name | acc.pinned]}
  defp record(acc, name, {:error, reason}), do: %{acc | failed: [{name, reason} | acc.failed]}

  defp jump_depth(%Host{jump_via: nil}, _by_id, depth), do: depth

  defp jump_depth(%Host{jump_via: via}, by_id, depth) when depth < 32 do
    case Map.get(by_id, via) do
      nil -> depth + 1
      jump -> jump_depth(jump, by_id, depth + 1)
    end
  end

  defp jump_depth(_host, _by_id, depth), do: depth

  @doc "True when the host has a typed fingerprint and the matching public key."
  @spec fully_pinned?(Host.t()) :: boolean()
  def fully_pinned?(%Host{key_fingerprint: pinned, host_key: key}) do
    with true <- is_binary(key),
         {:ok, fingerprint} <- HostKey.fingerprint(key),
         [_type, _hash] <- String.split(pinned || "", " ") do
      HostKey.matches?(pinned, fingerprint)
    else
      _ -> false
    end
  end

  @doc "Persist a probed key (fingerprint + public key)."
  @spec store_key(Host.t(), %{public_key: String.t(), fingerprint: String.t()}) ::
          {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def store_key(%Host{} = host, offered) do
    host |> Host.key_changeset(offered) |> Repo.update()
  end

  defp probe(host, opts, probe_opts) do
    client = Keyword.get(opts, :client, Ssm.Ssh)
    client.probe_host_key(Hosts.target_for(host), probe_opts)
  end

  defp ensure_enabled(%Host{disabled: true, name: name}),
    do: {:error, {:host_disabled, "host #{inspect(name)} is disabled"}}

  defp ensure_enabled(%Host{}), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp audit(opts, action, host, details) do
    Activity.log(%{
      activity_type: "host",
      action: action,
      target: host.name,
      host_id: host.id,
      actor_username: Keyword.get(opts, :actor, "system"),
      details:
        %{address: host.address, port: host.port}
        |> Map.merge(details)
        |> maybe_put(:ip, Keyword.get(opts, :ip))
    })
  end
end
