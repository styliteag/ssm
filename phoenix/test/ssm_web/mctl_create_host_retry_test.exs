defmodule SsmWeb.MctlCreateHostRetryTest do
  @moduledoc """
  Which failed login attempts of a `create_host` job are tried again. A
  host's login guard (sshguard on pfSense) refuses the connection for a
  while after failed logins: that is waited out, a refused first connection
  (wrong port) is not.
  """
  use ExUnit.Case, async: true

  alias SsmWeb.Mctl.CreateHostJob

  @refused {:ssh_connect_failed, "ssh connect failed for fw: :econnrefused"}

  test "a refused connection is retried only after a failed login of the same job" do
    refute CreateHostJob.retry?(@refused, false)
    assert CreateHostJob.retry?(@refused, true)
  end

  test "a changed host key is never retried" do
    refute CreateHostJob.retry?({:host_key_changed, %{}}, true)
  end
end
