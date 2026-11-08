defmodule Ssm.Mctl.BootTest do
  use SsmWeb.ConnCase, async: false

  alias MctlContract.Jobs.Ecto, as: Jobs

  # Test-only, deliberately low-entropy (secret scanner + not a secret).
  @token "ssm_test-only-service-token-00000000000000000000000000000000"

  setup do
    # failed-auth counters are global (ETS); the 401 checks here count too
    Ssm.RateLimit.reset()
    on_exit(&Ssm.RateLimit.reset/0)
  end

  # A fresh file outside the project tree: the dev container bind-mounts the
  # project, and a file re-created under the same path (ExUnit's tmp_dir on
  # every run) could read back empty there, so the token was not installed.
  defp token_file(content) do
    path = Path.join(System.tmp_dir!(), "ssm-boot-token-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "installs the service token from MCTL_TOKEN_FILE; it opens /api/mctl/v1 only",
       %{conn: conn} do
    path = token_file(@token <> "\n")

    assert :ok =
             Ssm.Mctl.Boot.run(env: %{"MCTL_TOKEN_FILE" => path, "MCTL_TOKEN_SCOPES" => "read"})

    me =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/api/mctl/v1/me")
      |> json_response(200)

    assert me["data"]["product"] == "ssm"
    assert me["data"]["scopes"] == ["read"]
    assert me["data"]["token"]["name"] == MctlContract.Bootstrap.name()
    # Only the tool prefix and 4 secret characters are ever shown.
    assert me["data"]["token"]["prefix"] == String.slice(@token, 0, 8)

    # /api/v2 keeps its own auth and envelope.
    v2 =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/api/v2/hosts")
      |> json_response(401)

    assert v2["success"] == false
    assert v2["error"]["code"] == "AUTH_REQUIRED"
  end

  @tag :capture_log
  test "a token without the ssm_ prefix is refused" do
    path = token_file("omon_test-only-service-token-00000000000000000000000000000000")

    assert :ok = Ssm.Mctl.Boot.run(env: %{"MCTL_TOKEN_FILE" => path})
    assert MctlContract.Tokens.Ecto.list() == []
  end

  test "a revoked service token stays revoked across boots; boot logs it and goes on",
       %{conn: conn} do
    path = token_file(@token)
    assert :ok = Ssm.Mctl.Boot.run(env: %{"MCTL_TOKEN_FILE" => path})
    :ok = MctlContract.Tokens.Ecto.revoke(MctlContract.Bootstrap.name())

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Ssm.Mctl.Boot.run(env: %{"MCTL_TOKEN_FILE" => path})
      end)

    assert log =~ "revoked"
    refute log =~ @token

    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get("/api/mctl/v1/me")
    |> json_response(401)
  end

  @tag :capture_log
  test "removing MCTL_TOKEN_FILE revokes the installed service token", %{conn: conn} do
    path = token_file(@token)
    assert :ok = Ssm.Mctl.Boot.run(env: %{"MCTL_TOKEN_FILE" => path})
    assert :ok = Ssm.Mctl.Boot.run(env: %{})

    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get("/api/mctl/v1/me")
    |> json_response(401)
  end

  @tag :capture_log
  test "no MCTL_TOKEN_FILE: nothing installed; interrupted jobs are failed" do
    {:ok, job} = Jobs.create("create_host", "1")

    assert :ok = Ssm.Mctl.Boot.run(env: %{})
    assert MctlContract.Tokens.Ecto.list() == []
    assert {:ok, %{state: "failed"}} = Jobs.get(job.id)
  end
end
