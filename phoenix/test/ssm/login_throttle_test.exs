defmodule Ssm.LoginThrottleTest do
  use Ssm.DataCase, async: false

  alias Ssm.{Activity, LoginThrottle, RateLimit}

  @window 1_000_000_000

  setup do
    RateLimit.reset()
    previous = Application.get_env(:ssm, :login_limits)
    Application.put_env(:ssm, :login_limits, failures: 3, window: @window)

    on_exit(fn ->
      RateLimit.reset()

      if previous,
        do: Application.put_env(:ssm, :login_limits, previous),
        else: Application.delete_env(:ssm, :login_limits)
    end)

    :ok
  end

  defp fail_n(n, ip, user), do: for(_ <- 1..n, do: LoginThrottle.record_failure(ip, user))

  test "defaults: 5 failures per 15 minutes" do
    Application.delete_env(:ssm, :login_limits)
    assert LoginThrottle.limits() == {5, 900}
  end

  test "allowed until the limit is reached, then locked with seconds left" do
    assert :ok = LoginThrottle.check({10, 0, 0, 1}, "alice")
    fail_n(2, {10, 0, 0, 1}, "alice")
    assert :ok = LoginThrottle.check({10, 0, 0, 1}, "alice")
    fail_n(1, {10, 0, 0, 1}, "alice")
    assert {:error, retry} = LoginThrottle.check({10, 0, 0, 1}, "alice")
    assert retry in 1..@window
  end

  test "check does not count" do
    for _ <- 1..10, do: assert(:ok = LoginThrottle.check({10, 0, 0, 1}, "alice"))
  end

  test "per IP: locks every username from that IP, not other IPs" do
    fail_n(1, {10, 0, 0, 1}, "a")
    fail_n(1, {10, 0, 0, 1}, "b")
    fail_n(1, {10, 0, 0, 1}, "c")
    assert {:error, _} = LoginThrottle.check({10, 0, 0, 1}, "fresh")
    assert :ok = LoginThrottle.check({10, 0, 0, 2}, "fresh")
  end

  test "per username across IPs, case-insensitive and trimmed" do
    LoginThrottle.record_failure({10, 0, 0, 1}, "Alice")
    LoginThrottle.record_failure({10, 0, 0, 2}, "alice ")
    LoginThrottle.record_failure({10, 0, 0, 3}, "ALICE")
    assert {:error, _} = LoginThrottle.check({10, 0, 0, 4}, "alice")
    assert :ok = LoginThrottle.check({10, 0, 0, 4}, "bob")
  end

  test "success resets the username counter but not the IP counter" do
    fail_n(2, {10, 0, 0, 1}, "alice")
    LoginThrottle.record_success("Alice")
    LoginThrottle.record_failure({10, 0, 0, 9}, "alice")
    LoginThrottle.record_failure({10, 0, 0, 9}, "alice")
    assert :ok = LoginThrottle.check({10, 0, 0, 7}, "alice")

    # IP counter survived: 2 earlier + 1 more locks 10.0.0.1
    LoginThrottle.record_failure({10, 0, 0, 1}, "other")
    assert {:error, _} = LoginThrottle.check({10, 0, 0, 1}, "zed")
  end

  test "locking is audited once, without a password; username is not logged raw twice" do
    fail_n(3, {10, 0, 0, 1}, "alice")
    fail_n(2, {10, 0, 0, 1}, "alice")

    locks =
      Activity.list()
      |> Enum.filter(&(&1.action == "login_locked"))

    # one for the IP, one for the username
    assert length(locks) == 2
    assert Enum.all?(locks, &(&1.activity_type == "auth"))
    refute inspect(locks) =~ "password"
  end

  test "very long usernames do not blow up the key" do
    long = String.duplicate("x", 100_000)
    assert :ok = LoginThrottle.check({10, 0, 0, 1}, long)
    LoginThrottle.record_failure({10, 0, 0, 1}, long)
  end

  test "IPv6 clients share a /64" do
    fail_n(3, {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}, "a")
    assert {:error, _} = LoginThrottle.check({0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}, "b")
  end
end
