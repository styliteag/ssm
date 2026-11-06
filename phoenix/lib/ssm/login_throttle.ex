defmodule Ssm.LoginThrottle do
  @moduledoc """
  Failed-login limit for password logins (web form and `/api/v2/auth/login`),
  on `Ssm.RateLimit`.

  Failures are counted per client (IPv6: its /64) and per username
  (trimmed, lowercased — unknown names count too, so the limit does not
  reveal which names exist). At the limit the client / username is locked
  until its fixed window ends (at most `window` seconds). Callers `check/2`
  first and refuse a locked request without verifying the password, then
  `record_failure/2` or `record_success/1`. A success resets the username
  counter only; the IP counter is left alone, so one valid account cannot
  launder guesses against others.

  Locks are audited in the activity log (`login_locked`, type `auth`), once
  per subject and window, never with a password; the username is logged only if it names a known user, else as a short hash.

  Limits: `config :ssm, :login_limits, failures: 5, window: 900`.
  """

  alias Ssm.Activity
  alias Ssm.Auth.Htpasswd
  alias Ssm.RateLimit

  @defaults [failures: 5, window: 900]

  @doc "`{failures, window_seconds}` in effect."
  @spec limits() :: {pos_integer(), pos_integer()}
  def limits do
    config = Application.get_env(:ssm, :login_limits, [])

    {Keyword.get(config, :failures, @defaults[:failures]),
     Keyword.get(config, :window, @defaults[:window])}
  end

  @doc "`:ok`, or `{:error, retry_after_seconds}` when the IP or the username is locked. Does not count."
  @spec check(:inet.ip_address(), String.t()) :: :ok | {:error, pos_integer()}
  def check(ip, username) do
    {limit, window} = limits()

    results = [
      RateLimit.check(ip_key(ip), limit, window),
      RateLimit.check(user_key(username), limit, window)
    ]

    case for({:error, retry} <- results, do: retry) do
      [] -> :ok
      retries -> {:error, Enum.max(retries)}
    end
  end

  @doc "Count one failed login against the IP and the username; audits when either reaches the limit."
  @spec record_failure(:inet.ip_address(), String.t()) :: :ok
  def record_failure(ip, username) do
    {limit, window} = limits()
    norm = normalize(username)

    if RateLimit.count(ip_key(ip), window) == limit,
      do: audit("ip", %{ip: ip |> :inet.ntoa() |> to_string()}, limit, window)

    if RateLimit.count(user_key(username), window) == limit,
      do: audit("username", %{username: audit_name(norm)}, limit, window)

    :ok
  end

  @doc "A successful login: forget the username's failures (not the IP's)."
  @spec record_success(String.t()) :: :ok
  def record_success(username), do: RateLimit.clear(user_key(username))

  defp audit(subject, details, limit, window) do
    Activity.log(%{
      activity_type: "auth",
      action: "login_locked",
      target: "login",
      actor_username: "anonymous",
      details: Map.merge(details, %{subject: subject, failures: limit, window_seconds: window})
    })
  end

  # A known login name is logged as is; anything else (possibly a password
  # typed into the username field) only as a short hash. Runs on the lock
  # event only, never on the login hot path.
  defp audit_name(norm) do
    path = Application.get_env(:ssm, :htpasswd_path, ".htpasswd")

    if Enum.any?(Htpasswd.list_users(path), &(String.downcase(&1) == norm)) do
      norm
    else
      "sha256:" <>
        (:crypto.hash(:sha256, norm) |> Base.encode16(case: :lower) |> binary_part(0, 16))
    end
  rescue
    _ -> "sha256:unavailable"
  end

  defp ip_key(ip), do: {:login_failed_ip, RateLimit.client_key(ip)}

  # Hashed: keeps the ETS key small whatever a client sends as username.
  defp user_key(username),
    do: {:login_failed_user, :crypto.hash(:sha256, normalize(username))}

  defp normalize(username), do: username |> to_string() |> String.trim() |> String.downcase()
end
