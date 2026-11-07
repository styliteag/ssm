defmodule MctlContract.ConformanceCase.DeleteCustomer do
  @moduledoc """
  Conformance assertions of contract section 14 (delete customer), used by
  `MctlContract.ConformanceCase`: `DELETE /customers/{slug}` (capability
  `delete_customer`; when `/me` does not list it the route must be 404 and
  absent from the OpenAPI document). Only an empty customer may be deleted:
  while a host belongs to it the answer is 409 and the customer stays.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @doc "Checks `delete_customer`: served when `/me` lists it, else absent."
  def check(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)

    if "delete_customer" in me["capabilities"],
      do: assert_served(c, spec),
      else: assert_absent(c, spec)
  end

  defp assert_served(c, spec) do
    assert get_in(spec, ["paths", "/customers/{slug}", "delete", "x-scope"]) == "setup"
    token = c.fixtures.token(~w(read setup))

    # a customer with a host is not deleted
    used = customer!(c, token)
    id = host_id!(c, token, create_host!(c, token, %{"customer" => used}))
    {200, %{"data" => host}} = call(c, :get, "/hosts/" <> id, token)
    assert host["customer"] == used

    assert {409, %{"error" => %{"code" => "conflict"}}} =
             call(c, :delete, "/customers/" <> used, token)

    assert used in customer_slugs(c, token)

    # an empty customer: scope and binding checks, then 204, then 404
    empty = customer!(c, token)
    path = "/customers/" <> empty

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :delete, path, c.fixtures.token(~w(read commands)))

    case bound_token(c.fixtures, ~w(read setup)) do
      nil ->
        :ok

      bound ->
        assert {403, %{"error" => %{"code" => "forbidden"}}} = call(c, :delete, path, bound)
    end

    {status, body} = call(c, :delete, path, token)
    assert status == 204, "DELETE #{path}: #{status} #{inspect(body)}"
    refute empty in customer_slugs(c, token)

    assert {404, %{"error" => %{"code" => "not_found"}}} = call(c, :delete, path, token)
  end

  defp assert_absent(c, spec) do
    refute get_in(spec, ["paths", "/customers/{slug}", "delete"])
    token = c.fixtures.token(~w(read setup))
    empty = customer!(c, token)

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :delete, "/customers/" <> empty, token)

    assert empty in customer_slugs(c, token)
  end

  defp customer!(c, token) do
    s = slug()
    {201, _} = call(c, :post, "/customers", token, %{"slug" => s, "name" => "Conf delete"})
    s
  end

  defp customer_slugs(c, token), do: c |> all(token, "/customers") |> Enum.map(& &1["slug"])

  defp bound_token(fixtures, scopes) do
    if function_exported?(fixtures, :bound_token, 1), do: fixtures.bound_token(scopes)
  end
end
