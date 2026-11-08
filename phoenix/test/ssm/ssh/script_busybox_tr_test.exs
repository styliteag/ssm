defmodule Ssm.Ssh.ScriptBusyboxTrTest do
  @moduledoc """
  BusyBox 1.01 (sty-qnap) `tr` ignores ranges between octal escapes:
  `tr -d '\\000-\\040\\177'` there keeps TAB, LF and ESC, so `login_ok`
  must list every control character on its own.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../priv/ssh/script.sh", __DIR__)

  test "tr in script.sh uses no octal ranges" do
    script = File.read!(@script)
    refute script =~ ~r/tr -d '[^']*\\[0-7]{3}-\\[0-7]{3}/
  end

  test "login_ok deletes every C0 control character, space and DEL" do
    [_, set] = Regex.run(~r/login_ok\(\).*?tr -d '([^']+)'/s, File.read!(@script))
    listed = for <<c::8 <- decode(set)>>, into: MapSet.new(), do: c
    assert MapSet.new(Enum.to_list(1..32) ++ [127]) == listed
  end

  defp decode(set) do
    ~r/\\([0-7]{3})/
    |> Regex.scan(set)
    |> Enum.map(fn [_, oct] -> String.to_integer(oct, 8) end)
    |> :binary.list_to_bin()
  end
end
