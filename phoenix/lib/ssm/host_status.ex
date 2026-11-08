defmodule Ssm.HostStatus do
  @moduledoc """
  The one status of a host, as the hosts page and the diff viewer show it.
  Pure: derived from the host row, this node's `Ssm.Diffs.StatusCache`
  entry and the stored check (`Ssm.Diffs.HostCheck`); nothing here reads
  the database or opens a connection.

  States (`t()`):

    * `:disabled` – `host.disabled`; beats every other signal
    * `:unchecked` – no cache entry and no stored check
    * `:synced` – keys read, no difference
    * `{:drift, missing, extra}` – keys read, differences found
    * `:reachable` – a connection test passed; keys not compared
      (`from_connection/1`, the hosts page's own test)
    * `{:auth_failed, message}` – the host refused ssm's key
    * `{:host_key_changed, message}` – the host presented another host key
      than the pinned one
    * `{:unreachable, message}` – any other failed read or connect

  Precedence in `derive/3`: disabled, then the cache entry (the latest
  result on this node), then the stored check (survives a restart), else
  unchecked. Failures are classified by `Ssm.Ssh.ErrorCode` (raw text) or
  the stored `error_code`; nothing else parses the error.

  Transitions that drop a status: deleting a host (`Ssm.Hosts.delete_host/1`,
  every path, including the hosts a jump host's delete cascades to) evicts
  its cache entry (the check row goes by `ON DELETE CASCADE`); disabling or
  re-enabling a host (`Ssm.Hosts.update_host/2`) forgets both, so a host
  starts `:unchecked` after it is enabled again.
  """

  alias Ssm.Diffs.HostCheck
  alias Ssm.Hosts.Host
  alias Ssm.Ssh.ErrorCode

  @type error :: {:auth_failed | :host_key_changed | :unreachable, String.t()}
  @type t ::
          :disabled
          | :unchecked
          | :synced
          | {:drift, non_neg_integer(), non_neg_integer()}
          | :reachable
          | error()

  @typedoc "A `Ssm.Diffs.StatusCache.all/0` value: `{SyncCheck.status/1, cached_at_ms}`."
  @type cache_entry :: {term(), integer()} | nil

  @doc "The status of `host` from its cache entry and stored check."
  @spec derive(Host.t(), cache_entry(), HostCheck.t() | nil) :: t()
  def derive(%Host{disabled: true}, _cached, _stored), do: :disabled
  def derive(%Host{}, {status, _at}, _stored), do: from_sync_status(status)
  def derive(%Host{}, nil, %HostCheck{} = stored), do: from_check(stored)
  def derive(%Host{}, nil, nil), do: :unchecked

  @doc "The status of a `Ssm.Diffs.SyncCheck.status/1` result."
  @spec from_sync_status(term()) :: t()
  def from_sync_status(:synced), do: :synced
  def from_sync_status({:needs_sync, missing, extra}), do: {:drift, missing, extra}
  def from_sync_status({:error, raw}), do: from_error(raw)

  @doc "The status of a stored check."
  @spec from_check(HostCheck.t()) :: t()
  def from_check(%HostCheck{state: "synced"}), do: :synced

  def from_check(%HostCheck{state: "drift", drift: drift}) do
    count = fn field -> drift |> Enum.map(&length(&1[field] || [])) |> Enum.sum() end
    {:drift, count.("missing"), count.("extra")}
  end

  def from_check(%HostCheck{state: "error", error_code: code, error: error}),
    do: error_tag(code, error || "error")

  @doc "The status of an `Ssm.Ssh.connect/1` result (a connection test)."
  @spec from_connection(:ok | {:error, term()}) :: t()
  def from_connection(:ok), do: :reachable

  def from_connection({:error, {_code, message}}) when is_binary(message),
    do: from_error(message)

  def from_connection({:error, reason}), do: {:unreachable, inspect(reason)}

  @doc "The status of a raw failure text (SSH output, connect error)."
  @spec from_error(String.t()) :: error()
  def from_error(raw) when is_binary(raw) do
    {code, _sentence} = ErrorCode.classify({:ssh_connect_failed, raw})
    error_tag(code, raw)
  end

  @doc "Did the last signal reach the host (keys read or connect passed)?"
  @spec reachable?(t()) :: boolean()
  def reachable?(status), do: status in [:synced, :reachable] or match?({:drift, _, _}, status)

  @doc "Did the last signal fail?"
  @spec error?(t()) :: boolean()
  def error?({tag, _message}) when tag in [:auth_failed, :host_key_changed, :unreachable],
    do: true

  def error?(_status), do: false

  defp error_tag("auth_failed", message), do: {:auth_failed, message}
  defp error_tag("host_key_changed", message), do: {:host_key_changed, message}
  defp error_tag(_code, message), do: {:unreachable, message}
end
