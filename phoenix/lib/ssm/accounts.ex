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
    operator =
      Repo.get_by(Operator, oidc_issuer: issuer, oidc_subject: subject) || %Operator{}

    operator
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
  end

  @doc "Customer slugs of an operator (`[\"*\"]` = all)."
  @spec customers(Operator.t()) :: [String.t()]
  def customers(%Operator{customers: json}), do: Jason.decode!(json)

  @doc "Admin switch: a disabled operator is refused at login and mid-session."
  @spec set_disabled(Operator.t(), boolean()) :: {:ok, Operator.t()}
  def set_disabled(%Operator{} = operator, disabled?) do
    at = if disabled?, do: DateTime.utc_now() |> DateTime.truncate(:second)
    operator |> Ecto.Changeset.change(disabled_at: at) |> Repo.update()
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

  @doc "Revoke the operator whose last login carried this `sid`."
  @spec revoke_by_sid(String.t(), String.t()) :: {:ok, [integer()]}
  def revoke_by_sid(issuer, sid) do
    revoke(from o in Operator, where: o.oidc_issuer == ^issuer and o.last_sid == ^sid)
  end

  defp revoke(query) do
    ids = Repo.all(select(query, [o], o.id))
    Repo.update_all(from(o in Operator, where: o.id in ^ids), set: [session_revoked_at: now_ms()])
    {:ok, ids}
  end

  @doc "Unix milliseconds; the clock for session start and revocation."
  def now_ms, do: System.system_time(:millisecond)
end
