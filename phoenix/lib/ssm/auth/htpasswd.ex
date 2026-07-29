defmodule Ssm.Auth.Htpasswd do
  @moduledoc """
  Parse and verify Apache-style `.htpasswd` files — 1:1 port of
  backend/src/ssm/auth/htpasswd.py.

  Only bcrypt hashes are accepted (`$2a$`, `$2b$`, `$2y$`); other historical
  Apache hash formats are rejected so a weak hash in the file can never
  authenticate anyone. Operators create entries with `htpasswd -cB`.

  The file is read per call: it is tiny, the OS caches it, and a password
  change or new user takes effect on the next request without any reload
  machinery.
  """

  require Logger

  @bcrypt_prefixes ["$2a$", "$2b$", "$2y$"]

  @doc "True iff `password` matches the bcrypt `hashed` value."
  @spec verify_password(String.t(), String.t()) :: boolean()
  def verify_password(password, hashed)

  def verify_password(password, hashed)
      when password in [nil, ""] or hashed in [nil, ""],
      do: false

  def verify_password(password, hashed) do
    if String.starts_with?(hashed, @bcrypt_prefixes) do
      # Bcrypt.verify_pass requires $2a/$2b; normalize the Apache $2y$ variant.
      normalized =
        case hashed do
          "$2y$" <> rest -> "$2b$" <> rest
          other -> other
        end

      Bcrypt.verify_pass(password, normalized)
    else
      false
    end
  rescue
    # A malformed hash line must yield false, never an exception.
    _ -> false
  end

  @doc """
  Verify `username`/`password` against the htpasswd file at `path`.
  Runs a dummy bcrypt verification for unknown users so response timing does
  not reveal which usernames exist.
  """
  @spec verify(Path.t(), String.t(), String.t()) :: boolean()
  def verify(path, username, password) do
    case Map.fetch(parse(path), username) do
      {:ok, hashed} ->
        verify_password(password, hashed)

      :error ->
        Bcrypt.no_user_verify()
        false
    end
  end

  @doc """
  A short fingerprint of the user's current hash line, stored in the session
  at login: when the entry changes or disappears, every session of that user
  dies on its next request.
  """
  @spec entry_fingerprint(Path.t(), String.t()) :: {:ok, String.t()} | :error
  def entry_fingerprint(path, username) do
    case Map.fetch(parse(path), username) do
      {:ok, hashed} ->
        fp =
          :crypto.hash(:sha256, hashed)
          |> Base.encode16(case: :lower)
          |> binary_part(0, 16)

        {:ok, fp}

      :error ->
        :error
    end
  end

  @doc "Sorted list of usernames in the file."
  @spec list_users(Path.t()) :: [String.t()]
  def list_users(path), do: path |> parse() |> Map.keys() |> Enum.sort()

  @doc """
  Read the file into `%{username => hash}`. Missing or unreadable files yield
  an empty map; malformed lines are skipped with a warning (python parity).
  """
  @spec parse(Path.t()) :: %{String.t() => String.t()}
  def parse(path) do
    case File.read(path) do
      {:ok, raw} ->
        raw
        |> String.split(["\n", "\r\n"])
        |> Enum.with_index(1)
        |> Enum.reduce(%{}, fn {raw_line, lineno}, acc ->
          parse_line(String.trim(raw_line), lineno, path, acc)
        end)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("could not read htpasswd #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp parse_line("", _lineno, _path, acc), do: acc
  defp parse_line("#" <> _, _lineno, _path, acc), do: acc

  defp parse_line(line, lineno, path, acc) do
    case String.split(line, ":", parts: 2) do
      [username, hashed] when username != "" and hashed != "" ->
        Map.put(acc, String.trim(username), String.trim(hashed))

      _ ->
        Logger.warning("skipping malformed htpasswd line #{lineno} in #{path}")
        acc
    end
  end
end
