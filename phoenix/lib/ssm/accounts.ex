defmodule Ssm.Accounts do
  @moduledoc """
  Operators (OIDC web accounts): upsert at login, session revocation.
  Local `.htpasswd` users are not stored here.
  """

  import Ecto.Query

  alias Ssm.Accounts.Operator
  alias Ssm.Repo

  @spec get_operator(term()) :: Operator.t() | nil
  def get_operator(id) when is_integer(id), do: Repo.get(Operator, id)
  def get_operator(_), do: nil

  @doc """
  Insert or overwrite the operator for (`issuer`, `subject`). Name, e-mail,
  role and customers are overwritten every time; `disabled_at` is untouched.
  `attrs`: `:name`, `:email`, `:role`, `:customers` (list of slugs), `:sid`.
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
      role: attrs.role,
      customers: Jason.encode!(attrs[:customers] || []),
      last_sid: attrs[:sid],
      last_login_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert_or_update()
    |> tap(&disconnect_on_role_change(existing, &1))
  end

  defp disconnect_on_role_change(%Operator{role: old}, {:ok, %Operator{role: new} = operator})
       when old != new,
       do: disconnect_sessions(operator.id)

  defp disconnect_on_role_change(_existing, _result), do: :ok

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
  def customers(%Operator{customers: json}), do: Jason.decode!(json)

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
