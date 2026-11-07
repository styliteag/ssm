defmodule MctlContract.ConformanceCase.Merge do
  @moduledoc """
  Conformance assertions of contract section 12 (merge), used by
  `MctlContract.ConformanceCase`: `POST /customers/{slug}/merge`
  (capability `merge_customer`; when `/me` does not list it the route must
  be 404 and absent from the OpenAPI document). A merge moves the hosts of
  the source to the target and deletes the source.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @doc "Checks `merge_customer`: served when `/me` lists it, else absent."
  def check(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)

    if "merge_customer" in me["capabilities"],
      do: assert_served(c, spec),
      else: assert_absent(c, spec)
  end

  defp assert_served(c, spec) do
    assert get_in(spec, ["paths", "/customers/{slug}/merge", "post", "x-scope"]) == "setup"
    token = c.fixtures.token(~w(read setup))
    {source, target} = {customer!(c, token), customer!(c, token)}
    id = host_id!(c, token, create_host!(c, token, %{"customer" => source}))
    path = "/customers/" <> source <> "/merge"

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :post, path, c.fixtures.token(~w(read commands)), %{"into" => target})

    case bound_token(c.fixtures, ~w(read setup)) do
      nil ->
        :ok

      bound ->
        assert {403, %{"error" => %{"code" => "forbidden"}}} =
                 call(c, :post, path, bound, %{"into" => target})
    end

    for body <- [%{}, %{"into" => source}, %{"into" => target, "name" => "X"}] do
      assert {422, %{"error" => %{"code" => "validation_failed"}}} =
               call(c, :post, path, token, body)
    end

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :post, path, token, %{"into" => slug()})

    {status, body} = call(c, :post, path, token, %{"into" => target})
    assert status == 200, "POST #{path}: #{status} #{inspect(body)}"
    assert %{"moved_hosts" => moved} = body["data"]
    assert is_integer(moved) and moved >= 1

    {200, %{"data" => host}} = call(c, :get, "/hosts/" <> id, token)
    assert host["customer"] == target
    slugs = c |> all(token, "/customers") |> Enum.map(& &1["slug"])
    assert target in slugs
    refute source in slugs

    # a repeat after success: the source is gone
    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :post, path, token, %{"into" => target})
  end

  defp assert_absent(c, spec) do
    refute Map.has_key?(spec["paths"], "/customers/{slug}/merge")
    token = c.fixtures.token(~w(read setup))
    {source, target} = {customer!(c, token), customer!(c, token)}

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :post, "/customers/" <> source <> "/merge", token, %{"into" => target})
  end

  defp customer!(c, token) do
    s = slug()
    {201, _} = call(c, :post, "/customers", token, %{"slug" => s, "name" => "Conf merge"})
    s
  end

  defp bound_token(fixtures, scopes) do
    if function_exported?(fixtures, :bound_token, 1), do: fixtures.bound_token(scopes)
  end
end
