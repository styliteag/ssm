defmodule MctlContract.MixProject do
  use Mix.Project

  @version "0.4.0"

  def project do
    [
      app: :mctl_contract,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Shared mctl contract v1: plug, envelope, cursor, tokens, jobs, conformance",
      package: [
        licenses: ["Apache-2.0"],
        files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE)
      ],
      test_coverage: [ignore_modules: [~r/^MctlContract\.Test\./]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.26", only: :test}
    ]
  end
end
