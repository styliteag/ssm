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

  # options that narrow what a key may do; dropping one widens access
  @restrictions ~w(from command restrict permitopen permitlisten expiry-time principals)

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

  defp restriction?(name), do: name in @restrictions or String.starts_with?(name, "no-")

  # lenient: option names of a prefix read from a host (sshd quoting rules)
  defp names(options) do
    options
    |> host_entries("", [], false)
    |> Enum.map(fn entry -> entry |> String.split("=", parts: 2) |> hd() |> String.downcase() end)
    |> Enum.reject(&(&1 == ""))
  end

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
