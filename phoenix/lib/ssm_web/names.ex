defmodule SsmWeb.Names do
  @moduledoc """
  Short lists of names for flash messages: a fleet operation over many hosts
  names the first few and counts the rest, so a message stays readable.
  """

  @doc ~S|"a, b and c"; past `max`: "a, b, c and 4 more".|
  @spec short_list([String.t()], pos_integer()) :: String.t()
  def short_list(names, max \\ 5)
  def short_list([], _max), do: ""
  def short_list([one], _max), do: one

  def short_list(names, max) when length(names) > max do
    {shown, rest} = Enum.split(names, max)
    Enum.join(shown, ", ") <> " and #{length(rest)} more"
  end

  def short_list(names, _max) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
