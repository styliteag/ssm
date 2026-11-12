defmodule MctlContract.ConformanceCase.Helpers do
  @moduledoc "Request and assertion helpers of `MctlContract.ConformanceCase`."
  import ExUnit.Assertions

  @host_keys ~w(id name addresses mode kind customer groups ui_url updated_at identity attributes)
  @identity_keys ~w(machine_id product_uuid macs ssh_host_keys observed_at)
  @job_keys ~w(id kind state host_id progress result error created_at finished_at)

  @doc false
  def setup_fixtures(config, context) do
    fixtures = config.fixtures
    Code.ensure_loaded!(fixtures)

    extra =
      if function_exported?(fixtures, :setup, 1),
        do: fixtures.setup(context) |> to_map(),
        else: %{}

    if function_exported?(fixtures, :cleanup, 0),
      do: ExUnit.Callbacks.on_exit(fn -> fixtures.cleanup() end)

    {:ok, Map.put(extra, :mctl, config)}
  end

  defp to_map(:ok), do: %{}
  defp to_map(kw) when is_list(kw), do: Map.new(kw)
  defp to_map(map) when is_map(map), do: map

  @doc "`{status, decoded_body}`."
  def call(c, method, path, token, body \\ nil, headers \\ []) do
    {status, decoded, _headers} = call_full(c, method, path, token, body, headers)
    {status, decoded}
  end

  @doc "`{status, decoded_body, resp_headers}`."
  def call_full(c, method, path, token, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil ->
          Plug.Test.conn(method, c.base <> path)

        body ->
          Plug.Test.conn(method, c.base <> path, Jason.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
      end

    conn =
      conn
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> then(
        &Enum.reduce(headers, &1, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      )
      |> then(fn conn ->
        if token,
          do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
          else: conn
      end)

    conn = c.endpoint.call(conn, c.endpoint.init([]))
    {conn.status, decode(conn.resp_body), conn.resp_headers}
  end

  defp decode(""), do: nil
  defp decode(body), do: Jason.decode!(body)

  @doc "A fresh slug."
  def slug,
    do: "conf-" <> (:crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false))

  @doc "Host params of the fixtures with a fresh name."
  def host_params(c) do
    c.fixtures.valid_host_params()
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("name", slug())
  end

  @doc "POST /hosts, asserting 202 and a job; returns the job."
  def create_host!(c, token, extra) do
    {status, body} = call(c, :post, "/hosts", token, Map.merge(host_params(c), extra))
    assert status == 202, "POST /hosts: #{status} #{inspect(body)}"
    body["data"]
  end

  @doc "The host id of a create job, waiting up to ~5 s for it to appear."
  def host_id!(c, token, job, tries \\ 50) do
    case job["host_id"] do
      id when is_binary(id) ->
        id

      nil when tries > 0 ->
        Process.sleep(100)
        {200, %{"data" => job}} = call(c, :get, "/jobs/" <> job["id"], token)
        host_id!(c, token, job, tries - 1)

      nil ->
        flunk("job #{job["id"]} never got a host_id")
    end
  end

  @doc "Every item of a paged collection."
  def all(c, token, path, cursor \\ nil, acc \\ []) do
    query =
      if cursor, do: "?limit=1000&cursor=" <> URI.encode_www_form(cursor), else: "?limit=1000"

    {200, %{"data" => data, "meta" => meta}} = call(c, :get, path <> query, token)

    case meta["next_cursor"] do
      nil -> acc ++ data
      next -> all(c, token, path, next, acc ++ data)
    end
  end

  def unsupported_mode(fixtures) do
    if function_exported?(fixtures, :unsupported_mode, 0),
      do: fixtures.unsupported_mode() || "carrier-pigeon",
      else: "carrier-pigeon"
  end

  def assert_host_shape(h) do
    assert Enum.sort(Map.keys(h)) == Enum.sort(@host_keys)
    assert is_binary(h["id"]) and is_binary(h["name"])
    assert is_list(h["addresses"]) and is_list(h["groups"])
    assert h["mode"] in ["push", "pull", "relay", "snmp", nil]
    assert h["kind"] in ~w(linux freebsd windows firewall snmp other)
    assert is_map(h["attributes"])
    assert_time(h["updated_at"])
    assert Enum.sort(Map.keys(h["identity"])) == Enum.sort(@identity_keys)
    assert Enum.all?(h["identity"]["macs"], &Regex.match?(~r/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/, &1))
  end

  @summary_keys ~w(host_id state reason counts items checked_at updated_at)
  @summary_states ~w(ok warn crit unknown pending)

  @doc "Both summary routes work, are paged and filterable (capability present)."
  def assert_summaries_served(c, token, spec) do
    assert Map.has_key?(spec["paths"], "/host-summaries")
    assert Map.has_key?(spec["paths"], "/hosts/{id}/summary")
    assert Map.has_key?(spec["components"]["schemas"], "HostSummary")

    id1 = host_id!(c, token, create_host!(c, token, %{}))
    id2 = host_id!(c, token, create_host!(c, token, %{}))

    {200, %{"data" => one}} = call(c, :get, "/hosts/" <> URI.encode(id1) <> "/summary", token)
    assert_summary_shape(one)
    assert one["host_id"] == id1

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :get, "/hosts/999999999/summary", token)

    {200, %{"data" => [first], "meta" => %{"limit" => 1, "next_cursor" => cursor}}} =
      call(c, :get, "/host-summaries?limit=1", token)

    assert_summary_shape(first)
    assert is_binary(cursor)

    {200, %{"data" => [second]}} =
      call(c, :get, "/host-summaries?limit=1&cursor=" <> URI.encode_www_form(cursor), token)

    assert second["host_id"] != first["host_id"]

    listed = all(c, token, "/host-summaries")
    Enum.each(listed, &assert_summary_shape/1)
    ids = Enum.map(listed, & &1["host_id"])
    assert id1 in ids and id2 in ids

    {200, %{"data" => only}} = call(c, :get, "/host-summaries?host_id=" <> URI.encode(id2), token)
    assert Enum.map(only, & &1["host_id"]) == [id2]

    {200, %{"data" => none}} =
      call(c, :get, "/host-summaries?changed_after=2999-01-01T00:00:00Z", token)

    assert none == []

    assert {400, %{"error" => %{"code" => "bad_request"}}} =
             call(c, :get, "/host-summaries?changed_after=yesterday", token)

    assert {403, _} =
             call(c, :get, "/host-summaries", c.fixtures.token(["setup"]))
  end

  @doc "Both summary routes are 404 and not in the OpenAPI document."
  def assert_summaries_absent(c, token, spec) do
    refute Map.has_key?(spec["paths"], "/host-summaries")
    refute Map.has_key?(spec["paths"], "/hosts/{id}/summary")

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :get, "/host-summaries", token)

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :get, "/hosts/1/summary", token)
  end

  @doc "Action names of the `action:<name>` entries in `capabilities`."
  def advertised_actions(capabilities) do
    for "action:" <> name <- capabilities, do: name
  end

  @doc """
  `POST /hosts/{id}/actions` is documented with exactly the advertised
  actions, needs scope `commands` and refuses unknown actions with 422
  (capability present). Never runs a real action.
  """
  def assert_actions_served(c, spec, actions) do
    op = get_in(spec, ["paths", "/hosts/{id}/actions", "post"])
    assert op, "OpenAPI lacks POST /hosts/{id}/actions"
    assert op["x-scope"] == "commands"

    assert Enum.sort(spec["components"]["schemas"]["HostAction"]["properties"]["action"]["enum"]) ==
             Enum.sort(actions)

    path = "/hosts/999999999/actions"
    known = %{"action" => hd(actions), "params" => %{}}

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :post, path, c.fixtures.token(~w(read setup)), known)

    commands = c.fixtures.token(["commands"])

    assert {422, %{"error" => %{"code" => "validation_failed", "details" => details}}} =
             call(c, :post, path, commands, %{"action" => "conformance-unknown", "params" => %{}})

    assert details == %{"action" => ["not supported"]}

    assert {422, %{"error" => %{"details" => %{"action" => _}}}} =
             call(c, :post, path, commands, %{"params" => %{}})
  end

  @doc "`POST /hosts/{id}/actions` is 404 and not in the OpenAPI document."
  def assert_actions_absent(c, spec) do
    refute Map.has_key?(spec["paths"], "/hosts/{id}/actions")

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :post, "/hosts/1/actions", c.fixtures.token(["commands"]), %{
               "action" => "probe"
             })
  end

  def assert_summary_shape(s) do
    assert Enum.sort(Map.keys(s)) == Enum.sort(@summary_keys)
    assert is_binary(s["host_id"])
    assert s["state"] in @summary_states
    assert s["reason"] == nil or is_binary(s["reason"])
    assert_keys(s["counts"], ~w(ok warn crit unknown), ~w(handled))
    assert Enum.all?(Map.values(s["counts"]), &(is_integer(&1) and &1 >= 0))
    assert is_list(s["items"]) and length(s["items"]) <= 50

    for i <- s["items"] do
      assert_keys(i, ~w(name state text since), ~w(acknowledged in_downtime))
      assert Map.get(i, "acknowledged", false) in [true, false]
      assert Map.get(i, "in_downtime", false) in [true, false]
      assert is_binary(i["name"])
      assert i["state"] in ~w(warn crit unknown)
      assert_time(i["since"])
    end

    assert_time(s["checked_at"])
    assert_time(s["updated_at"])
  end

  # Required keys all present, nothing beyond required + optional (C4 handled
  # flags are optional so tools on an older library stay conformant).
  defp assert_keys(map, required, optional) do
    keys = Map.keys(map)
    assert required -- keys == []
    assert keys -- (required ++ optional) == []
  end

  def assert_job_shape(j) do
    assert Enum.sort(Map.keys(j)) == Enum.sort(@job_keys)
    assert is_binary(j["id"])
    assert j["state"] in ~w(queued running succeeded failed)
    assert_time(j["created_at"])
  end

  defp assert_time(nil), do: :ok

  defp assert_time(t) do
    assert String.ends_with?(t, "Z"), "time #{t} must be UTC with Z"
    assert {:ok, _, 0} = DateTime.from_iso8601(t)
  end
end
