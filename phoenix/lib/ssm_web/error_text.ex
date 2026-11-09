defmodule SsmWeb.ErrorText do
  @moduledoc """
  Plain sentences for errors shown in the web UI. Raw Elixir terms (tuples,
  structs, exit reasons) never reach the page: they go to the server log and
  the user reads a sentence. Tagged `{code, message}` errors keep their
  message — those are written for people already (`Ssm.Ssh.ErrorCode`).
  """

  require Logger

  @unexpected "unexpected error (details are in the server log)"

  @doc "The text for an error reason inside a sentence (\"… failed: <text>\")."
  @spec reason(term()) :: String.t()
  def reason({_code, message}) when is_binary(message), do: message

  def reason(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: atom |> Atom.to_string() |> String.replace("_", " ")

  def reason(other) do
    Logger.error("UI error: #{inspect(other)}")
    @unexpected
  end

  @doc """
  The flash for an async task that exited (`handle_async/3` `{:exit, reason}`):
  logs `what` and the reason, returns a sentence without the reason.
  """
  @spec crashed(String.t(), term()) :: String.t()
  def crashed(what, reason) do
    Logger.error("#{what} crashed: #{inspect(reason)}")
    "#{what} failed unexpectedly. The details are in the server log."
  end
end
