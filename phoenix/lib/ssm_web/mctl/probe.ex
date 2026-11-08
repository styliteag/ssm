defmodule SsmWeb.Mctl.Probe do
  @moduledoc """
  `probe_ssh` of the mctl contract (0.5.0): Mission Control asks ssm whether
  an address answers SSH as seen from ssm, directly or through one of ssm's
  hosts as jump host (`jump_via`, id or name). The probe itself is
  `Ssm.Ssh.Probe` (TCP connect + first line only, no login).

  The jump host and every hop of its own chain must exist, must not be
  disabled (`Ssm.Ssh.Safety`: disabled hosts are never contacted) and must
  have a pinned host key. Probes are rate-limited per token (#{30} per
  minute; over it a `conflict`) and every probe is written to the activity
  log (target, ports, via, which ports answered SSH).
  """

  alias Ssm.Hosts
  alias Ssm.Ssh.{Probe, Safety}
  alias SsmWeb.Mctl.Audit

  @limit 30
  @window 60

  @doc "Run one probe for `principal` with the contract's checked params."
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(principal, %{"address" => address, "ports" => ports} = params) do
    with :ok <- rate(principal),
         {:ok, jump} <- jump(params["jump_via"]) do
      target = jump && Hosts.target_for(jump)

      case Probe.run(address, ports, target) do
        {:ok, results} ->
          Audit.probe(principal, address, ports, jump && jump.name, results)
          {:ok, %{results: results, address: address, via: jump && jump.name}}

        {:error, _} = error ->
          Audit.probe(principal, address, ports, jump && jump.name, :refused)
          error
      end
    end
  end

  defp rate(principal) do
    case Ssm.RateLimit.hit({:mctl_probe_ssh, principal.name}, @limit, @window) do
      :ok -> :ok
      {:error, retry} -> {:error, {:conflict, "too many SSH probes, retry in #{retry} s"}}
    end
  end

  defp jump(nil), do: {:ok, nil}

  defp jump(ref) do
    with {:ok, id} <- Hosts.resolve_host_ref(ref) |> found(),
         host when not is_nil(host) <- Hosts.get_host(id) || :not_found,
         :ok <- usable_chain(host, MapSet.new()) do
      {:ok, host}
    else
      :not_found -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp found({:ok, id}), do: {:ok, id}
  defp found(:error), do: :not_found

  # every hop: not disabled, host key pinned; a loop in jump_via is refused
  defp usable_chain(host, seen) do
    cond do
      MapSet.member?(seen, host.id) ->
        invalid("jump chain of #{host.name} loops")

      Safety.ensure_host_not_disabled(host) != :ok ->
        invalid("jump host #{host.name} is disabled")

      blank?(host.key_fingerprint) or blank?(host.host_key) ->
        invalid("jump host #{host.name} has no pinned host key")

      is_nil(host.jump_via) ->
        :ok

      true ->
        case Hosts.get_host(host.jump_via) do
          nil -> invalid("jump host #{host.name} points to a missing host")
          next -> usable_chain(next, MapSet.put(seen, host.id))
        end
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp invalid(reason), do: {:error, {:validation, %{"jump_via" => [reason]}}}
end
