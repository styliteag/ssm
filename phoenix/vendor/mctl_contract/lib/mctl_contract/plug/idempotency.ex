defmodule MctlContract.Plug.Idempotency do
  @moduledoc false
  # `Idempotency-Key` on POST (same semantics as omon API v2): a retry
  # with the same key and request gets the first response again (header
  # `Idempotent-Replayed: true`); the same key with another request is
  # 422 idempotency_key_reused; a retry while the first one runs is 409
  # idempotency_in_progress. Server errors release the key.
  import Plug.Conn

  alias MctlContract.Plug.Respond

  @max_key 255

  def run(conn, store, fun) do
    case get_req_header(conn, "idempotency-key") do
      [] ->
        fun.(conn)

      [key] when byte_size(key) in 1..@max_key ->
        with_key(conn, store, key, fun)

      _ ->
        Respond.error(
          conn,
          "bad_request",
          "Idempotency-Key must be one value of 1-#{@max_key} bytes"
        )
    end
  end

  defp with_key(conn, store, key, fun) do
    token_id = to_string(conn.assigns.mctl_principal.id)

    case store.claim(token_id, key, request_hash(conn)) do
      {:new, ref} -> execute(conn, store, ref, fun)
      {:replay, record} -> replay(conn, record)
      :mismatch -> reused(conn)
      :in_progress -> in_progress(conn)
    end
  end

  defp execute(conn, store, ref, fun) do
    conn
    |> register_before_send(&save(&1, store, ref))
    |> fun.()
  rescue
    e ->
      store.release(ref)
      reraise e, __STACKTRACE__
  end

  defp save(conn, store, ref) do
    if conn.status < 500,
      do: store.complete(ref, conn.status, IO.iodata_to_binary(conn.resp_body)),
      else: store.release(ref)

    conn
  end

  defp replay(conn, record) do
    conn
    |> put_resp_header("idempotent-replayed", "true")
    |> put_resp_content_type("application/json")
    |> send_resp(record.status, record.response || "")
    |> halt()
  end

  defp reused(conn) do
    Respond.error(
      conn,
      "idempotency_key_reused",
      "Idempotency-Key was already used with a different request"
    )
  end

  defp in_progress(conn) do
    Respond.error(
      conn,
      "idempotency_in_progress",
      "a request with this Idempotency-Key is still running"
    )
  end

  defp request_hash(conn) do
    body = conn.body_params |> redact_secrets() |> Jason.encode!()
    payload = Enum.join([conn.method, conn.request_path, conn.query_string, body], "\n")
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  @secret ~r/password|passphrase|secret|token|private_key/i

  @doc false
  # the stored hash must not allow guessing secrets of the request (an
  # unsalted hash of a short password can be brute-forced): values of
  # secret-looking keys are left out, at any depth
  def redact_secrets(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if Regex.match?(@secret, to_string(k)), do: {k, "[redacted]"}, else: {k, redact_secrets(v)}
    end)
  end

  def redact_secrets(list) when is_list(list), do: Enum.map(list, &redact_secrets/1)
  def redact_secrets(other), do: other
end
