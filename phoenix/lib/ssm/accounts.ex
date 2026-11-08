defmodule Ssm.Accounts do
  @moduledoc """
  Operators (OIDC web accounts): upsert at login, session revocation.
  Local `.htpasswd` users are not stored here.
  """

  import Ecto.Query

  alias Ssm.Accounts.Operator
  alias Ssm.{Repo, Scope}

  @spec get_operator(term()) :: Operator.t() | nil
  def get_operator(id) when is_integer(id), do: Repo.get(Operator, id)
  def get_operator(_), do: nil

  @doc """
  Insert or overwrite the operator for (`issuer`, `subject`). Name, e-mail,
  `email_verified`, role, customers and groups are overwritten every time;
  `disabled_at` is untouched. `verified_email` is set once, from the first
  login whose e-mail is verified, and never moves afterwards (the IdP user
  may change the claim; offboarding matches by this one only).
  `attrs`: `:name`, `:email`, `:email_verified`, `:role`, `:customers`
  and `:groups` (lists of slugs, `["*"]` = all), `:sid`. A changed role or
  scope disconnects the operator's open LiveViews.
  """
  @spec upsert_from_oidc(String.t(), String.t(), map()) ::
          {:ok, Operator.t()} | {:error, Ecto.Changeset.t()}
  def upsert_from_oidc(issuer, subject, attrs) do
    existing = Repo.get_by(Operator, oidc_issuer: issuer, oidc_subject: subject)

    (existing || %Operator{})
    |> Operator.login_changeset(%{
      oidc_issuer: issuer,
      oidc_subject: subject,
      name: attrs.name,
      email: attrs[:email],
      email_verified: attrs[:email_verified] == true,
      verified_email: verified_email(existing, attrs),
      role: attrs.role,
      customers: Jason.encode!(attrs[:customers] || []),
      groups: Jason.encode!(attrs[:groups] || []),
      last_sid: attrs[:sid],
      last_login_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert_or_update()
    |> tap(&disconnect_on_change(existing, &1))
  end

  defp verified_email(%Operator{verified_email: frozen}, _attrs) when is_binary(frozen),
    do: frozen

  defp verified_email(_existing, %{email_verified: true, email: email})
       when is_binary(email) and email != "",
       do: email

  defp verified_email(_existing, _attrs), do: nil

  defp disconnect_on_change(%Operator{} = old, {:ok, %Operator{} = new}) do
    if rights(old) != rights(new), do: disconnect_sessions(new.id), else: :ok
  end

  defp disconnect_on_change(_existing, _result), do: :ok

  defp rights(%Operator{} = operator), do: {operator.role, scope(operator)}

  @doc "Audit label of an operator: distinct from any `.htpasswd` user name."
  @spec actor_label(Operator.t()) :: String.t()
  def actor_label(%Operator{} = operator), do: "#{operator.name} (oidc:#{operator.id})"

  @doc "LiveView socket topic of an operator's sessions."
  @spec socket_id(integer()) :: String.t()
  def socket_id(operator_id), do: "ssm_sessions:op:#{operator_id}"

  @doc "Disconnect every open LiveView of the operator; they re-mount through the session checks."
  @spec disconnect_sessions(integer()) :: :ok
  def disconnect_sessions(operator_id),
    do: SsmWeb.Endpoint.broadcast(socket_id(operator_id), "disconnect", %{})

  @doc "Customer slugs of an operator (`[\"*\"]` = all)."
  @spec customers(Operator.t()) :: [String.t()]
  def customers(%Operator{customers: json}), do: decode_list(json)

  @doc "Host-group slugs of an operator (`[\"*\"]` = all)."
  @spec groups(Operator.t()) :: [String.t()]
  def groups(%Operator{groups: json}), do: decode_list(json)

  @doc """
  The operator's host scope (`Ssm.Scope`, ADR-0012). An admin is always
  global (the login refuses a scoped admin); an unreadable stored list is
  empty (fail closed).
  """
  @spec scope(Operator.t()) :: Scope.t()
  def scope(%Operator{role: "admin"}), do: Scope.global()
  def scope(%Operator{} = operator), do: Scope.new(customers(operator), groups(operator))

  defp decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_list(_json), do: []

  @doc "Admin switch: a disabled operator is refused at login and mid-session."
  @spec set_disabled(Operator.t(), boolean()) :: {:ok, Operator.t()}
  def set_disabled(%Operator{} = operator, disabled?) do
    at = if disabled?, do: DateTime.utc_now() |> DateTime.truncate(:second)
    result = operator |> Ecto.Changeset.change(disabled_at: at) |> Repo.update()
    if disabled?, do: disconnect_sessions(operator.id)
    result
  end

  @doc "End all sessions of the operator that began before now."
  @spec revoke_sessions(Operator.t()) :: {:ok, Operator.t()}
  def revoke_sessions(%Operator{} = operator) do
    operator |> Operator.revoke_changeset(now_ms()) |> Repo.update()
  end

  @doc "Revoke by issuer + subject; `{:ok, ids}` of the operators hit."
  @spec revoke_by_subject(String.t(), String.t()) :: {:ok, [integer()]}
  def revoke_by_subject(issuer, subject) do
    revoke(from o in Operator, where: o.oidc_issuer == ^issuer and o.oidc_subject == ^subject)
  end

  @doc "Remember a revoked `sid` for `ttl` seconds (the longest an OIDC session can live)."
  @spec revoke_sid(String.t(), String.t(), integer()) :: :ok
  def revoke_sid(issuer, sid, ttl) do
    now = System.os_time(:second)
    Repo.delete_all(from(r in "oidc_revoked_sids", where: r.expires_at <= ^now))

    Repo.insert_all(
      "oidc_revoked_sids",
      [%{issuer: issuer, sid: sid, expires_at: now + ttl}],
      on_conflict: {:replace, [:expires_at]},
      conflict_target: [:issuer, :sid]
    )

    :ok
  end

  @doc "Was this `sid` revoked by a back-channel logout and not yet expired?"
  @spec sid_revoked?(String.t(), String.t() | nil) :: boolean()
  def sid_revoked?(_issuer, nil), do: false

  def sid_revoked?(issuer, sid) do
    now = System.os_time(:second)

    Repo.exists?(
      from(r in "oidc_revoked_sids",
        where: r.issuer == ^issuer and r.sid == ^sid and r.expires_at > ^now
      )
    )
  end

  @doc "Ids of operators whose last login carried `sid` (to disconnect their LiveViews)."
  @spec operator_ids_by_sid(String.t(), String.t()) :: [integer()]
  def operator_ids_by_sid(issuer, sid),
    do:
      Repo.all(
        from(o in Operator, where: o.oidc_issuer == ^issuer and o.last_sid == ^sid, select: o.id)
      )

  defp revoke(query) do
    ids = Repo.all(select(query, [o], o.id))
    Repo.update_all(from(o in Operator, where: o.id in ^ids), set: [session_revoked_at: now_ms()])
    {:ok, ids}
  end

  @doc "Unix milliseconds; the clock for session start and revocation."
  def now_ms, do: System.system_time(:millisecond)
end
