defmodule Ssm.Authorizations.Login do
  @moduledoc """
  The remote login of an authorization, as `script.sh` passes it to
  `getent passwd` on the host. Refused: an all-numeric login (getent
  resolves it as a uid — `"0"` is root), a leading `-` (read as an option),
  whitespace, `:` (the passwd field separator) and `/` (a path), plus every
  control character (`Ssm.ControlChars`). Directory-service names stay
  allowed: `user@corp.example`, `CORP\\user`, dots, uppercase.

  This is deliberately not a strict POSIX/useradd charset (AD/SSSD logins);
  a stricter policy is an open product decision.
  """

  import Ecto.Changeset

  alias Ssm.ControlChars

  @max 255
  @message "must be a login name (no whitespace, ':' or '/', not all digits, not starting with '-')"
  @refused ~r/[\s:\/]/u

  @doc "True when `login` is a login ssm may pass to a host."
  @spec valid?(term()) :: boolean()
  def valid?(login) when is_binary(login) do
    login != "" and String.length(login) <= @max and not ControlChars.present?(login) and
      not String.starts_with?(login, "-") and not Regex.match?(@refused, login) and
      not Regex.match?(~r/\A[0-9]+\z/, login)
  end

  def valid?(_login), do: false

  @doc "Changeset check of `field` (control characters are reported by `Ssm.ControlChars`)."
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if ControlChars.present?(value) or valid?(value), do: [], else: [{field, @message}]
    end)
  end
end
