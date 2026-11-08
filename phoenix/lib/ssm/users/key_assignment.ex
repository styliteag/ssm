defmodule Ssm.Users.KeyAssignment do
  @moduledoc """
  Assigning a key found on a host but missing from the database (diff page,
  "Assign unknown key"): to an existing user or to a new user created on the
  spot, with a chosen key name, plus the grant for the login the key was
  found under. User, key and grant are written in one transaction, so a
  failure (e.g. a taken user name) leaves nothing behind. Database only: the
  host itself changes with a later sync.

  With `:scope` (web UI, ADR-0012 §3; default global) an existing user must
  be `Ssm.Users.writable?/2` – the new key lands on every host of that user –
  and the grant's host must be in scope. With `:role` other than `"admin"`
  (default: none, fails closed) an existing user holding admin-only options
  is refused before anything is written (`Ssm.Users.check_admin_only/3`,
  audited with `:actor`).
  """

  alias Ecto.Changeset
  alias Ssm.{Authorizations, Repo, Users}
  alias Ssm.Users.{User, UserKey}

  @doc """
  User name suggested for a key comment: the part before "@" of the last
  token when that token holds an "@" (`"Oliver Tegeler ot@FW13-OT"` →
  `"ot"`), otherwise the whole comment slugged (`"Oliver Tegeler"` →
  `"oliver-tegeler"`); `""` without a usable comment.
  """
  @spec suggest_username(String.t() | nil) :: String.t()
  def suggest_username(nil), do: ""

  def suggest_username(comment) when is_binary(comment) do
    last = comment |> String.split() |> List.last()

    if last && String.contains?(last, "@"),
      do: last |> String.split("@", parts: 2) |> hd(),
      else: slug(comment)
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.trim("-")
  end

  @type params :: %{
          user: :new | User.t(),
          username: String.t() | nil,
          key_name: String.t() | nil,
          parsed: %{key_type: String.t(), key_base64: String.t(), name: String.t() | nil},
          host_id: integer(),
          login: String.t()
        }

  @doc """
  Writes user (when `user: :new`), key and grant. Returns
  `{:ok, %{user, key, user_created?, granted?}}` or `{:error, {field, message}}`
  with `field` `:username`, `:key` or `:authorization`.
  """
  @spec assign(params()) ::
          {:ok, %{user: User.t(), key: UserKey.t(), user_created?: boolean, granted?: boolean}}
          | {:error, {atom(), String.t()}}
  def assign(%{} = params) do
    with :ok <- check_admin_only(params), do: assign_in_transaction(params)
  end

  defp check_admin_only(%{user: %User{} = user} = params) do
    opts = [role: Map.get(params, :role), actor: Map.get(params, :actor)]

    case Users.check_admin_only([user], "assign key", opts) do
      :ok ->
        :ok

      {:error, :admin_only_options} ->
        {:error,
         {:key, "#{user.username} holds admin-only key options; only an admin may add keys."}}
    end
  end

  defp check_admin_only(_params), do: :ok

  defp assign_in_transaction(params) do
    Repo.transaction(fn ->
      with {:ok, user, created?} <- ensure_user(params),
           {:ok, key} <- create_or_adopt_key(user, params),
           {:ok, granted?} <- grant(user, params) do
        %{user: user, key: key, user_created?: created?, granted?: granted?}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_user(%{user: :new, username: username}) do
    case Users.create_user(%{username: String.trim(username || "")}) do
      {:ok, user} -> {:ok, user, true}
      {:error, changeset} -> {:error, {:username, error_text(changeset, :username)}}
    end
  end

  defp ensure_user(%{user: %User{} = user} = params) do
    if Users.writable?(scope(params), user),
      do: {:ok, user, false},
      else:
        {:error,
         {:key, "#{user.username} has access outside your scope; its keys are read-only."}}
  end

  defp scope(params), do: Map.get(params, :scope, Ssm.Scope.global())

  # A key that already exists in the DB (assigned to someone) is adopted
  # as it is instead of failing.
  defp create_or_adopt_key(user, %{parsed: parsed} = params) do
    attrs = %{
      user_id: user.id,
      key_type: parsed.key_type,
      key_base64: parsed.key_base64,
      name: key_name(params)
    }

    case Users.create_key(attrs) do
      {:ok, key} ->
        {:ok, key}

      {:error, changeset} ->
        case {changeset.errors[:key_base64], Users.get_key_by_base64(parsed.key_base64)} do
          {{"has already been taken", _}, %UserKey{} = key} -> {:ok, key}
          _ -> {:error, {:key, "Could not save the key — check the key line."}}
        end
    end
  end

  defp key_name(%{key_name: name, parsed: parsed}) do
    case name && String.trim(name) do
      nil -> parsed.name
      "" -> parsed.name
      trimmed -> trimmed
    end
  end

  defp grant(user, %{host_id: host_id, login: login} = params) do
    if Authorizations.exists?(user.id, host_id, login) do
      {:ok, false}
    else
      case Authorizations.create_authorization(scope(params), %{
             user_id: user.id,
             host_id: host_id,
             login: login
           }) do
        {:ok, _auth} -> {:ok, true}
        {:error, _changeset} -> {:error, {:authorization, "Could not create the authorization."}}
      end
    end
  end

  defp error_text(changeset, field) do
    case Changeset.traverse_errors(changeset, fn {msg, opts} ->
           Enum.reduce(opts, msg, fn {k, v}, acc ->
             String.replace(acc, "%{#{k}}", to_string(v))
           end)
         end)[field] do
      [message | _] -> "User name #{message}"
      _ -> "Could not create the user — check the name."
    end
  end
end
