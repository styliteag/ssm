defmodule Ssm.OIDC.Roles do
  @moduledoc """
  Suite role → ssm role (oidc-client-v1 §4) and the operator's host scope
  (ADR-0012 §1). `admin`, `operator`, `viewer` map to themselves;
  `customer` is refused in ssm; anything else (or nothing) is refused.

  The scope comes from two claims, customers (`OIDC_CUSTOMERS_CLAIM`,
  default `orbit_customers`) and host groups (`OIDC_GROUPS_CLAIM`, default
  `orbit_groups`). Each must be exactly `["*"]` or a non-empty list of
  slugs; anything else (a mixed `["*", "x"]` included) is malformed.
  Fail closed: `operator` and `viewer` are refused when a claim is missing
  or malformed. The only exception is `OIDC_GROUPS_DEFAULT=*`, which lets
  a missing groups claim count as `*` (providers that are not mctl).
  `admin` is always global: missing claims count as `*`, a restriction is
  refused (`:admin_scoped`), never downgraded. Unknown slugs grant nothing
  and are logged.
  """

  require Logger

  alias Ssm.{Customers, Groups}
  alias Ssm.OIDC.Config

  @type refusal ::
          :customer_role
          | :unknown_role
          | :customers_missing
          | :customers_malformed
          | :groups_missing
          | :groups_malformed
          | :admin_scoped

  @type scope :: %{customers: [String.t()], groups: [String.t()]}

  @doc "Resolve role and scope (slug lists, `[\"*\"]` = all) from ID token `claims`."
  @spec resolve(map(), Config.t()) :: {:ok, String.t(), scope()} | {:error, refusal()}
  def resolve(claims, %Config{} = config) do
    case suite_role(claims, config) do
      role when role in ["operator", "viewer"] -> scoped(role, claims, config)
      "admin" -> admin(claims, config)
      "customer" -> {:error, :customer_role}
      _ -> {:error, :unknown_role}
    end
  end

  defp scoped(role, claims, config) do
    with {:ok, customers} <- dimension(claims, config.customers_claim, nil, :customers),
         {:ok, groups} <- dimension(claims, config.groups_claim, config.groups_default, :groups) do
      {:ok, role, %{customers: known(customers, :customers), groups: known(groups, :groups)}}
    end
  end

  # Missing claims count as `*` for an admin; a present claim must be `*`.
  defp admin(claims, config) do
    with {:ok, customers} <- dimension(claims, config.customers_claim, :all, :customers),
         {:ok, groups} <- dimension(claims, config.groups_claim, :all, :groups) do
      if customers == :all and groups == :all,
        do: {:ok, "admin", %{customers: ["*"], groups: ["*"]}},
        else: {:error, :admin_scoped}
    end
  end

  # `{:ok, :all | [slug]}` or `{:error, :<name>_missing | :<name>_malformed}`.
  defp dimension(claims, claim, default, name) do
    case Map.fetch(claims, claim) do
      :error -> missing(default, name)
      {:ok, nil} -> {:error, refusal(name, :malformed)}
      {:ok, ["*"]} -> {:ok, :all}
      {:ok, value} -> slugs(value, name)
    end
  end

  defp missing(:all, _name), do: {:ok, :all}
  defp missing(_default, name), do: {:error, refusal(name, :missing)}

  defp slugs([_ | _] = list, name) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "" and &1 != "*")),
      do: {:ok, Enum.uniq(list)},
      else: {:error, refusal(name, :malformed)}
  end

  defp slugs(_value, name), do: {:error, refusal(name, :malformed)}

  defp refusal(:customers, :missing), do: :customers_missing
  defp refusal(:customers, :malformed), do: :customers_malformed
  defp refusal(:groups, :missing), do: :groups_missing
  defp refusal(:groups, :malformed), do: :groups_malformed

  defp known(:all, _name), do: ["*"]
  defp known(slugs, name), do: Enum.filter(slugs, &known_slug?(&1, name))

  defp known_slug?(slug, name) do
    known = lookup(name, slug) != nil

    unless known,
      do: Logger.warning("OIDC: unknown #{singular(name)} slug #{inspect(slug)} ignored")

    known
  end

  defp lookup(:customers, slug), do: Customers.get_customer_by_slug(slug)
  defp lookup(:groups, slug), do: Groups.get_group_by_slug(slug)

  defp singular(:customers), do: "customer"
  defp singular(:groups), do: "group"

  defp suite_role(claims, config) do
    case claims[config.role_claim] do
      role when is_binary(role) -> role
      nil -> role_from_groups(claims["groups"], config.role_map)
      _ -> nil
    end
  end

  # First entry of the map (in list order) that the user's groups contain.
  defp role_from_groups(groups, role_map) when is_list(groups) do
    Enum.find_value(role_map, fn {group, role} -> if group in groups, do: role end)
  end

  defp role_from_groups(_groups, _role_map), do: nil
end
