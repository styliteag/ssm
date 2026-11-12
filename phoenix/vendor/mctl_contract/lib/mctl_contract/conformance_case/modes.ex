defmodule MctlContract.ConformanceCase.Modes do
  @moduledoc """
  Conformance assertions of contract section 17 (host modes, optional
  `modes/0`), used by `MctlContract.ConformanceCase`. With `mode:<m>`
  capabilities in `/me`, a contract mode the tool does not list is `422`
  on `mode`, and with the optional fixture `mode_host_params/1` (extra
  `POST /hosts` params a mode needs, e.g. `relay`'s
  `attributes.relay_ref`, or nil to skip) every listed mode creates a
  host (`202`). Without `mode:` capabilities nothing is checked here (the
  tool checks modes itself; see the `unsupported_mode` test).
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @doc "Checks the `mode:<m>` capabilities against `POST /hosts`."
  def check(c) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    token = c.fixtures.token(~w(read setup))

    case for("mode:" <> m <- me["capabilities"], do: m) do
      [] ->
        :ok

      modes ->
        for m <- MctlContract.Params.modes() -- modes do
          assert {422, %{"error" => %{"details" => %{"mode" => _}}}} =
                   call(c, :post, "/hosts", token, Map.merge(host_params(c), %{"mode" => m})),
                 "mode #{m} is not in /me but POST /hosts did not refuse it"
        end

        for m <- modes, extra = fixture(c.fixtures, m), extra != nil do
          create_host!(c, token, Map.put(extra, "mode", m))
        end

        :ok
    end
  end

  defp fixture(fixtures, mode) do
    if function_exported?(fixtures, :mode_host_params, 1), do: fixtures.mode_host_params(mode)
  end
end
