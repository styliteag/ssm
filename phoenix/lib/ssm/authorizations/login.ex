defmodule Ssm.Authorizations.Login do
  @moduledoc """
  The remote login of an authorization or grant, in one of two forms:

    * a POSIX-style user name — a letter or `_` first, then letters, digits,
      `_`, `.` and `-`, at most 32 characters, optionally ending in `$`
      (Samba machine accounts);
    * an SSSD/AD name `user@domain` — the same local part (no `$`, at most
      64 characters), `@`, then a domain of dot-separated labels (letters,
      digits, `-` inside a label), at most 128 characters in all.

  Upper case is allowed (`Administrator` on Windows OpenSSH hosts). So a
  login never starts with `-` (it would read as an option to `getent` and
  other tools), is never all digits (a uid) and never holds whitespace,
  `:`, `/`, `\\` (`DOMAIN\\user` is refused) or a control character.

  Checked only when a login is set or changed (`validate/1`): rows stored
  before with another login (such as `DOMAIN\\user`) stay as they are, and
  split/merge copy them unchanged.
  """

  alias Ssm.ControlChars

  # POSIX name (optional trailing $) | local@label(.label)*, a label never
  # starting or ending in "-"; 128 characters at most in all
  @format ~r/\A(?=.{1,128}\z)(?:[A-Za-z_][A-Za-z0-9_.-]{0,31}\$?|[A-Za-z_][A-Za-z0-9_.-]{0,63}@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)\z/

  @message "must be a user name (a letter or _ first, then letters, digits, _ . -, " <>
             "at most 32 characters, an optional trailing $) or user@domain " <>
             "(at most 64 characters before @, 128 in all)"

  @doc "Is `login` a valid login?"
  @spec valid?(term()) :: boolean()
  def valid?(login) when is_binary(login), do: Regex.match?(@format, login)
  def valid?(_login), do: false

  @doc """
  May ssm pass `login` to a host at all? The weaker check for logins read
  from a host or stored before `valid?/1` existed (`DOMAIN\\user` stays
  usable): never empty, never all digits or a leading `+` (getent reads a
  uid: `+0` is root), never a leading `-` (an option), no whitespace, `:`,
  `/` or control characters. `script.sh` (`login_ok`) refuses the same.
  """
  @spec host_safe?(term()) :: boolean()
  def host_safe?(login) when is_binary(login),
    do:
      Regex.match?(~r/\A(?![0-9]+\z)[^\s:\/+-][^\s:\/]{0,254}\z/u, login) and
        not ControlChars.present?(login)

  def host_safe?(_login), do: false

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
