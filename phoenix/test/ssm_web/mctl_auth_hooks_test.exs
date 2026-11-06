defmodule SsmWeb.MctlAuthHooksTest do
  use SsmWeb.ConnCase, async: false

  alias MctlContract.Tokens.Ecto, as: Tokens
  alias Ssm.{Activity, RateLimit}

  @window 1_000_000_000

  setup do
    RateLimit.reset()
    previous = Application.get_env(:ssm, :mctl_limits)

    # Fixed windows: a window boundary between two requests of one test
    # would reset the counter. A ~31-year window keeps the tests stable.
    Application.put_env(:ssm, :mctl_limits,
      auth_failures: {3, @window},
      token_requests: {5, @window}
    )

    on_exit(fn ->
      RateLimit.reset()

      if previous,
        do: Application.put_env(:ssm, :mctl_limits, previous),
        else: Application.delete_env(:ssm, :mctl_limits)
    end)

    :ok
  end

  defp from(ip), do: %{build_conn() | remote_ip: ip}

  defp me(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/mctl/v1/me")
  end

  defp token(scopes \\ ["read"]) do
    {:ok, _t, plain} =
      Tokens.create("t-#{System.unique_integer([:positive])}", scopes, prefix: "ssm_")

    plain
  end

  test "failed auth is counted per client IP; over the limit even valid tokens get 429" do
    good = token()

    for _ <- 1..3 do
      assert from({10, 0, 0, 1}) |> me("ssm_wrong") |> json_response(401)
    end

    resp = from({10, 0, 0, 1}) |> me(good)
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(resp, 429)
    assert [retry_after] = get_resp_header(resp, "retry-after")
    assert String.to_integer(retry_after) in 1..@window

    # Another client is not affected.
    assert from({10, 0, 0, 2}) |> me(good) |> json_response(200)
  end

  test "requests without a token are neither counted nor audited" do
    for _ <- 1..5, do: assert(from({10, 0, 0, 3}) |> get("/api/mctl/v1/me") |> json_response(401))
    assert from({10, 0, 0, 3}) |> me(token()) |> json_response(200)
    assert Activity.list(activity_type: "auth") == []
  end

  test "IPv6 failures count per /64" do
    good = token()
    for i <- 1..3, do: from({0x2001, 0xDB8, 1, 2, 0, 0, 0, i}) |> me("ssm_wrong")

    assert from({0x2001, 0xDB8, 1, 2, 0xFFFF, 0, 0, 9}) |> me(good) |> json_response(429)
    assert from({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}) |> me(good) |> json_response(200)
  end

  test "successful requests and missing scopes are not auth failures" do
    good = token(["read"])

    for _ <- 1..3 do
      conn =
        from({10, 0, 0, 4})
        |> put_req_header("authorization", "Bearer " <> good)
        |> put_req_header("content-type", "application/json")
        |> post("/api/mctl/v1/customers", Jason.encode!(%{slug: "x", name: "X"}))

      assert json_response(conn, 403)["error"]["code"] == "insufficient_scope"
    end

    assert from({10, 0, 0, 4}) |> me(good) |> json_response(200)
  end

  test "failed auth is audited once per client and window, plus when the limit is hit" do
    for _ <- 1..4, do: from({10, 0, 0, 5}) |> me("ssm_wrong")

    entries = Activity.list(activity_type: "auth")
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.target == "api/mctl/v1"))
    assert Enum.all?(entries, &(&1.meta =~ "10.0.0.5"))
    assert Enum.any?(entries, &(&1.action == "mctl_auth_failed"))
    assert Enum.any?(entries, &(&1.action == "mctl_auth_locked"))
    refute Enum.any?(entries, &(&1.meta =~ "ssm_wrong"))
  end

  test "per-token request limit answers 429 with Retry-After" do
    good = token()

    for _ <- 1..5, do: assert(from({10, 0, 0, 6}) |> me(good) |> json_response(200))

    resp = from({10, 0, 0, 7}) |> me(good)
    assert json_response(resp, 429)["error"]["code"] == "rate_limited"
    assert [_] = get_resp_header(resp, "retry-after")

    # Another token keeps its own budget.
    assert from({10, 0, 0, 6}) |> me(token()) |> json_response(200)
  end

  test "invalid JSON is a contract 400 bad_request, not Phoenix's error page" do
    resp =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(~w(read setup)))
      |> put_req_header("content-type", "application/json")
      |> post("/api/mctl/v1/customers", "{not json")

    assert %{"error" => %{"code" => "bad_request", "message" => _, "details" => _}} =
             json_response(resp, 400)
  end

  test "broken JSON without a token is 401: the token is checked before the body" do
    resp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/mctl/v1/customers", "{not json")

    assert json_response(resp, 401)["error"]["code"] == "unauthorized"
  end

  test "/api/v2 still parses JSON bodies at the endpoint" do
    resp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v2/auth/login", Jason.encode!(%{username: "nobody", password: "x"}))

    assert json_response(resp, 401)["error"]["code"] == "INVALID_CREDENTIALS"
  end
end
