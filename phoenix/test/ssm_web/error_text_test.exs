defmodule SsmWeb.ErrorTextTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SsmWeb.ErrorText

  describe "reason/1" do
    test "a tagged message is shown as is" do
      assert ErrorText.reason({:unreachable, "connection refused"}) == "connection refused"
    end

    test "a bare atom becomes words" do
      assert ErrorText.reason(:not_found) == "not found"
      assert ErrorText.reason(:timeout) == "timeout"
    end

    test "anything else is logged, never shown raw" do
      log =
        capture_log(fn ->
          text = ErrorText.reason({:badmatch, %{secret_shape: [1, 2]}})
          assert text == "unexpected error (details are in the server log)"
          refute text =~ "badmatch"
        end)

      assert log =~ "badmatch"
    end
  end

  describe "crashed/2" do
    test "logs the exit reason and shows a plain sentence" do
      log =
        capture_log(fn ->
          text = ErrorText.crashed("Sync all", {:timeout, {GenServer, :call, []}})
          assert text == "Sync all failed unexpectedly. The details are in the server log."
          refute text =~ "GenServer"
        end)

      assert log =~ "Sync all crashed"
      assert log =~ "GenServer"
    end
  end
end
