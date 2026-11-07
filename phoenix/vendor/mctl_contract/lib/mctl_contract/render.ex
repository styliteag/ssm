defmodule MctlContract.Render do
  @moduledoc """
  Turns provider maps (atom or string keys) into the JSON shape of the
  contract objects: every key present, unknown keys dropped, times as ISO
  8601 UTC with `Z`, ids as strings, identity MACs filtered by
  `MctlContract.Identity.useful_macs/1`.
  """
  alias MctlContract.Identity

  @spec host(map()) :: map()
  def host(h) do
    %{
      "id" => id(get(h, :id)),
      "name" => get(h, :name),
      "addresses" => get(h, :addresses) || [],
      "mode" => get(h, :mode),
      "kind" => get(h, :kind) || "other",
      "customer" => get(h, :customer),
      "groups" => get(h, :groups) || [],
      "ui_url" => get(h, :ui_url),
      "updated_at" => time(get(h, :updated_at)),
      "identity" => identity(get(h, :identity)),
      "attributes" => get(h, :attributes) || %{}
    }
  end

  @spec identity(map() | nil) :: map()
  def identity(nil), do: identity(%{})

  def identity(i) do
    %{
      "machine_id" => get(i, :machine_id),
      "product_uuid" => get(i, :product_uuid),
      "macs" => Identity.useful_macs(get(i, :macs)),
      "ssh_host_keys" => get(i, :ssh_host_keys) || [],
      "observed_at" => time(get(i, :observed_at))
    }
  end

  @doc "Result of `POST /customers/{slug}/merge`."
  @spec customer_merge(map()) :: map()
  def customer_merge(r), do: %{"moved_hosts" => get(r, :moved_hosts) || 0}

  @spec named(map()) :: map()
  def named(c), do: %{"slug" => get(c, :slug), "name" => get(c, :name)}

  @spec job(map()) :: map()
  def job(j) do
    %{
      "id" => id(get(j, :id)),
      "kind" => get(j, :kind),
      "state" => get(j, :state),
      "host_id" => id(get(j, :host_id)),
      "progress" => get(j, :progress),
      "result" => get(j, :result),
      "error" => get(j, :error),
      "created_at" => time(get(j, :created_at)),
      "finished_at" => time(get(j, :finished_at))
    }
  end

  @doc "A maintenance window (contract section 10)."
  @spec maintenance(map()) :: map()
  def maintenance(m) do
    %{
      "id" => id(get(m, :id)),
      "host_id" => id(get(m, :host_id)),
      "start" => time(get(m, :start)),
      "end" => time(get(m, :end)),
      "comment" => get(m, :comment),
      "author" => get(m, :author),
      "state" => get(m, :state)
    }
  end

  @doc """
  A person (contract section 10): only fingerprint, comment, hosts and
  `matched_by` per key – anything else a provider puts there (key material)
  is dropped. `emails` are the e-mail addresses the tool matched by,
  `matched_by` says why a key or authorization belongs to the person (shown
  before a removal). `operator` is passed through as given (a map or nil).
  """
  @spec person(map()) :: map()
  def person(p) do
    %{
      "key" => get(p, :key),
      "operator" => get(p, :operator),
      "emails" => get(p, :emails) || [],
      "keys" =>
        Enum.map(get(p, :keys) || [], fn k ->
          %{
            "fingerprint" => get(k, :fingerprint),
            "comment" => get(k, :comment),
            "hosts" => Enum.map(get(k, :hosts) || [], &id/1),
            "matched_by" => get(k, :matched_by)
          }
        end),
      "authorizations" =>
        Enum.map(get(p, :authorizations) || [], fn a ->
          %{
            "host_id" => id(get(a, :host_id)),
            "remote_user" => get(a, :remote_user),
            "matched_by" => get(a, :matched_by)
          }
        end)
    }
  end

  @max_summary_items 50
  @severity %{"crit" => 0, "warn" => 1, "unknown" => 2}

  @doc """
  A host summary (contract section 9): all five `counts` keys present
  (`handled` defaults to 0), `items` unhandled first, each group worst
  first (stable), cut at 50. Item flags `acknowledged` and `in_downtime`
  are always booleans (absent = `false`).
  """
  @spec host_summary(map()) :: map()
  def host_summary(s) do
    counts = get(s, :counts) || %{}

    %{
      "host_id" => id(get(s, :host_id)),
      "state" => get(s, :state),
      "reason" => get(s, :reason),
      "counts" => Map.new(~w(ok warn crit unknown handled), &{&1, count(counts, &1)}),
      "items" => summary_items(get(s, :items) || []),
      "checked_at" => time(get(s, :checked_at)),
      "updated_at" => time(get(s, :updated_at))
    }
  end

  defp summary_items(items) do
    items
    |> Enum.map(fn i ->
      %{
        "name" => get(i, :name),
        "state" => get(i, :state),
        "text" => get(i, :text),
        "since" => time(get(i, :since)),
        "acknowledged" => get(i, :acknowledged) == true,
        "in_downtime" => get(i, :in_downtime) == true
      }
    end)
    |> Enum.sort_by(&{handled?(&1), Map.get(@severity, &1["state"], 3)})
    |> Enum.take(@max_summary_items)
  end

  defp handled?(item), do: item["acknowledged"] or item["in_downtime"]

  defp count(counts, key), do: get(counts, String.to_atom(key)) || 0

  @doc "ISO 8601 UTC with `Z`, seconds precision; nil stays nil."
  @spec time(DateTime.t() | NaiveDateTime.t() | String.t() | nil) :: String.t() | nil
  def time(nil), do: nil

  def time(%DateTime{} = dt),
    do:
      dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def time(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> time()
  def time(s) when is_binary(s), do: s

  defp id(nil), do: nil
  defp id(v) when is_binary(v), do: v
  defp id(v), do: to_string(v)

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
