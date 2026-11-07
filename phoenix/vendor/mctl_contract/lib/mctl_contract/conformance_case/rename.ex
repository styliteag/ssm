defmodule MctlContract.ConformanceCase.Rename do
  @moduledoc """
  Conformance assertions of contract section 11 (rename), used by
  `MctlContract.ConformanceCase`: `PATCH /customers/{slug}` (always
  served) and `PATCH /groups/{slug}` (capability `rename_group`; when `/me`
  does not list it the route must be 404 and absent from the OpenAPI
  document). A rename changes only `name`, never the slug.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @doc "Rename a fresh customer: 200, slug kept, idempotent, 404, 422, 403."
  def check_customer(c), do: assert_rename(c, "/customers")

  @doc "Checks `rename_group`: served when `/me` lists it, else absent."
  def check_group(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)

    if "rename_group" in me["capabilities"] do
      assert get_in(spec, ["paths", "/groups/{slug}", "patch", "x-scope"]) == "setup"
      assert_rename(c, "/groups")
    else
      refute Map.has_key?(spec["paths"], "/groups/{slug}")
      token = c.fixtures.token(~w(read setup))
      s = slug()
      {201, _} = call(c, :post, "/groups", token, %{"slug" => s, "name" => "Conf"})
      assert {404, _} = call(c, :patch, "/groups/" <> s, token, %{"name" => "Other"})
    end
  end

  defp assert_rename(c, collection) do
    token = c.fixtures.token(~w(read setup))
    s = slug()
    path = collection <> "/" <> s
    {201, _} = call(c, :post, collection, token, %{"slug" => s, "name" => "Conf"})

    for _ <- 1..2 do
      {status, body} = call(c, :patch, path, token, %{"name" => "Conf renamed"})
      assert status == 200, "PATCH #{path}: #{status} #{inspect(body)}"
      assert body["data"] == %{"slug" => s, "name" => "Conf renamed"}
    end

    listed = Enum.find(all(c, token, collection), &(&1["slug"] == s))
    assert listed == %{"slug" => s, "name" => "Conf renamed"}

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :patch, collection <> "/" <> slug(), token, %{"name" => "X"})

    for body <- [%{"name" => ""}, %{"name" => "X", "slug" => slug()}] do
      assert {422, %{"error" => %{"code" => "validation_failed"}}} =
               call(c, :patch, path, token, body)
    end

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :patch, path, c.fixtures.token(~w(read commands)), %{"name" => "X"})
  end
end
