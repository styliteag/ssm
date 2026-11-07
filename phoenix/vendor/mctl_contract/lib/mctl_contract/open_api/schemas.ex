defmodule MctlContract.OpenAPI.Schemas do
  @moduledoc false
  # JSON schemas of the contract objects (contract v1, section 5).
  alias MctlContract.{Page, Params}

  # actions: the provider's action names, or nil without host actions
  # caps: the provider's capabilities (section 10 schemas)
  def all(attributes, summaries? \\ false, actions \\ nil, caps \\ []) do
    base(attributes)
    |> then(&if(summaries?, do: Map.put(&1, "HostSummary", host_summary()), else: &1))
    |> then(&if(actions, do: Map.put(&1, "HostAction", host_action(actions)), else: &1))
    |> then(&if("maintenance" in caps, do: Map.merge(&1, maintenance()), else: &1))
    |> then(&if("people" in caps, do: Map.merge(&1, people()), else: &1))
  end

  defp maintenance do
    %{
      "Maintenance" =>
        obj(
          %{
            "id" => str(),
            "host_id" => str(),
            "start" => time(),
            "end" => time(),
            "comment" => nullable(str()),
            "author" => nullable(str()),
            "state" => enum(Page.maintenance_states())
          },
          ~w(id host_id start end comment author state)
        ),
      "MaintenanceCreate" =>
        obj(
          %{
            "start" => time(),
            "end" =>
              Map.put(
                time(),
                "description",
                "after start and now, at most #{Params.max_window_days()} days after start"
              ),
            "comment" => %{"type" => "string", "minLength" => 1, "maxLength" => 1000}
          },
          ~w(start end comment)
        )
    }
  end

  defp people do
    matched_by =
      Map.put(
        nullable(str()),
        "description",
        "why it belongs to the person, e.g. \"ssh user ada@example.com (verified e-mail)\""
      )

    key =
      obj(
        %{
          "fingerprint" => str(),
          "comment" => nullable(str()),
          "hosts" => list(str()),
          "matched_by" => matched_by
        },
        ~w(fingerprint comment hosts matched_by)
      )

    authorization =
      obj(
        %{"host_id" => str(), "remote_user" => nullable(str()), "matched_by" => matched_by},
        ~w(host_id remote_user matched_by)
      )

    %{
      "Person" =>
        obj(
          %{
            "key" => Map.put(str(), "description", "oidc:<iss>|<sub> or email:<address>"),
            "operator" => nullable(%{"type" => "object"}),
            "emails" =>
              Map.put(list(str()), "description", "e-mail addresses the tool matched by"),
            "keys" => Map.put(list(key), "description", "fingerprints only, never key material"),
            "authorizations" => list(authorization)
          },
          ~w(key operator emails keys authorizations)
        ),
      "PersonRemove" =>
        obj(
          %{
            "hosts" => Map.put(list(str()), "description", "host ids; default all managed hosts")
          },
          []
        )
    }
  end

  defp host_action(actions) do
    obj(
      %{
        "action" => enum(actions),
        "params" => %{
          "type" => "object",
          "description" => "action specific, validated by the tool"
        }
      },
      ["action"]
    )
  end

  defp base(attributes) do
    %{
      "Me" => me(),
      "Host" => host(),
      "HostAttributes" => attributes,
      "Identity" => identity(),
      "HostCreate" => host_create(),
      "HostUpdate" => host_update(),
      "Customer" => named(),
      "Group" => named(),
      "NamedCreate" => named(),
      "NamedUpdate" => obj(%{"name" => str()}, ["name"]),
      "Job" => job(),
      "PageMeta" =>
        obj(%{"limit" => %{"type" => "integer"}, "next_cursor" => nullable(str())}, [
          "limit",
          "next_cursor"
        ]),
      "Error" =>
        obj(
          %{
            "error" =>
              obj(%{"code" => str(), "message" => str(), "details" => %{}}, [
                "code",
                "message",
                "details"
              ])
          },
          ["error"]
        )
    }
  end

  defp me do
    obj(
      %{
        "product" => str(),
        "version" => str(),
        "contract_version" => str(),
        "scopes" => list(str()),
        "capabilities" => list(str()),
        "token" => obj(%{"name" => str(), "prefix" => str()}, ["name", "prefix"])
      },
      ~w(product version contract_version scopes capabilities token)
    )
  end

  defp host do
    obj(
      %{
        "id" => str(),
        "name" => str(),
        "addresses" => list(str()),
        "mode" => nullable(enum(Params.modes())),
        "kind" => enum(~w(linux freebsd windows firewall snmp other)),
        "customer" => nullable(slug()),
        "groups" => list(slug()),
        "ui_url" => nullable(str()),
        "updated_at" => nullable(time()),
        "identity" => ref("Identity"),
        "attributes" => ref("HostAttributes")
      },
      ~w(id name addresses mode kind customer groups ui_url updated_at identity attributes)
    )
  end

  defp identity do
    obj(
      %{
        "machine_id" => nullable(str()),
        "product_uuid" => nullable(str()),
        "macs" => list(%{"type" => "string", "pattern" => "^([0-9a-f]{2}:){5}[0-9a-f]{2}$"}),
        "ssh_host_keys" => list(str()),
        "observed_at" => nullable(time())
      },
      ~w(machine_id product_uuid macs ssh_host_keys observed_at)
    )
  end

  defp host_create do
    obj(
      %{
        "name" => str(),
        "addresses" => list(str()),
        "mode" => nullable(enum(Params.modes())),
        "customer" => nullable(slug()),
        "groups" => list(slug()),
        "attributes" => ref("HostAttributes")
      },
      ["name"]
    )
  end

  defp host_update do
    obj(
      %{
        "name" => str(),
        "customer" => nullable(slug()),
        "groups" => list(slug()),
        "mode" => nullable(enum(Params.modes()))
      },
      []
    )
  end

  defp named, do: obj(%{"slug" => slug(), "name" => str()}, ["slug", "name"])

  defp job do
    obj(
      %{
        "id" => str(),
        "kind" => str(),
        "state" => enum(Page.job_states()),
        "host_id" => nullable(str()),
        "progress" => nullable(str()),
        "result" => nullable(%{"type" => "object"}),
        "error" => nullable(obj(%{"code" => str(), "message" => str()}, ["code", "message"])),
        "created_at" => time(),
        "finished_at" => nullable(time())
      },
      ~w(id kind state host_id progress result error created_at finished_at)
    )
  end

  defp host_summary do
    state = enum(~w(ok warn crit unknown pending))
    count = %{"type" => "integer", "minimum" => 0}

    item =
      obj(
        %{
          "name" => str(),
          "state" => enum(~w(warn crit unknown)),
          "text" => nullable(str()),
          "since" => nullable(time()),
          "acknowledged" => bool(),
          "in_downtime" => bool()
        },
        ~w(name state text since)
      )

    obj(
      %{
        "host_id" => str(),
        "state" => state,
        "reason" => nullable(str()),
        "counts" =>
          obj(
            %{
              "ok" => count,
              "warn" => count,
              "crit" => count,
              "unknown" => count,
              "handled" => count
            },
            ~w(ok warn crit unknown)
          ),
        "items" => %{"type" => "array", "maxItems" => 50, "items" => item},
        "checked_at" => nullable(time()),
        "updated_at" => nullable(time())
      },
      ~w(host_id state reason counts items checked_at updated_at)
    )
  end

  defp obj(props, required),
    do: %{"type" => "object", "properties" => props, "required" => required}

  defp str, do: %{"type" => "string"}
  defp bool, do: %{"type" => "boolean"}
  defp time, do: %{"type" => "string", "format" => "date-time"}
  defp slug, do: %{"type" => "string", "pattern" => Params.slug_pattern()}
  defp enum(values), do: %{"type" => "string", "enum" => values}
  defp list(items), do: %{"type" => "array", "items" => items}
  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  defp nullable(%{"enum" => values} = s),
    do: %{s | "type" => [s["type"], "null"], "enum" => values ++ [nil]}

  defp nullable(%{"type" => type} = s) when is_binary(type), do: %{s | "type" => [type, "null"]}
  defp nullable(s), do: %{"oneOf" => [s, %{"type" => "null"}]}
end
