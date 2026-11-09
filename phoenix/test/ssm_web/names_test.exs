defmodule SsmWeb.NamesTest do
  use ExUnit.Case, async: true

  alias SsmWeb.Names

  test "short_list/2" do
    assert Names.short_list([]) == ""
    assert Names.short_list(["a"]) == "a"
    assert Names.short_list(["a", "b", "c"]) == "a, b and c"
    assert Names.short_list(~w(a b c d e f g), 3) == "a, b, c and 4 more"
  end
end
