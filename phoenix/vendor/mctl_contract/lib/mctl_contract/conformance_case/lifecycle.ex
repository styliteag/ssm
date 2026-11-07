defmodule MctlContract.ConformanceCase.Lifecycle do
  @moduledoc """
  Conformance assertions of contract section 10 (capabilities
  `delete_host`, `maintenance`, `people`), used by
  `MctlContract.ConformanceCase`. Each capability is checked when `/me`
  advertises it, else its routes must be 404 and absent from the OpenAPI
  document. People checks never remove a real person.
  """
  import ExUnit.Assertions
  import MctlContract.ConformanceCase.Helpers

  @maintenance_keys ~w(id host_id start end comment author state)
  @person_keys ~w(key operator emails keys authorizations)
  @maintenance_paths ["/hosts/{id}/maintenance", "/maintenance", "/maintenance/{id}"]

  @doc "Checks one capability: served when `/me` lists it, else absent."
  def check(c, capability) do
    {200, %{"data" => me}} = call(c, :get, "/me", c.fixtures.token(["read"]))
    {200, spec} = call(c, :get, "/openapi.json", nil)
    served? = capability in me["capabilities"]

    case {capability, served?} do
      {"delete_host", true} -> assert_delete_served(c, spec)
      {"delete_host", false} -> assert_delete_absent(c, spec)
      {"maintenance", true} -> assert_maintenance_served(c, spec)
      {"maintenance", false} -> assert_maintenance_absent(c, spec)
      {"people", true} -> assert_people_served(c, spec)
      {"people", false} -> assert_people_absent(c, spec)
    end
  end

  @doc "`DELETE /hosts/{id}` deletes a fresh host via a `delete_host` job."
  def assert_delete_served(c, spec) do
    assert get_in(spec, ["paths", "/hosts/{id}", "delete", "x-scope"]) == "setup"
    token = c.fixtures.token(~w(read setup))
    id = host_id!(c, token, create_host!(c, token, %{}))

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :delete, "/hosts/" <> id, c.fixtures.token(~w(read commands)))

    {status, body} = call(c, :delete, "/hosts/" <> id, token)
    assert status == 202, "DELETE /hosts/#{id}: #{status} #{inspect(body)}"
    job = body["data"]
    assert_job_shape(job)
    assert job["kind"] == "delete_host"
    assert job["host_id"] == id

    done = wait_job(c, token, job)
    assert done["state"] == "succeeded", inspect(done)
    # tools may add details (e.g. the dashboard's `agent`)
    assert done["result"]["deleted"] == true
    assert {404, _} = call(c, :get, "/hosts/" <> id, token)

    assert {404, %{"error" => %{"code" => "not_found"}}} =
             call(c, :delete, "/hosts/999999999", token)
  end

  @doc "`DELETE /hosts/{id}` is 404 and not documented."
  def assert_delete_absent(c, spec) do
    refute Map.has_key?(spec["paths"]["/hosts/{id}"], "delete")
    token = c.fixtures.token(~w(read setup))
    id = host_id!(c, token, create_host!(c, token, %{}))
    assert {404, _} = call(c, :delete, "/hosts/" <> id, token)
    assert {200, _} = call(c, :get, "/hosts/" <> id, token)
  end

  @doc "Create, list, cancel a future window on a fresh host."
  def assert_maintenance_served(c, spec) do
    for p <- @maintenance_paths,
        do: assert(Map.has_key?(spec["paths"], p), p)

    token = c.fixtures.token(~w(read setup))
    id = host_id!(c, token, create_host!(c, token, %{}))
    path = "/hosts/" <> id <> "/maintenance"
    body = window(3600, 7200)

    assert {403, _} = call(c, :post, path, c.fixtures.token(~w(read commands)), body)

    {status, resp} = call(c, :post, path, token, body)
    assert status == 201, "POST #{path}: #{status} #{inspect(resp)}"
    m = resp["data"]
    assert_maintenance_shape(m)
    assert m["host_id"] == id
    assert m["state"] == "planned"

    listed = for_host(c, token, id)
    assert Enum.any?(listed, &(&1["id"] == m["id"]))
    Enum.each(listed, &assert_maintenance_shape/1)

    assert {422, %{"error" => %{"code" => "validation_failed", "details" => %{"end" => _}}}} =
             call(c, :post, path, token, window(7200, 3600))

    assert {404, _} = call(c, :post, "/hosts/999999999/maintenance", token, body)
    assert {403, _} = call(c, :get, "/maintenance", c.fixtures.token(["setup"]))

    assert {204, nil} = call(c, :delete, "/maintenance/" <> URI.encode(m["id"]), token)

    after_cancel = for_host(c, token, id)

    assert Enum.all?(after_cancel, &(&1["id"] != m["id"] or &1["state"] == "cancelled")),
           inspect(after_cancel)

    assert {404, _} = call(c, :delete, "/maintenance/999999999", token)
  end

  @doc "The maintenance routes are 404 and not documented."
  def assert_maintenance_absent(c, spec) do
    for p <- @maintenance_paths,
        do: refute(Map.has_key?(spec["paths"], p), p)

    token = c.fixtures.token(~w(read setup))
    assert {404, _} = call(c, :post, "/hosts/1/maintenance", token, window(3600, 7200))
    assert {404, _} = call(c, :get, "/maintenance", token)
    assert {404, _} = call(c, :delete, "/maintenance/1", token)
  end

  @doc """
  `GET /people/{key}` (404 unknown, 400 malformed, shape of the fixtures'
  `person_key/0` when given) and the scope and 404 of `remove`.
  """
  def assert_people_served(c, spec) do
    assert Map.has_key?(spec["paths"], "/people/{key}")
    assert Map.has_key?(spec["paths"], "/people/{key}/remove")
    read = c.fixtures.token(["read"])
    unknown = person_path("email:conformance-" <> slug() <> "@example.invalid")

    assert {404, %{"error" => %{"code" => "not_found"}}} = call(c, :get, unknown, read)
    assert {400, %{"error" => %{"code" => "bad_request"}}} = call(c, :get, "/people/nobody", read)

    assert {403, %{"error" => %{"code" => "insufficient_scope"}}} =
             call(c, :post, unknown <> "/remove", c.fixtures.token(~w(read setup)), %{})

    assert {404, _} = call(c, :post, unknown <> "/remove", c.fixtures.token(["commands"]), %{})

    case person_key(c.fixtures) do
      nil ->
        :ok

      key ->
        {200, %{"data" => p}} = call(c, :get, person_path(key), read)
        assert_person_shape(p)
        assert p["key"] == key
    end
  end

  @doc "The people routes are 404 and not documented."
  def assert_people_absent(c, spec) do
    refute Map.has_key?(spec["paths"], "/people/{key}")
    path = person_path("email:a@example.invalid")
    assert {404, _} = call(c, :get, path, c.fixtures.token(["read"]))
    assert {404, _} = call(c, :post, path <> "/remove", c.fixtures.token(["commands"]), %{})
  end

  def assert_maintenance_shape(m) do
    assert Enum.sort(Map.keys(m)) == Enum.sort(@maintenance_keys)
    assert is_binary(m["id"]) and is_binary(m["host_id"])
    assert m["state"] in ~w(planned active ended cancelled)
    assert String.ends_with?(m["start"], "Z") and String.ends_with?(m["end"], "Z")
  end

  def assert_person_shape(p) do
    assert Enum.sort(Map.keys(p)) == Enum.sort(@person_keys)

    for k <- p["keys"] do
      assert Enum.sort(Map.keys(k)) == ~w(comment fingerprint hosts matched_by)
      assert is_binary(k["fingerprint"])
    end

    for a <- p["authorizations"],
        do: assert(Enum.sort(Map.keys(a)) == ~w(host_id matched_by remote_user))

    assert is_list(p["emails"])
  end

  @doc "`/people/<key>` with the key URL-encoded."
  def person_path(key), do: "/people/" <> URI.encode(key, &URI.char_unreserved?/1)

  defp window(start_s, end_s) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      "start" => DateTime.to_iso8601(DateTime.add(now, start_s)),
      "end" => DateTime.to_iso8601(DateTime.add(now, end_s)),
      "comment" => "mctl conformance"
    }
  end

  defp for_host(c, token, id) do
    path = "/maintenance?limit=1000&host_id=" <> URI.encode_www_form(id)
    {200, %{"data" => data}} = call(c, :get, path, token)
    data
  end

  defp person_key(fixtures) do
    if function_exported?(fixtures, :person_key, 0), do: fixtures.person_key()
  end

  # polls a job until it is finished (~10 s)
  defp wait_job(c, token, job, tries \\ 100)
  defp wait_job(_c, _token, %{"state" => s} = job, _) when s in ~w(succeeded failed), do: job
  defp wait_job(_c, _token, job, 0), do: flunk("job #{job["id"]} never finished")

  defp wait_job(c, token, job, tries) do
    Process.sleep(100)
    {200, %{"data" => job}} = call(c, :get, "/jobs/" <> job["id"], token)
    wait_job(c, token, job, tries - 1)
  end
end
