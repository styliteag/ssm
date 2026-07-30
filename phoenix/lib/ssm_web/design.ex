defmodule SsmWeb.Design do
  @moduledoc """
  Theme registry — the ../dashboard (orbit) / ../link-shortener pattern: a
  design (orbit / bench / soft / rainbow) crossed with a mode (light / dark)
  yields the daisyUI theme name rendered as `data-theme` on `<html>`.

  Choices persist in year-long cookies (`SsmWeb.DesignController`); unknown
  ids from stale cookies fall back to the default instead of crashing. Every
  design ships a matching `<id>-light` / `<id>-dark` daisyUI block in
  `assets/css/app.css`.
  """

  @designs [
    %{id: "orbit", name: "Orbit", default_mode: "dark"},
    %{id: "bench", name: "Bench", default_mode: "light"},
    %{id: "soft", name: "Soft", default_mode: "light"},
    %{id: "rainbow", name: "Rainbow", default_mode: "dark"}
  ]

  @modes ~w(light dark)

  def all, do: @designs

  def ids, do: Enum.map(@designs, & &1.id)

  def default, do: hd(@designs).id

  def modes, do: @modes

  @doc "Unknown design ids degrade to the default (stale cookies survive theme removals)."
  def validate(design) do
    if design in ids(), do: design, else: default()
  end

  @doc ~S(nil / "" / junk mean "Auto" — the design's native mode.)
  def validate_mode(mode) do
    if mode in @modes, do: mode, else: nil
  end

  def default_mode(design) do
    case Enum.find(@designs, &(&1.id == design)) do
      nil -> default_mode(default())
      design -> design.default_mode
    end
  end

  def theme(design, mode \\ nil) do
    design = validate(design)
    "#{design}-#{mode || default_mode(design)}"
  end
end
