defmodule Ssm.Ssh.ShellTest do
  use ExUnit.Case, async: true

  alias Ssm.Ssh.Shell

  test "safe strings pass through unquoted" do
    assert Shell.quote("simple") == "simple"
    assert Shell.quote("a/b_c-d.e") == "a/b_c-d.e"
    assert Shell.quote("user@host:22") == "user@host:22"
  end

  test "empty string quotes to ''" do
    assert Shell.quote("") == "''"
  end

  test "spaces and shell metacharacters get single-quoted" do
    assert Shell.quote("two words") == "'two words'"
    assert Shell.quote("a;rm -rf /") == "'a;rm -rf /'"
    assert Shell.quote("$(evil)") == "'$(evil)'"
    assert Shell.quote("back`tick") == "'back`tick'"
  end

  test "embedded single quotes are closed, escaped, reopened (shlex parity)" do
    assert Shell.quote("it's") == "'it'\\''s'"
  end
end
