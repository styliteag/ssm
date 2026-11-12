defmodule MctlContract.ConformanceCase do
  @moduledoc """
  ExUnit case template every tool runs against its own endpoint: the same
  requests and assertions everywhere.

      defmodule MyAppWeb.MctlConformanceTest do
        use MctlContract.ConformanceCase,
          endpoint: MyAppWeb.Endpoint,
          base: "/api/mctl/v1",
          fixtures: MyApp.MctlFixtures
      end

  `endpoint` is any plug (`init/1`, `call/2`), usually the Phoenix
  endpoint. `fixtures` implements `MctlContract.ConformanceCase.Fixtures`.
  The tests run with `async: false`.
  """
  use ExUnit.CaseTemplate

  defmodule Fixtures do
    @moduledoc """
    What a tool provides to the conformance tests.

      * `setup(context)` (optional) – e.g. check out the Ecto sandbox
      * `token(scopes)` – a valid plain token with exactly these scopes
      * `valid_host_params()` – a `POST /hosts` body the tool accepts
        (the test sets `name`, `customer` and `groups` itself)
      * `unsupported_mode()` (optional) – a mode the tool refuses, or nil
        (then the test sends an unknown mode)
      * `cleanup()` (optional) – runs after every test
      * `person_key()` (optional, capability `people`) – the key of a
        person the tool knows (`GET /people/{key}` shape check), or nil
      * `bound_token(scopes)` (optional, capabilities `merge_customer`,
        `delete_group` and `delete_customer`) – a valid token with these
        scopes and a binding (not global), or nil when the tool has no
        bindings; a merge or a group/customer delete with it must be 403
        `forbidden`
      * `ssh_probe_target()` (optional, capability `probe_ssh`) –
        `{address, port}` of something the tool can reach in tests where
        a TCP connection is accepted (an SSH server, ideally), or nil to
        skip the happy path
      * `updatable_attribute()` (optional, capability `update_attributes`)
        – `{key, value}` of a host attribute the tool accepts in
        `PATCH /hosts/{id}` for any freshly created host (e.g.
        `{"folder", ""}`), or nil to skip the happy path
      * `mode_host_params(mode)` (optional, `mode:<m>` capabilities) – the
        extra `POST /hosts` params a listed mode needs (e.g. for `relay`
        `%{"attributes" => %{"relay_ref" => "…"}}`; `%{}` when none), or
        nil to skip that mode's happy path
    """
    @callback setup(map()) :: :ok | keyword() | map()
    @callback token([String.t()]) :: String.t()
    @callback valid_host_params() :: map()
    @callback unsupported_mode() :: String.t() | nil
    @callback cleanup() :: any()
    @callback person_key() :: String.t() | nil
    @callback bound_token([String.t()]) :: String.t() | nil
    @callback ssh_probe_target() :: {String.t(), pos_integer()} | nil
    @callback updatable_attribute() :: {String.t(), term()} | nil
    @callback mode_host_params(String.t()) :: map() | nil
    @optional_callbacks setup: 1,
                        unsupported_mode: 0,
                        cleanup: 0,
                        person_key: 0,
                        bound_token: 1,
                        ssh_probe_target: 0,
                        updatable_attribute: 0,
                        mode_host_params: 1
  end

  using opts do
    quote do
      use ExUnit.Case, async: false
      import MctlContract.ConformanceCase.Helpers

      @mctl_conformance Map.new(unquote(opts))

      setup context do
        MctlContract.ConformanceCase.Helpers.setup_fixtures(@mctl_conformance, context)
      end

      test "conformance: requests without a token are 401 in the envelope", %{mctl: c} do
        for path <- ["/me", "/hosts", "/customers", "/groups", "/jobs"] do
          {status, body} = call(c, :get, path, nil)
          assert status == 401, path
          assert %{"error" => %{"code" => "unauthorized", "message" => m}} = body
          assert is_binary(m)
          assert Map.has_key?(body["error"], "details")
        end

        assert {401, _} = call(c, :get, "/me", "invalid-token-value")
      end

      test "conformance: a missing scope is 403 insufficient_scope", %{mctl: c} do
        read = c.fixtures.token(["read"])
        {status, body} = call(c, :post, "/customers", read, %{"slug" => slug(), "name" => "X"})
        assert status == 403
        assert body["error"]["code"] == "insufficient_scope"
      end

      test "conformance: GET /openapi.json is public OpenAPI 3.1", %{mctl: c} do
        {200, spec} = call(c, :get, "/openapi.json", nil)
        assert spec["openapi"] == "3.1.0"

        for path <-
              ~w(/me /hosts /hosts/{id} /customers /customers/{slug} /groups /jobs /jobs/{id}) do
          assert Map.has_key?(spec["paths"], path), path
        end
      end

      test "conformance: GET /me", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        {200, %{"data" => me, "meta" => meta}} = call(c, :get, "/me", token)
        assert is_map(meta)
        assert is_binary(me["product"]) and is_binary(me["version"])
        assert me["contract_version"] == "1"
        assert Enum.sort(me["scopes"]) == ["read", "setup"]
        assert %{"name" => name, "prefix" => prefix} = me["token"]
        assert is_binary(name)
        assert String.starts_with?(token, prefix)
      end

      test "conformance: GET /hosts shape and cursor round trip", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        create_host!(c, token, %{})
        create_host!(c, token, %{})

        {200, page1} = call(c, :get, "/hosts?limit=1", token)
        assert %{"data" => [h1], "meta" => %{"limit" => 1, "next_cursor" => cursor}} = page1
        assert is_binary(cursor)
        assert_host_shape(h1)

        {200, page2} =
          call(c, :get, "/hosts?limit=1&cursor=" <> URI.encode_www_form(cursor), token)

        assert [h2] = page2["data"]
        assert h2["id"] != h1["id"]

        assert {400, %{"error" => %{"code" => "bad_request"}}} =
                 call(c, :get, "/hosts?cursor=garbage", token)

        {200, one} = call(c, :get, "/hosts/" <> URI.encode(h1["id"]), token)
        assert one["data"]["id"] == h1["id"]

        assert {404, %{"error" => %{"code" => "not_found"}}} =
                 call(c, :get, "/hosts/999999999", token)

        assert {200, _} =
                 call(c, :get, "/hosts?changed_after=2000-01-01T00:00:00Z", token)
      end

      test "conformance: POST /customers and GET /customers", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        s = slug()

        {201, %{"data" => created}} =
          call(c, :post, "/customers", token, %{"slug" => s, "name" => "Conformance"})

        assert created == %{"slug" => s, "name" => "Conformance"}

        assert Enum.any?(all(c, token, "/customers"), &(&1["slug"] == s))

        {200, %{"data" => renamed}} =
          call(c, :patch, "/customers/" <> s, token, %{"name" => "Conformance 2"})

        assert renamed == %{"slug" => s, "name" => "Conformance 2"}

        assert {409, %{"error" => %{"code" => "conflict"}}} =
                 call(c, :post, "/customers", token, %{"slug" => s, "name" => "Again"})

        assert {422, %{"error" => %{"code" => "validation_failed", "details" => %{"slug" => _}}}} =
                 call(c, :post, "/customers", token, %{"slug" => "Not A Slug", "name" => "X"})
      end

      test "conformance: POST /groups and GET /groups", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        s = slug()

        {201, %{"data" => created}} =
          call(c, :post, "/groups", token, %{"slug" => s, "name" => "Conf"})

        assert created == %{"slug" => s, "name" => "Conf"}
        assert Enum.any?(all(c, token, "/groups"), &(&1["slug"] == s))
      end

      test "conformance: POST /hosts is 202 with a job readable via GET /jobs", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        job = create_host!(c, token, %{})
        assert_job_shape(job)

        {200, %{"data" => again}} = call(c, :get, "/jobs/" <> job["id"], token)
        assert again["id"] == job["id"]
        assert_job_shape(again)

        {200, %{"data" => listed}} = call(c, :get, "/jobs?limit=1000", token)
        assert Enum.any?(listed, &(&1["id"] == job["id"]))

        assert {404, _} = call(c, :get, "/jobs/999999999", token)
      end

      test "conformance: PATCH /hosts/{id} assigns customer and groups", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        customer = slug()
        group = slug()
        {201, _} = call(c, :post, "/customers", token, %{"slug" => customer, "name" => "C"})
        {201, _} = call(c, :post, "/groups", token, %{"slug" => group, "name" => "G"})

        id = host_id!(c, token, create_host!(c, token, %{}))

        {status, body} =
          call(c, :patch, "/hosts/" <> id, token, %{"customer" => customer, "groups" => [group]})

        assert status == 200, inspect(body)
        assert body["data"]["customer"] == customer
        assert body["data"]["groups"] == [group]

        {200, %{"data" => host}} = call(c, :get, "/hosts/" <> id, token)
        assert host["customer"] == customer
        assert group in host["groups"]

        {200, %{"data" => filtered}} =
          call(c, :get, "/hosts?customer=#{customer}&group=#{group}", token)

        assert Enum.map(filtered, & &1["id"]) == [id]
      end

      test "conformance: an unsupported mode is 422 on mode", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        mode = unsupported_mode(c.fixtures)
        body = Map.merge(host_params(c), %{"mode" => mode})
        {status, resp} = call(c, :post, "/hosts", token, body)
        assert status == 422, inspect(resp)
        assert resp["error"]["code"] == "validation_failed"
        assert Map.has_key?(resp["error"]["details"], "mode")
      end

      test "conformance: host summaries are served exactly when /me advertises them", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        {200, %{"data" => me}} = call(c, :get, "/me", token)
        assert is_list(me["capabilities"])
        {200, spec} = call(c, :get, "/openapi.json", nil)

        if "host_summaries" in me["capabilities"] do
          assert_summaries_served(c, token, spec)
        else
          assert_summaries_absent(c, token, spec)
        end
      end

      test "conformance: host actions are served exactly when /me advertises them", %{mctl: c} do
        {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
        {200, spec} = call(c, :get, "/openapi.json", nil)
        actions = advertised_actions(me["capabilities"])

        if actions == [],
          do: assert_actions_absent(c, spec),
          else: assert_actions_served(c, spec, actions)
      end

      # contract section 10: each capability is served exactly when /me
      # advertises it
      test "conformance: delete_host is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.Lifecycle.check(c, "delete_host")
      end

      test "conformance: maintenance is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.Lifecycle.check(c, "maintenance")
      end

      test "conformance: people is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.Lifecycle.check(c, "people")
      end

      # contract section 11: rename changes only the name, never the slug
      test "conformance: PATCH /customers/{slug} renames a customer", %{mctl: c} do
        MctlContract.ConformanceCase.Rename.check_customer(c)
      end

      test "conformance: rename_group is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.Rename.check_group(c)
      end

      # contract section 12: merge moves the hosts and deletes the source
      test "conformance: merge_customer is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.Merge.check(c)
      end

      # contract section 13: only an unused group is deleted
      test "conformance: delete_group is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.DeleteGroup.check(c)
      end

      # contract section 14: only an empty customer is deleted
      test "conformance: delete_customer is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.DeleteCustomer.check(c)
      end

      # contract section 15: a narrow SSH reachability probe from the tool
      test "conformance: probe_ssh is served exactly when /me advertises it", %{mctl: c} do
        MctlContract.ConformanceCase.ProbeSsh.check(c)
      end

      # contract section 16: host attributes in PATCH /hosts/{id}
      test "conformance: PATCH /hosts/{id} attributes follow update_attributes", %{mctl: c} do
        MctlContract.ConformanceCase.UpdateAttributes.check(c)
      end

      # contract section 17: the modes a tool lists (mode:<m>) and no others
      test "conformance: POST /hosts accepts exactly the modes /me lists", %{mctl: c} do
        MctlContract.ConformanceCase.Modes.check(c)
      end

      test "conformance: Idempotency-Key replays the first response", %{mctl: c} do
        token = c.fixtures.token(~w(read setup))
        body = %{"slug" => slug(), "name" => "Idem"}
        key = [{"idempotency-key", "conf-" <> slug()}]

        {201, first} = call(c, :post, "/customers", token, body, key)
        {201, again, headers} = call_full(c, :post, "/customers", token, body, key)
        assert again == first
        assert {"idempotent-replayed", "true"} in headers

        other = Map.put(body, "name", "Other")

        assert {422, %{"error" => %{"code" => "idempotency_key_reused"}}} =
                 call(c, :post, "/customers", token, other, key)
      end
    end
  end
end
