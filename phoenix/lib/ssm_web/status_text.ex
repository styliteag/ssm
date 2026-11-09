defmodule SsmWeb.StatusText do
  @moduledoc """
  The words and badge classes for a host's state (`Ssm.HostStatus` values,
  plus the diff page's transient `:loading`). Every page uses these, so one
  state has one name everywhere: "not checked", "in sync", "needs sync",
  "unreachable", "key not accepted", "host key changed", "disabled".

  `label/1` is the sync view (diff page). `connection/1` is the hosts page,
  which answers "can ssm reach it": a host whose keys were read is online.
  """

  @doc "Label for a host state."
  @spec label(term()) :: String.t()
  def label(:disabled), do: "disabled"
  def label(:loading), do: "checking…"
  def label(:unchecked), do: "not checked"
  def label(:synced), do: "in sync"
  def label({:drift, missing, extra}), do: "needs sync (+#{missing}/−#{extra})"
  def label(:reachable), do: "online"
  def label({:auth_failed, _message}), do: "key not accepted"
  def label({:host_key_changed, _message}), do: "host key changed"
  def label({:unreachable, _message}), do: "unreachable"

  @doc "daisyUI badge class for a host state."
  @spec class(term()) :: String.t()
  def class(:disabled), do: "badge-neutral"
  def class(status) when status in [:loading, :unchecked], do: "badge-ghost"
  def class(status) when status in [:synced, :reachable], do: "badge-success"
  def class({:drift, _missing, _extra}), do: "badge-warning"
  def class({_error, _message}), do: "badge-error"

  @doc "Hosts page: reached is reached, whatever the keys look like."
  @spec connection(term()) :: String.t()
  def connection(status), do: status |> reached() |> label()

  @spec connection_class(term()) :: String.t()
  def connection_class(status), do: status |> reached() |> class()

  defp reached(:synced), do: :reachable
  defp reached({:drift, _missing, _extra}), do: :reachable
  defp reached(status), do: status

  @doc "Label and class for a stored periodic check state (`HostCheck.state`)."
  @spec check_state(String.t() | nil) :: {String.t(), String.t()}
  def check_state(nil), do: {"not checked", "badge-ghost"}
  def check_state("synced"), do: {"in sync", "badge-success"}
  def check_state("drift"), do: {"needs sync", "badge-warning"}
  def check_state(_error), do: {"check failed", "badge-error"}
end
