defmodule MctlContract.ConformanceCase.DeleteGroup do
  @moduledoc """
  Conformance assertions of contract section 13 (delete group), used by
  `MctlContract.ConformanceCase`: `DELETE /groups/{slug}` (capability
  `delete_group`; when `/me` does not list it the route must be 404 and
  absent from the OpenAPI document). Only an unused group may be deleted:
  while a host carries it the answer is 409 and the group stays.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @doc "Checks `delete_group`: served when `/me` lists it, else absent."
  def check(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)

    if "delete_group" in me["capabilities"],
      do: assert_served(c, spec),
      else: assert_absent(c, spec)
  end

  defp assert_served(c, spec) do
    assert get_in(spec, ["paths", "/groups/{slug}", "delete", "x-scope"]) == "setup"
    token = c.fixtures.token(~w(read setup))

    # a group a host carries is not deleted
    used = group!(c, token)
    id = host_id!(c, token, create_host!(c, token, %{"groups" => [used]}))
    {200, %{"data" => host}} = call(c, :get, "/hosts/" <> id, token)
    assert used in host["groups"]

    assert {409, %{"error" => %{"code" => "conflict"}}} =
             call(c, :delete, "/groups/" <> used, token)

    assert used in group_slugs(c, token)

    # an unused group: scope and binding checks, then 204, then 404
    unused = group!(c, token)
    path = "/groups/" <> unused

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
    refute unused in group_slugs(c, token)

    assert {404, %{"error" => %{"code" => "not_found"}}} = call(c, :delete, path, token)
  end

  defp assert_absent(c, spec) do
    refute get_in(spec, ["paths", "/groups/{slug}", "delete"])
    token = c.fixtures.token(~w(read setup))
    unused = group!(c, token)

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :delete, "/groups/" <> unused, token)

    assert unused in group_slugs(c, token)
  end

  defp group!(c, token) do
    s = slug()
    {201, _} = call(c, :post, "/groups", token, %{"slug" => s, "name" => "Conf delete"})
    s
  end

  defp group_slugs(c, token), do: c |> all(token, "/groups") |> Enum.map(& &1["slug"])

  defp bound_token(fixtures, scopes) do
    if function_exported?(fixtures, :bound_token, 1), do: fixtures.bound_token(scopes)
  end
end
