defmodule SsmWeb.MctlConformanceTest do
  use MctlContract.ConformanceCase,
    endpoint: SsmWeb.Endpoint,
    base: "/api/mctl/v1",
    fixtures: Ssm.MctlFixtures
end
