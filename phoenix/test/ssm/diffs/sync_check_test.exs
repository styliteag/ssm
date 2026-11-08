defmodule Ssm.Diffs.SyncCheckTest do
  use ExUnit.Case, async: true

  alias Ssm.Diffs.{HostDiff, KeyDiff, LoginDiff, SyncCheck}

  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"
  @ed25519_b64 "AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"

  defp diff(logins, read_error \\ nil),
    do: %HostDiff{host_id: 1, host_name: "web01", logins: logins, read_error: read_error}

  defp login(name, items, read_error \\ nil),
    do: %LoginDiff{login: name, items: items, read_error: read_error}

  defp item(status, line), do: %KeyDiff{status: status, line: line}

  describe "result/2" do
    test "no difference is synced and counts the logins" do
      d = diff([login("root", [item(:present, @ed25519)]), login("deploy", [])])

      assert %{state: "synced", logins: 2, drift: [], error_code: nil, error: nil} =
               SyncCheck.result(d, %{})
    end

    test "missing and extra keys become drift entries per user and login" do
      owners = %{@ed25519_b64 => "alice"}

      d =
        diff([
          login("root", [
            item(:missing_on_host, @ed25519 <> " laptop"),
            item(:extra_on_host, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB stranger@old"),
            item(:present, "ssh-ed25519 PRESENT")
          ])
        ])

      assert %{state: "drift", logins: 1, drift: entries} = SyncCheck.result(d, owners)
      assert length(entries) == 2

      assert %{"user" => "alice", "login" => "root", "missing" => [m], "extra" => []} =
               Enum.find(entries, &(&1["user"] == "alice"))

      assert m =~ ~r/^ssh-ed25519 SHA256:[A-Za-z0-9+\/]{43} \(laptop\)$/

      assert %{"user" => nil, "login" => "root", "missing" => [], "extra" => [x]} =
               Enum.find(entries, &(&1["user"] == nil))

      assert x =~ ~r/^ssh-rsa SHA256:.* \(stranger@old\)$/
    end

    test "key material never reaches the result" do
      d = diff([login("root", [item(:missing_on_host, @ed25519 <> " laptop")])])
      json = d |> SyncCheck.result(%{}) |> Jason.encode!()
      refute json =~ @ed25519_b64
      refute json =~ String.slice(@ed25519_b64, 8, 24)
    end

    test "a user's several keys on one login are one entry" do
      owners = %{"AAAA" => "bob", "BBBB" => "bob"}

      d =
        diff([
          login("root", [
            item(:missing_on_host, "ssh-ed25519 AAAA one"),
            item(:missing_on_host, "ssh-ed25519 BBBB two")
          ])
        ])

      assert %{drift: [%{"user" => "bob", "missing" => [_, _]}]} = SyncCheck.result(d, owners)
    end

    test "a host-read comment loses control and bidi characters and is capped" do
      comment = "evil\u202Egnp.exe\u0007\u2066x" <> String.duplicate("c", 500)
      d = diff([login("root", [item(:extra_on_host, "ssh-rsa AAAA " <> comment)])])

      assert %{drift: [%{"extra" => [label]}]} = SyncCheck.result(d, %{})
      refute label =~ ~r/[\x{202E}\x{2066}\x{0007}]/u
      assert label =~ "(evilgnp.exex"
      assert String.length(label) < 200 + 80
    end

    test "a line that is no key is labelled without leaking its content" do
      d = diff([login("root", [item(:extra_on_host, ~s(command="rm -rf /" ssh-ed25519 AAAA x))])])
      assert %{drift: [%{"extra" => [label]}]} = SyncCheck.result(d, %{})
      assert label == "unparsable key line"
    end

    test "a login that could not be read is an error with a fixed sentence, raw text dropped" do
      d = diff([login("root", [], "connect to 10.1.2.3: econnrefused")], nil)

      assert %{
               state: "error",
               error_code: "connect_refused",
               error: "the host refused the SSH connection",
               drift: []
             } = SyncCheck.result(d, %{})
    end

    test "a host-level read error counts even without any login" do
      d = diff([], "timeout while talking to 10.1.2.3")

      assert %{state: "error", error_code: "timeout", error: "the SSH connection timed out"} =
               SyncCheck.result(d, %{})
    end
  end

  describe "status/1 (diff page format)" do
    test "synced, needs_sync with counts, error with the raw text" do
      assert SyncCheck.status(diff([login("a", [item(:present, "x y")])])) == :synced

      assert SyncCheck.status(
               diff([login("a", [item(:missing_on_host, "x y"), item(:extra_on_host, "x z")])])
             ) == {:needs_sync, 1, 1}

      assert SyncCheck.status(diff([login("a", [], "boom")])) == {:error, "boom"}
      assert SyncCheck.status(diff([], "down")) == {:error, "down"}
    end
  end
end
