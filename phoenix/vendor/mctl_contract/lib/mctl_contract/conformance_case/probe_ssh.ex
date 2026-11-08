defmodule MctlContract.ConformanceCase.ProbeSsh do
  @moduledoc """
  Conformance assertions of contract section 15 (SSH probe), used by
  `MctlContract.ConformanceCase`: `POST /probe/ssh` (capability
  `probe_ssh`; when `/me` does not list it the route must be 404 and absent
  from the OpenAPI document). Served: the shape checks answer 422, a token
  without `setup` 403, and with the optional fixture `ssh_probe_target/0`
  a probe of that target answers 200 with one result per port.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @path "/probe/ssh"

  @doc "Checks `probe_ssh`: served when `/me` lists it, else absent."
  def check(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)

    if "probe_ssh" in me["capabilities"],
      do: assert_served(c, spec),
      else: assert_absent(c, spec)
  end

  defp assert_served(c, spec) do
    assert get_in(spec, ["paths", @path, "post", "x-scope"]) == "setup"
    token = c.fixtures.token(~w(read setup))

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :post, @path, c.fixtures.token(~w(read commands)), valid())

    for {body, field} <- invalid_bodies() do
      assert {422, %{"error" => %{"code" => "validation_failed", "details" => details}}} =
               call(c, :post, @path, token, body),
             "#{inspect(body)} must be 422"

      assert Map.has_key?(details, field), "#{inspect(body)}: no error on #{field}"
    end

    case target(c.fixtures) do
      nil ->
        :ok

      {address, port} ->
        body = %{"address" => address, "ports" => [port]}
        assert {200, %{"data" => data}} = call(c, :post, @path, token, body)
        assert data["address"] == address
        assert data["via"] == nil
        assert [%{"port" => ^port, "open" => true} = result] = data["results"]
        assert Map.has_key?(result, "banner") and Map.has_key?(result, "error")
    end
  end

  defp assert_absent(c, spec) do
    refute get_in(spec, ["paths", @path, "post"])

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :post, @path, c.fixtures.token(~w(read setup)), valid())
  end

  defp valid, do: %{"address" => "192.0.2.10", "ports" => [22]}

  defp invalid_bodies do
    long = String.duplicate("a", 254)

    [
      {%{"ports" => [22]}, "address"},
      {%{"address" => "", "ports" => [22]}, "address"},
      {%{"address" => "a b", "ports" => [22]}, "address"},
      {%{"address" => long, "ports" => [22]}, "address"},
      {%{"address" => "192.0.2.10"}, "ports"},
      {%{"address" => "192.0.2.10", "ports" => []}, "ports"},
      {%{"address" => "192.0.2.10", "ports" => [1, 2, 3, 4, 5, 6]}, "ports"},
      {%{"address" => "192.0.2.10", "ports" => [22, 22]}, "ports"},
      {%{"address" => "192.0.2.10", "ports" => [0]}, "ports"},
      {%{"address" => "192.0.2.10", "ports" => [70_000]}, "ports"},
      {%{"address" => "192.0.2.10", "ports" => [22], "jump_via" => ""}, "jump_via"},
      {%{"address" => "192.0.2.10", "ports" => [22], "user" => "root"}, "user"}
    ]
  end

  defp target(fixtures) do
    if function_exported?(fixtures, :ssh_probe_target, 0), do: fixtures.ssh_probe_target()
  end
end
