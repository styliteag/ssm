defmodule Ssm.OIDC.Roles do
  @moduledoc """
  Suite role → ssm role (oidc-client-v1 §4) and customer resolution (§5).
  `admin`, `operator`, `viewer` map to themselves; `customer` is refused in
  ssm; anything else (or nothing) is refused.
  """

  require Logger

  alias Ssm.Customers
  alias Ssm.OIDC.Config

  @type refusal :: :customer_role | :unknown_role

  @doc "Resolve role and customers from ID token `claims`."
  @spec resolve(map(), Config.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, refusal()}
  def resolve(claims, %Config{} = config) do
    case suite_role(claims, config) do
      "admin" -> {:ok, "admin", customers(claims, config)}
      "operator" -> {:ok, "operator", customers(claims, config)}
      "viewer" -> {:ok, "viewer", customers(claims, config)}
      "customer" -> {:error, :customer_role}
      _ -> {:error, :unknown_role}
    end
  end

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

  defp customers(claims, config) do
    case claims[config.customers_claim] do
      ["*"] -> ["*"]
      slugs when is_list(slugs) -> Enum.filter(Enum.uniq(slugs), &known_slug?/1)
      _ -> []
    end
  end

  defp known_slug?(slug) when is_binary(slug) do
    known = Customers.get_customer_by_slug(slug) != nil
    unless known, do: Logger.warning("OIDC: unknown customer slug #{inspect(slug)} ignored")
    known
  end

  defp known_slug?(_), do: false
end
