defmodule Ssm.ToolVersionsTest do
  @moduledoc """
  One source for the Elixir/OTP versions: `.tool-versions` (local toolchain
  and CI via erlef/setup-beam `version-file`). The Dockerfile ARGs must
  match it, so CI checks with the versions the release image builds with.
  An OTP ARG without a dot (official `elixir:<v>-otp-<major>` image) is
  compared with the major of the exact OTP in `.tool-versions`.
  """
  use ExUnit.Case, async: true

  @dockerfiles ~w(Dockerfile Dockerfile.dev)

  test ".tool-versions names exact erlang and elixir versions" do
    %{"erlang" => otp, "elixir" => elixir} = tool_versions()
    assert otp =~ ~r/^\d+\.\d+(\.\d+)*$/
    assert elixir =~ ~r/^\d+\.\d+\.\d+-otp-\d+$/
    assert String.ends_with?(elixir, "-otp-" <> otp_major(otp))
  end

  for file <- @dockerfiles do
    test "#{file} ARGs match .tool-versions" do
      %{"erlang" => otp, "elixir" => elixir} = tool_versions()
      args = docker_args(unquote(file))

      assert args["ELIXIR_VERSION"] == elixir |> String.split("-otp-") |> hd()

      expected_otp =
        if String.contains?(args["OTP_VERSION"] || "", "."), do: otp, else: otp_major(otp)

      assert args["OTP_VERSION"] == expected_otp

      # no FROM line pins an Elixir image by hand
      for line <- File.read!(unquote(file)) |> String.split("\n"),
          line =~ ~r/^FROM\s+\S*elixir:/i do
        assert line =~ "${ELIXIR_VERSION}", "#{unquote(file)}: #{line}"
      end
    end
  end

  defp tool_versions do
    ".tool-versions"
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Map.new(fn line -> line |> String.split() |> then(fn [k, v | _] -> {k, v} end) end)
  end

  defp docker_args(file) do
    Regex.scan(~r/^ARG\s+(\w+)=(\S+)/m, File.read!(file))
    |> Map.new(fn [_, k, v] -> {k, String.trim(v, "\"")} end)
  end

  defp otp_major(otp), do: otp |> String.split(".") |> hd()
end
