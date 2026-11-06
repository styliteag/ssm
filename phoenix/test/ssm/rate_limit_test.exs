defmodule Ssm.RateLimitTest do
  use ExUnit.Case, async: false

  alias Ssm.RateLimit

  setup do
    RateLimit.reset()
    :ok
  end

  test "hit/4 allows up to the limit per window, then reports seconds left" do
    for _ <- 1..3, do: assert(:ok = RateLimit.hit({:t, 1}, 3, 60, now: 120))
    assert {:error, 60} = RateLimit.hit({:t, 1}, 3, 60, now: 120)
    assert {:error, 15} = RateLimit.hit({:t, 1}, 3, 60, now: 165)
    # Next window starts fresh.
    assert :ok = RateLimit.hit({:t, 1}, 3, 60, now: 180)
  end

  test "keys are independent" do
    assert :ok = RateLimit.hit({:t, 1}, 1, 60, now: 0)
    assert {:error, _} = RateLimit.hit({:t, 1}, 1, 60, now: 0)
    assert :ok = RateLimit.hit({:t, 2}, 1, 60, now: 0)
  end

  test "check/4 reads without counting; count/3 counts without checking" do
    assert :ok = RateLimit.check({:ip, "a"}, 2, 300, now: 10)
    assert RateLimit.count({:ip, "a"}, 300, now: 10) == 1
    assert RateLimit.count({:ip, "a"}, 300, now: 11) == 2
    assert {:error, 289} = RateLimit.check({:ip, "a"}, 2, 300, now: 11)
    assert RateLimit.count({:ip, "a"}, 300, now: 11) == 3
  end

  test "clear/1 forgets one key in every window, others stay" do
    RateLimit.count({:c, 1}, 60, now: 0)
    RateLimit.count({:c, 1}, 60, now: 60)
    RateLimit.count({:c, 2}, 60, now: 60)
    assert :ok = RateLimit.clear({:c, 1})
    assert RateLimit.count({:c, 1}, 60, now: 60) == 1
    assert RateLimit.count({:c, 2}, 60, now: 60) == 2
  end

  test "client_key/1: IPv4 as is, IPv6 by /64" do
    assert RateLimit.client_key({10, 0, 0, 1}) == "10.0.0.1"
    assert RateLimit.client_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) == "2001:db8:1:2::/64"
    assert RateLimit.client_key({0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}) == "2001:db8:1:2::/64"
    # IPv4-mapped IPv6 is the IPv4 client
    assert RateLimit.client_key({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}) == "10.0.0.1"
  end

  test "sweep/1 drops expired windows only" do
    :ok = RateLimit.hit({:t, :old}, 5, 60, now: 0)
    :ok = RateLimit.hit({:t, :new}, 5, 60, now: 100)
    assert RateLimit.sweep(100) == 1
    assert {:error, _} = RateLimit.check({:t, :new}, 1, 60, now: 100)
    assert :ok = RateLimit.check({:t, :old}, 1, 60, now: 0)
  end
end
