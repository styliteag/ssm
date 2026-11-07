defmodule Ssm.People do
  @moduledoc """
  What ssm knows about a person, for mctl offboarding (contract section 10,
  US-ADM-09). A person key is `oidc:<iss>|<sub>` or `email:<address>`.

  Matching (shown to the admin, with the reason per item, before anything
  is removed):

    * the operator (`operators`) by issuer + subject; for an `email:` key
      the operator whose **verified** e-mail it is – several such
      operators are a conflict (use `oidc:`);
    * the person's e-mail: for `oidc:` only the operator's
      `verified_email` (set at the first login with `email_verified`,
      never moved by a later claim – an IdP user who changes their e-mail
      claim cannot redirect an offboarding to a colleague); for `email:`
      the address itself;
    * SSH users (`user`) whose username is that e-mail – all their keys
      and authorizations;
    * single keys (`user_key`) of other users whose comment (`name`) is
      that e-mail ("shared keys": the shared user keeps its
      authorizations, only the key goes).

  Key material never leaves this module: keys are described by SHA256
  fingerprint and comment.
  """

  import Ecto.Query

  alias Ssm.Accounts.Operator
  alias Ssm.Authorizations.Authorization
  alias Ssm.Repo
  alias Ssm.Users.{User, UserKey}

  defmodule Match do
    @moduledoc "The records of one person and why they matched."
    defstruct [:key, :email, :email_source, :operator, users: [], keys: [], shared_keys: []]

    @type t :: %__MODULE__{
            key: String.t(),
            email: String.t() | nil,
            email_source: String.t() | nil,
            operator: Ssm.Accounts.Operator.t() | nil,
            users: [Ssm.Users.User.t()],
            keys: [Ssm.Users.UserKey.t()],
            shared_keys: [Ssm.Users.UserKey.t()]
          }
  end

  @doc """
  `{:ok, match}`; `{:error, :not_found}` when ssm knows nothing;
  `{:error, {:conflict, msg}}` when an `email:` key is the verified e-mail
  of several operators.
  """
  @spec find(String.t()) :: {:ok, Match.t()} | {:error, :not_found | {:conflict, String.t()}}
  def find(key) do
    with {:ok, operator, email, source} <- operator_and_email(key) do
      users = users_by_email(email)
      user_ids = Enum.map(users, & &1.id)
      keys = Repo.all(from k in UserKey, where: k.user_id in ^user_ids, order_by: k.id)
      shared = shared_keys(email, user_ids)

      if operator == nil and users == [] and shared == [] do
        {:error, :not_found}
      else
        {:ok,
         %Match{
           key: key,
           email: email,
           email_source: source,
           operator: operator,
           users: users,
           keys: keys,
           shared_keys: shared
         }}
      end
    end
  end

  @doc "Why a key belongs to the person (one line, no key material)."
  @spec key_reason(Match.t(), UserKey.t()) :: String.t()
  def key_reason(%Match{} = match, %UserKey{} = key) do
    case Enum.find(match.users, &(&1.id == key.user_id)) do
      %User{username: name} -> "ssh user #{name} (#{match.email_source})"
      nil -> "key comment #{key.name} (#{match.email_source})"
    end
  end

  @doc "Why an authorization belongs to the person."
  @spec authorization_reason(Match.t(), Authorization.t()) :: String.t()
  def authorization_reason(%Match{} = match, %Authorization{user_id: user_id}) do
    %User{username: name} = Enum.find(match.users, &(&1.id == user_id))
    "ssh user #{name} (#{match.email_source})"
  end

  @doc "Authorizations of the person's own users, by host and login."
  @spec authorizations(Match.t()) :: [Authorization.t()]
  def authorizations(%Match{users: users}) do
    ids = Enum.map(users, & &1.id)
    Repo.all(from a in Authorization, where: a.user_id in ^ids, order_by: [a.host_id, a.login])
  end

  @doc "Host ids a key is deployed to according to the database."
  @spec key_hosts(UserKey.t()) :: [integer()]
  def key_hosts(%UserKey{user_id: user_id}) do
    Repo.all(
      from a in Authorization,
        where: a.user_id == ^user_id,
        distinct: true,
        order_by: a.host_id,
        select: a.host_id
    )
  end

  @doc "All keys of the match (own and shared), each once."
  @spec all_keys(Match.t()) :: [UserKey.t()]
  def all_keys(%Match{keys: keys, shared_keys: shared}), do: keys ++ shared

  @doc "OpenSSH style `SHA256:<base64>` fingerprint of a key's base64 blob."
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(base64) do
    blob =
      case Base.decode64(base64, padding: false) do
        {:ok, decoded} -> decoded
        :error -> base64
      end

    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
  end

  @doc """
  Deletes the authorizations of the person's own users (on `host_ids`, or
  all when nil); returns the ids of the hosts that held one. Shared keys
  are not touched here: `delete_keys/1` removes them only after every host
  was scrubbed.
  """
  @spec remove_authorizations(Match.t(), [integer()] | nil) :: {:ok, [integer()]}
  def remove_authorizations(%Match{} = match, host_ids) do
    user_ids = Enum.map(match.users, & &1.id)

    query =
      from(a in Authorization, where: a.user_id in ^user_ids)
      |> then(&if(host_ids, do: where(&1, [a], a.host_id in ^host_ids), else: &1))

    Repo.transaction(fn ->
      hosts = Repo.all(from a in query, distinct: true, select: a.host_id)
      Repo.delete_all(query)
      hosts
    end)
  end

  @doc "Delete `user_key` rows by id."
  @spec delete_keys([integer()]) :: {non_neg_integer(), nil}
  def delete_keys(ids), do: Repo.delete_all(from k in UserKey, where: k.id in ^ids)

  defp operator_and_email("oidc:" <> rest) do
    case String.split(rest, "|", parts: 2) do
      [iss, sub] ->
        op = Repo.one(from o in Operator, where: o.oidc_issuer == ^iss and o.oidc_subject == ^sub)
        email = op && op.verified_email
        {:ok, op, email, email && "verified e-mail of the operator"}

      _ ->
        {:ok, nil, nil, nil}
    end
  end

  defp operator_and_email("email:" <> address) do
    down = String.downcase(address)

    case Repo.all(
           from o in Operator,
             where: fragment("lower(?)", o.verified_email) == ^down,
             order_by: o.id
         ) do
      [_, _ | _] ->
        {:error,
         {:conflict, "several operators have this verified e-mail; use the oidc:<iss>|<sub> key"}}

      ops ->
        {:ok, List.first(ops), address, "e-mail of the person key"}
    end
  end

  defp operator_and_email(_key), do: {:ok, nil, nil, nil}

  defp users_by_email(nil), do: []

  defp users_by_email(email) do
    down = String.downcase(email)
    Repo.all(from u in User, where: fragment("lower(?)", u.username) == ^down, order_by: u.id)
  end

  defp shared_keys(nil, _user_ids), do: []

  defp shared_keys(email, user_ids) do
    down = String.downcase(email)

    Repo.all(
      from k in UserKey,
        where: fragment("lower(?)", k.name) == ^down and k.user_id not in ^user_ids,
        order_by: k.id
    )
  end
end
