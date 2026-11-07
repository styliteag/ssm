defmodule MctlContractVendoredTest do
  @moduledoc """
  `vendor/mctl_contract` is an unmodified, current mctl_contract release
  (copied by `mctl_contract/scripts/vendor.sh <tag> <mix-project-dir>`).

  The hash check always runs. The "newest tag" check runs only where a
  mctl_contract checkout sits next to this repo (developer machines), not
  in CI or Docker builds.
  """
  use ExUnit.Case, async: true

  @project Path.expand("..", __DIR__)
  @vendored Path.join(@project, "vendor/mctl_contract")
  @checkout Enum.find(
              Enum.map(
                ["../../mctl_contract", "../../../mctl_contract"],
                &Path.expand(&1, @project)
              ),
              &File.dir?(Path.join(&1, ".git"))
            )

  test "vendor/mctl_contract is unmodified (hash in VENDORED)" do
    assert meta()["sha256"] == tree_hash(@vendored),
           "vendor/mctl_contract differs from #{meta()["tag"]}: change mctl_contract, " <>
             "tag it and run its scripts/vendor.sh instead of editing the copy"
  end

  if @checkout do
    test "vendor/mctl_contract is the newest mctl_contract tag" do
      {out, 0} = System.cmd("git", ["-C", @checkout, "tag", "--list", "v*", "--sort=-v:refname"])
      newest = out |> String.split("\n", trim: true) |> List.first()

      assert meta()["tag"] == newest,
             "mctl_contract #{newest} is out, vendored is #{meta()["tag"]}: " <>
               "run #{@checkout}/scripts/vendor.sh #{newest} #{@project}"
    end
  end

  defp meta do
    for line <- File.read!(Path.join(@vendored, "VENDORED")) |> String.split("\n"),
        [key, value] <- [String.split(line, ": ", parts: 2)],
        into: %{},
        do: {key, String.trim(value)}
  end

  # same as scripts/vendor.sh: sha256 over "<sha256>  ./<path>" lines, byte-sorted paths
  defp tree_hash(dir) do
    Path.wildcard(Path.join(dir, "**"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&("./" <> Path.relative_to(&1, dir)))
    |> Enum.reject(&(&1 == "./VENDORED"))
    |> Enum.sort()
    |> Enum.map_join(fn rel -> sha256(File.read!(Path.join(dir, rel))) <> "  " <> rel <> "\n" end)
    |> sha256()
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
