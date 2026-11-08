defmodule Ssm.Authorizations.Options do
  @moduledoc """
  Validation of `authorization.options`, the authorized_keys options ssm
  writes in front of a granted key (`no-pty,from="10.0.0.0/8"`).

  Accepted: a comma-separated list of allow-listed option names (compared
  case-insensitively, like sshd). A flag (`no-pty`) takes no value; a valued
  option (`from="…"`) needs one, in double quotes. Refused: control
  characters, any backslash (sshd only knows `\\"` inside a value, and a
  parser that disagrees about where a value ends can be tricked into
  accepting a second key), unbalanced quotes, whitespace outside quotes,
  empty entries and every name not on the allow-list.
  """

  alias Ssm.ControlChars

  @flags ~w(restrict no-pty no-port-forwarding no-agent-forwarding no-X11-forwarding
            no-user-rc pty port-forwarding agent-forwarding X11-forwarding user-rc
            no-touch-required verify-required cert-authority)

  @valued ~w(from command permitopen permitlisten environment expiry-time principals tunnel)

  # options that widen what a key may do (or re-enable what `restrict`
  # takes away): set by admins only on the web UI (`validate_role/2`)
  @admin_only ~w(environment cert-authority user-rc permitopen permitlisten pty
                 port-forwarding agent-forwarding x11-forwarding tunnel no-touch-required)

  # options that narrow what a key may do; dropping one widens access
  @restrictions ~w(from command restrict permitopen permitlisten expiry-time principals
                   verify-required)

  @arity Map.new(@flags, &{String.downcase(&1), :flag})
         |> Map.merge(Map.new(@valued, &{String.downcase(&1), :valued}))

  @entry ~r/\A([A-Za-z0-9-]+)(="[^"]*")?\z/

  @doc "The allow-listed option names."
  @spec allowed() :: [String.t()]
  def allowed, do: @flags ++ @valued

  @doc "`:ok` for nil, empty or valid options; `{:error, message}` otherwise."
  @spec validate(String.t() | nil) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok
  def validate(""), do: :ok

  def validate(options) when is_binary(options) do
    with :ok <- check_chars(options),
         {:ok, entries} <- split(options, "", [], false) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case check_entry(entry) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  def validate(_other), do: {:error, "must be a string"}

  @doc "Changeset validation of the `:options` field."
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    Ecto.Changeset.validate_change(changeset, :options, fn :options, value ->
      case validate(value) do
        :ok -> []
        {:error, message} -> [options: message]
      end
    end)
  end

  @doc """
  The admin-only (permissive) option names in `options`, lower-case, once
  each, in order: `environment`, `cert-authority`, `user-rc`,
  `permitopen`, `permitlisten`, the re-enabling `pty`, `port-forwarding`,
  `agent-forwarding`, `x11-forwarding`, `tunnel`, and `no-touch-required`
  (drops the FIDO touch check). Everything else on the allow-list only
  narrows what a key may do.
  """
  @spec admin_only(String.t() | nil) :: [String.t()]
  def admin_only(nil), do: []

  def admin_only(options) when is_binary(options),
    do: options |> names() |> Enum.filter(&(&1 in @admin_only)) |> Enum.uniq()

  @doc """
  Changeset check for a web user's `role`: only `"admin"` may write
  permissive options (`admin_only/1`). Anyone else gets an `:options` error
  when the grant's options carry one and the change sets the options or
  moves the grant (new grant, other host, user or login); editing the
  comment of an admin's grant stays possible.
  """
  @spec validate_role(Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def validate_role(changeset, "admin"), do: changeset

  def validate_role(changeset, _role) do
    names = changeset |> Ecto.Changeset.get_field(:options) |> admin_only()

    cond do
      names != [] and writes_options?(changeset) ->
        Ecto.Changeset.add_error(changeset, :options, role_message(names))

      (dropped = dropped_by_change(changeset)) != [] ->
        Ecto.Changeset.add_error(changeset, :options, drop_message(dropped))

      true ->
        changeset
    end
  end

  # restrictions of a stored row that the change removes or alters
  defp dropped_by_change(%Ecto.Changeset{data: data} = changeset) do
    if is_nil(Map.get(data, :id)) or not Map.has_key?(changeset.changes, :options),
      do: [],
      else: missing_restrictions(Map.get(data, :options), changeset.changes.options)
  end

  defp drop_message(entries),
    do:
      "removing or changing the restriction #{Enum.join(entries, ", ")} may be done by an " <>
        "admin only (operators may only add restrictions)"

  @doc "The error text for permissive option `names` set by a non-admin."
  @spec role_message([String.t()]) :: String.t()
  def role_message(names),
    do:
      "#{Enum.join(names, ", ")} may be set by an admin only (operators: restrictive options only)"

  defp writes_options?(%Ecto.Changeset{data: data, changes: changes}) do
    is_nil(Map.get(data, :id)) or
      Enum.any?([:options, :host_id, :user_id, :login], &Map.has_key?(changes, &1))
  end

  @doc """
  The restricting options (`from`, `command`, `restrict`, `no-*`,
  `permitopen`, `permitlisten`, `expiry-time`, `principals`) of `host_options`
  that `db_options` lacks, lower-case, in host order. Both are options
  prefixes as `Ssm.Users.KeyParser.options/1` returns them.
  """
  @spec dropped_restrictions(String.t(), String.t()) :: [String.t()]
  def dropped_restrictions(host_options, db_options) do
    kept = MapSet.new(names(db_options))

    host_options
    |> names()
    |> Enum.filter(&restriction?/1)
    |> Enum.reject(&MapSet.member?(kept, &1))
    |> Enum.uniq()
  end

  @doc """
  The restriction entries of `required` (as in `dropped_restrictions/2`,
  plus `verify-required`) that `present` lacks: compared by lower-case
  name and exact value, so `from="10.0.0.0/8"` is missing from options
  that only carry `from="0.0.0.0/0"`. Entries as `name` or `name="value"`
  (name lower-case), in `required` order, once each.
  """
  @spec missing_restrictions(String.t() | nil, String.t() | nil) :: [String.t()]
  def missing_restrictions(required, present) do
    have = MapSet.new(restriction_entries(present))

    required
    |> restriction_entries()
    |> Enum.reject(&MapSet.member?(have, &1))
    |> Enum.uniq()
  end

  @doc """
  True when `options` grant more than `than`: they lack one of its
  restriction entries (`missing_restrictions/2`) or carry a permissive
  option (`admin_only/1`) it lacks. A change from `old` to `new` with
  `weaker?(old, new)` takes access away.
  """
  @spec weaker?(String.t() | nil, String.t() | nil) :: boolean()
  def weaker?(options, than),
    do: missing_restrictions(than, options) != [] or admin_only(options) -- admin_only(than) != []

  defp restriction?(name), do: name in @restrictions or String.starts_with?(name, "no-")

  defp restriction_entries(options) do
    for entry <- entries(options),
        [name | value] = String.split(entry, "=", parts: 2),
        name = String.downcase(name),
        restriction?(name),
        do: Enum.join([name | value], "=")
  end

  # lenient: option names of a prefix read from a host (sshd quoting rules)
  defp names(options) do
    options
    |> entries()
    |> Enum.map(fn entry -> entry |> String.split("=", parts: 2) |> hd() |> String.downcase() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp entries(nil), do: []
  defp entries(options), do: host_entries(options, "", [], false)

  defp host_entries(<<>>, cur, acc, _quoted), do: Enum.reverse([cur | acc])

  defp host_entries(<<?\\, ?", rest::binary>>, cur, acc, quoted),
    do: host_entries(rest, cur <> "\\\"", acc, quoted)

  defp host_entries(<<?", rest::binary>>, cur, acc, quoted),
    do: host_entries(rest, cur <> "\"", acc, not quoted)

  defp host_entries(<<?,, rest::binary>>, cur, acc, false),
    do: host_entries(rest, "", [cur | acc], false)

  defp host_entries(<<c, rest::binary>>, cur, acc, quoted),
    do: host_entries(rest, cur <> <<c>>, acc, quoted)

  defp check_chars(options) do
    cond do
      ControlChars.present?(options) -> {:error, "must not contain control characters"}
      String.contains?(options, "\\") -> {:error, "must not contain a backslash"}
      true -> :ok
    end
  end

  # split on commas outside quotes (no backslash can reach this point)
  defp split(<<>>, _cur, _acc, true), do: {:error, "has unbalanced quotes"}
  defp split(<<>>, cur, acc, false), do: {:ok, Enum.reverse([cur | acc])}

  defp split(<<?", rest::binary>>, cur, acc, quoted),
    do: split(rest, cur <> "\"", acc, not quoted)

  defp split(<<?,, rest::binary>>, cur, acc, false), do: split(rest, "", [cur | acc], false)

  defp split(<<?\s, _rest::binary>>, _cur, _acc, false),
    do: {:error, "must not contain whitespace outside quotes"}

  defp split(<<c, rest::binary>>, cur, acc, quoted), do: split(rest, cur <> <<c>>, acc, quoted)

  defp check_entry(""), do: {:error, "has an empty option"}

  defp check_entry(entry) do
    case Regex.run(@entry, entry) do
      [_, name] -> check_name(name, false)
      [_, name, _value] -> check_name(name, true)
      nil -> {:error, ~s(has an invalid option #{inspect(entry)}: use name or name="value")}
    end
  end

  defp check_name(name, valued?) do
    case {Map.get(@arity, String.downcase(name)), valued?} do
      {nil, _} ->
        {:error, ~s(has an unknown option "#{name}" \(allowed: #{Enum.join(allowed(), ", ")}\))}

      {:flag, true} ->
        {:error, ~s(option "#{name}" takes no value)}

      {:valued, false} ->
        {:error, ~s(option "#{name}" needs a value, e.g. #{name}="…")}

      _ ->
        :ok
    end
  end
end
