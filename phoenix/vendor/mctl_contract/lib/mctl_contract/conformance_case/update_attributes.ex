defmodule MctlContract.ConformanceCase.UpdateAttributes do
  @moduledoc """
  Conformance assertions of contract section 16 (host attributes in
  `PATCH /hosts/{id}`, capability `update_attributes`), used by
  `MctlContract.ConformanceCase`. With the capability, `HostUpdate` in the
  OpenAPI document lists the updatable keys, a key outside that list is
  `422` on `attributes`, and with the optional fixture
  `updatable_attribute/0` (`{key, value}`) a supported attribute is
  accepted (200 or 202). Without the capability any `attributes` in a
  PATCH is `422` on `attributes`.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @unsupported "zz_conformance_unsupported"

  @doc "Checks `update_attributes`: served when `/me` lists it, else refused."
  def check(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)
    token = c.fixtures.token(~w(read setup))
    id = host_id!(c, token, create_host!(c, token, %{}))
    path = "/hosts/" <> id

    if "update_attributes" in me["capabilities"] do
      keys =
        get_in(spec, [
          "components",
          "schemas",
          "HostUpdate",
          "properties",
          "attributes",
          "propertyNames",
          "enum"
        ])

      assert is_list(keys) and keys != [], "HostUpdate.attributes must list the updatable keys"
      refute @unsupported in keys

      assert {422,
              %{"error" => %{"code" => "validation_failed", "details" => %{"attributes" => _}}}} =
               call(c, :patch, path, token, %{"attributes" => %{@unsupported => "x"}})

      case fixture(c.fixtures) do
        nil ->
          :ok

        {key, value} ->
          assert key in keys, "updatable_attribute/0 key #{key} is not in HostUpdate.attributes"
          {status, body} = call(c, :patch, path, token, %{"attributes" => %{key => value}})
          assert status in [200, 202], "PATCH #{path} attributes: #{status} #{inspect(body)}"
      end
    else
      refute get_in(spec, ["components", "schemas", "HostUpdate", "properties", "attributes"])

      assert {422,
              %{"error" => %{"code" => "validation_failed", "details" => %{"attributes" => _}}}} =
               call(c, :patch, path, token, %{"attributes" => %{"folder" => "x"}})
    end
  end

  defp fixture(fixtures) do
    if function_exported?(fixtures, :updatable_attribute, 0), do: fixtures.updatable_attribute()
  end
end
