defmodule SsmWeb.DesignTest do
  use ExUnit.Case, async: true

  alias SsmWeb.Design

  test "designs in order, orbit first (default)" do
    assert Design.ids() == ["orbit", "bench", "soft", "rainbow"]
    assert Design.default() == "orbit"
  end

  test "theme resolves design + explicit mode" do
    assert Design.theme("bench", "dark") == "bench-dark"
    assert Design.theme("rainbow", "light") == "rainbow-light"
  end

  test "theme falls back to the design's native mode" do
    assert Design.theme("orbit") == "orbit-dark"
    assert Design.theme("bench") == "bench-light"
    assert Design.theme("soft") == "soft-light"
    assert Design.theme("rainbow") == "rainbow-dark"
  end

  test "unknown design from a stale cookie degrades to the default" do
    assert Design.validate("onyx") == "orbit"
    assert Design.validate(nil) == "orbit"
    assert Design.theme("onyx") == "orbit-dark"
  end

  test "modes validate; junk means Auto (nil)" do
    assert Design.validate_mode("light") == "light"
    assert Design.validate_mode("dark") == "dark"
    assert Design.validate_mode("") == nil
    assert Design.validate_mode("system") == nil
    assert Design.validate_mode(nil) == nil
  end
end
