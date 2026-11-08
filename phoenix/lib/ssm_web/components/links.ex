defmodule SsmWeb.Links do
  @moduledoc """
  Cross-links between the pages (host → diff, SSH user → user page, key →
  the user's keys, grant → the user's grants), short key text and a copy
  button. Imported into every LiveView and component (`SsmWeb.html_helpers`).
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: SsmWeb.Endpoint,
    router: SsmWeb.Router,
    statics: SsmWeb.static_paths()

  import SsmWeb.CoreComponents, only: [icon: 1]

  alias Ssm.Users.KeyParser

  @doc "Path of a host's diff (keys on the host vs. the database)."
  def host_path(host_id), do: ~p"/diff?host_id=#{host_id}"

  @doc "Path of an SSH user's page."
  def user_path(user_id), do: ~p"/users/#{user_id}"

  @doc "Path of an SSH user's keys."
  def keys_path(user_id), do: ~p"/keys?user_id=#{user_id}"

  @doc "Path of an SSH user's grants."
  def grants_path(user_id), do: ~p"/grants?user_id=#{user_id}"

  attr :id, :any, required: true, doc: "host id"
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  @doc "A host name linking to its diff."
  def host_link(assigns) do
    ~H"""
    <.link navigate={host_path(@id)} class={["link link-hover", @class]} title="Open the diff" {@rest}>
      {@name}
    </.link>
    """
  end

  attr :id, :any, required: true, doc: "SSH user id"
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  @doc "An SSH user name linking to the user's page."
  def user_link(assigns) do
    ~H"""
    <.link
      navigate={user_path(@id)}
      class={["link link-hover", @class]}
      title="Open the SSH user"
      {@rest}
    >
      {@name}
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, default: nil
  attr :title, :string, default: "Copy to the clipboard"
  attr :class, :any, default: nil

  @doc "Copies `text` to the clipboard (hook `CopyToClipboard`)."
  def copy_text(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={["btn btn-ghost btn-xs flex-none", @class]}
      phx-hook="CopyToClipboard"
      data-copy={@text}
      title={@title}
    >
      <.icon name="hero-clipboard" class="size-4 [[data-copied]_&]:hidden" />
      <.icon name="hero-check" class="hidden size-4 text-success [[data-copied]_&]:inline-block" />
      <span :if={@label}>{@label}</span>
    </button>
    """
  end

  @doc """
  A key line with the middle of the key cut out: options (shortened), type,
  the first 12 and last 20 characters of the key, comment. Unparsable text
  is cut at 120 characters.
  """
  @spec short_key_line(String.t()) :: String.t()
  def short_key_line(line) do
    case KeyParser.parse_authorized_line(line) do
      {:ok, parsed} ->
        [
          short_text(KeyParser.options(line) || "", 40),
          parsed.key_type,
          short_base64(parsed.key_base64),
          parsed.name
        ]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.join(" ")

      {:error, _} ->
        short_text(line, 120)
    end
  end

  @doc "The key material with its middle cut out."
  @spec short_base64(String.t()) :: String.t()
  def short_base64(b64) when is_binary(b64) and byte_size(b64) > 36,
    do: binary_part(b64, 0, 12) <> "…" <> binary_part(b64, byte_size(b64) - 20, 20)

  def short_base64(b64), do: b64 || ""

  defp short_text(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  attr :id, :string, required: true
  attr :q, :string, default: nil
  attr :placeholder, :string, default: "Search…"
  attr :filters, :list, default: [], doc: "[{name, current, [{label, value}]}] selects"

  @doc """
  Search box (and optional filter selects) of a list page. Sends `search`
  with `%{"q" => …, name => …}`; the page patches its URL (`?q=…`), so the
  filter survives reloads and, through app.js, navigating away and back.
  """
  def list_search(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="search"
      phx-submit="search"
      class="flex flex-wrap items-center gap-2"
      role="search"
    >
      <label class="input input-sm w-full sm:w-72">
        <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
        <input
          type="search"
          name="q"
          value={@q}
          placeholder={@placeholder}
          phx-debounce="250"
          autocomplete="off"
        />
      </label>
      <select :for={{name, current, options} <- @filters} name={name} class="select select-sm w-auto">
        <option :for={{label, value} <- options} value={value} selected={value == (current || "")}>
          {label}
        </option>
      </select>
    </form>
    """
  end

  @doc "The non-blank search params of `params` (keys `keys`), for a patch URL."
  @spec query_params(map(), [String.t()]) :: map()
  def query_params(params, keys) do
    for key <- keys,
        value = params[key],
        is_binary(value) and String.trim(value) != "",
        into: %{},
        do: {key, String.trim(value)}
  end

  @doc "Case-insensitive: does any of `fields` contain `q` (nil/blank: true)."
  @spec matches?(String.t() | nil, [term()]) :: boolean()
  def matches?(q, _fields) when q in [nil, ""], do: true

  def matches?(q, fields) do
    needle = q |> String.trim() |> String.downcase()
    Enum.any?(fields, &(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
  end
end
