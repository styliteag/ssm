defmodule Ssm.Authorizations.Login do
  @moduledoc """
  The remote login of an authorization or grant: a POSIX-style user name —
  a letter or `_` first, then letters, digits, `_`, `.` and `-`, at most 32
  characters, optionally ending in `$` (Samba machine accounts). Upper case
  is allowed (`Administrator` on Windows OpenSSH hosts). So a login never
  starts with `-` (it would read as an option to `getent` and other tools)
  and is never all digits (a uid).

  Checked only when a login is set or changed (`validate/1`): rows stored
  before with another login (AD/SSSD names like `user@domain`) stay as they
  are, and split/merge copy them unchanged.
  """

  @format ~r/\A[A-Za-z_][A-Za-z0-9_.-]{0,31}\$?\z/

  @message "must be a user name: a letter or _ first, then letters, digits, _ . -, " <>
             "at most 32 characters (an optional trailing $)"

  @doc "Is `login` a valid login?"
  @spec valid?(term()) :: boolean()
  def valid?(login) when is_binary(login), do: Regex.match?(@format, login)
  def valid?(_login), do: false

  @doc """
  Changeset check of a changed `:login` (an unchanged one is not checked;
  one that already has an error, e.g. control characters, gets no second).
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :login),
      do: changeset,
      else: Ecto.Changeset.validate_format(changeset, :login, @format, message: @message)
  end
end
