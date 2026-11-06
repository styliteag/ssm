defmodule SsmWeb.MctlProviderTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias MctlContract.Principal
  alias Ssm.{Customers, Groups, Hosts}
  alias Ssm.Ssh.MockClient
  alias SsmWeb.MctlProvider

  @ed "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"
  @ed_fp "ssh-ed25519 SHA256:fL66gvwaZdYDdKSZ3NwHakAvwnspoc1Lj5IAqcb4+4Q"
  @ecdsa_fp "ecdsa-sha2-nistp256 SHA256:lF0rWjfoTUXjkp9k51UM1vcqsjpqOz9XcMLrCCVpnNM"

  @machine_id "7f6b554ff5b43db2137ea2a70f5f40b584d6f4384399cdaaace85722c78c705f"

  @p %Principal{
    id: 1,
    name: "mission-control",
    prefix: "ssm_abc",
    scopes: ~w(read setup),
    ip: "203.0.113.9"
  }

  @wait Application.compile_env(:ssm, :mctl_login_wait)

  setup do
    start_supervised!(MockClient)
    :ok
  end

  defp page(after_key \\ nil, limit \\ 100, filters \\ %{}),
    do: %{after: after_key, limit: limit, filters: filters}

  # Job work runs under Ssm.Mctl.TaskSupervisor; wait for all of it.
  defp await_jobs do
    for pid <- Task.Supervisor.children(Ssm.Mctl.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    :ok
  end

  defp create_params(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "web#{System.unique_integer([:positive])}",
        "addresses" => ["10.9.0.#{rem(System.unique_integer([:positive]), 250) + 1}"],
        "mode" => "pull"
      },
      extra
    )
  end

  test "product/0" do
    assert %{product: "ssm", version: version} = MctlProvider.product()
    assert is_binary(version)
  end

  describe "hosts" do
    test "get_host maps an ssm host to the contract shape" do
      {:ok, _} = Customers.create_customer(%{slug: "kunde-a", name: "Kunde A"})
      {:ok, _} = Groups.create_group(%{slug: "web", name: "Web"})
      bastion = host_fixture(%{name: "bastion"})
      host = host_fixture(%{name: "web1", address: "10.0.0.5", port: 2222, jump_via: bastion.id})
      {:ok, host} = Hosts.update_membership(host, %{customer: "kunde-a", groups: ["web"]})

      {:ok, _} =
        Hosts.Host.key_changeset(host, %{public_key: @ed, fingerprint: @ed_fp}) |> Repo.update()

      assert {:ok, h} = MctlProvider.get_host(@p, to_string(host.id))
      assert h.id == to_string(host.id)
      assert h.name == "web1"
      assert h.addresses == ["10.0.0.5"]
      assert h.mode == "pull"
      assert h.kind == "other"
      assert h.customer == "kunde-a"
      assert h.groups == ["web"]
      assert h.ui_url =~ "/diff?host_id=#{host.id}"
      assert %DateTime{} = h.updated_at
      assert h.identity.ssh_host_keys == [@ed_fp]
      assert %DateTime{} = h.identity.observed_at
      assert h.identity.macs == []

      assert h.attributes == %{
               "username" => "root",
               "port" => 2222,
               "jump_via" => to_string(bastion.id),
               "disabled" => false,
               "comment" => nil,
               "limited" => false,
               "limited_reason" => nil
             }
    end

    test "attributes.limited flags a non-root login, with the reason" do
      root = host_fixture(%{name: "r", username: "root"})
      deploy = host_fixture(%{name: "d", username: "deploy"})

      assert {:ok, %{attributes: %{"limited" => false, "limited_reason" => nil}}} =
               MctlProvider.get_host(@p, to_string(root.id))

      assert {:ok, %{attributes: %{"limited" => true, "limited_reason" => reason}}} =
               MctlProvider.get_host(@p, to_string(deploy.id))

      assert reason =~ "deploy"
    end

    test "limited and limited_reason are read-only attributes" do
      assert {:error, {:validation, %{"attributes.limited" => ["is read-only"]}}} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"limited" => true}})
               )

      schema = MctlProvider.attributes_schema()
      assert schema["properties"]["limited"]["readOnly"] == true
    end

    test "a non-root create job reports limited: true" do
      MockClient.set_default_host_keys([@ed])

      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"username" => "deploy"}})
               )

      await_jobs()

      assert {:ok, %{state: "succeeded", result: %{"limited" => true, "username" => "deploy"}}} =
               MctlProvider.get_job(@p, job.id)
    end

    test "an unpinned host has no ssh_host_keys" do
      host = host_fixture()

      assert {:ok, %{identity: %{ssh_host_keys: [], observed_at: nil}}} =
               MctlProvider.get_host(@p, to_string(host.id))
    end

    test "ssh_host_keys use the exact spec format: <type> SHA256:<unpadded base64>" do
      host = host_fixture()

      {:ok, _} =
        Hosts.Host.key_changeset(host, %{public_key: @ed, fingerprint: @ed_fp}) |> Repo.update()

      assert {:ok, %{identity: %{ssh_host_keys: [key]}}} =
               MctlProvider.get_host(@p, to_string(host.id))

      assert key =~ ~r/\Assh-ed25519 SHA256:[A-Za-z0-9+\/]{43}\z/
    end

    test "a bare legacy pin with a stored key is reported typed; without a key it is omitted" do
      with_key = host_fixture()

      {:ok, _} =
        with_key
        |> Ecto.Changeset.change(
          host_key: @ed,
          key_fingerprint: "SHA256:" <> String.replace_prefix(@ed_fp, "ssh-ed25519 SHA256:", "")
        )
        |> Repo.update()

      bare = host_fixture()

      {:ok, _} =
        bare
        |> Ecto.Changeset.change(
          key_fingerprint: "SHA256:" <> String.replace_prefix(@ed_fp, "ssh-ed25519 SHA256:", "")
        )
        |> Repo.update()

      assert {:ok, %{identity: %{ssh_host_keys: [@ed_fp]}}} =
               MctlProvider.get_host(@p, to_string(with_key.id))

      assert {:ok, %{identity: %{ssh_host_keys: []}}} =
               MctlProvider.get_host(@p, to_string(bare.id))
    end

    test "identity carries the stored machine_id HMAC, nil when unknown" do
      host = host_fixture()

      assert {:ok, %{identity: %{machine_id: nil}}} =
               MctlProvider.get_host(@p, to_string(host.id))

      {:ok, _} = host |> Hosts.Host.machine_id_changeset(@machine_id) |> Repo.update()

      assert {:ok, %{identity: %{machine_id: @machine_id}}} =
               MctlProvider.get_host(@p, to_string(host.id))
    end

    test "get_host: unknown or malformed id is not_found" do
      assert {:error, :not_found} = MctlProvider.get_host(@p, "999999")
      assert {:error, :not_found} = MctlProvider.get_host(@p, "abc")
    end

    test "list_hosts pages by id and filters" do
      {:ok, _} = Customers.create_customer(%{slug: "kunde-a", name: "Kunde A"})
      a = host_fixture()
      b = host_fixture()
      {:ok, _} = Hosts.update_membership(b, %{customer: "kunde-a"})

      assert {:ok, [first], [key]} = MctlProvider.list_hosts(@p, page(nil, 1))
      assert first.id == to_string(a.id)
      assert key == a.id
      assert {:ok, [second], nil} = MctlProvider.list_hosts(@p, page([key], 1))
      assert second.id == to_string(b.id)

      assert {:ok, [only], nil} =
               MctlProvider.list_hosts(@p, page(nil, 10, %{"customer" => "kunde-a"}))

      assert only.id == to_string(b.id)

      assert {:ok, [_, _], nil} =
               MctlProvider.list_hosts(
                 @p,
                 page(nil, 10, %{"changed_after" => ~U[2000-01-01 00:00:00Z]})
               )
    end

    test "update_host sets name, customer and groups" do
      {:ok, _} = Customers.create_customer(%{slug: "kunde-a", name: "Kunde A"})
      {:ok, _} = Groups.create_group(%{slug: "web", name: "Web"})
      host = host_fixture()

      assert {:ok, h} =
               MctlProvider.update_host(@p, to_string(host.id), %{
                 "name" => "renamed",
                 "customer" => "kunde-a",
                 "groups" => ["web"]
               })

      assert {h.name, h.customer, h.groups} == {"renamed", "kunde-a", ["web"]}

      assert {:ok, %{customer: nil, groups: []}} =
               MctlProvider.update_host(@p, to_string(host.id), %{
                 "customer" => nil,
                 "groups" => []
               })

      assert [entry | _] = Ssm.Activity.list(activity_type: "host")
      assert entry.actor_username == "mctl:mission-control"
      assert Jason.decode!(entry.meta)["ip"] == "203.0.113.9"
    end

    test "update_host errors" do
      a = host_fixture(%{name: "taken"})
      b = host_fixture()
      assert {:error, :not_found} = MctlProvider.update_host(@p, "999999", %{"name" => "x"})

      assert {:error, {:conflict, _msg, %{"name" => ["already exists"]}}} =
               MctlProvider.update_host(@p, to_string(b.id), %{"name" => a.name})

      assert {:error, {:validation, %{"customer" => [_]}}} =
               MctlProvider.update_host(@p, to_string(b.id), %{"customer" => "ghost"})
    end
  end

  describe "create_host" do
    test "inserts the host, then probes and pins its key in a create_host job" do
      {:ok, _} = Groups.create_group(%{slug: "web", name: "Web"})
      MockClient.set_default_exec(%Ssm.Ssh.Result{})

      params =
        create_params(%{
          "groups" => ["web"],
          "attributes" => %{"username" => "deploy", "port" => 2200}
        })

      assert {:ok, job} = MctlProvider.create_host(@p, params)
      assert job.kind == "create_host"
      assert job.state in ~w(queued running succeeded)
      assert is_binary(job.host_id)

      host = Hosts.get_host_with_membership(String.to_integer(job.host_id))
      assert host.name == params["name"]
      assert host.username == "deploy"
      assert host.port == 2200
      assert Enum.map(host.groups, & &1.slug) == ["web"]

      # The key is not known to the mock until scripted: the job fails and
      # the half-created host is removed again.
      await_jobs()
      assert {:ok, failed} = MctlProvider.get_job(@p, job.id)
      assert failed.state == "failed"
      assert failed.error["code"] == "connect_failed"
      refute failed.error["message"] =~ "mock"
      assert Hosts.get_host(host.id) == nil
    end

    test "create is audited with the client IP; the job's pin carries the mctl actor" do
      MockClient.set_default_host_keys([@ed])
      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      await_jobs()

      entries = Ssm.Activity.list(activity_type: "host")
      create = Enum.find(entries, &(&1.action == "create"))
      pin = Enum.find(entries, &(&1.action == "pin_host_key"))
      assert Jason.decode!(create.meta)["ip"] == "203.0.113.9"
      assert pin.actor_username == "mctl:mission-control"
      assert Jason.decode!(pin.meta)["ip"] == "203.0.113.9"
      assert is_binary(job.host_id)
    end

    test "successful job pins the key (TOFU) and reports it" do
      params = create_params()
      # Host ids are allocated on insert; script every plausible id's key.
      MockClient.set_default_host_keys([@ed])

      assert {:ok, job} = MctlProvider.create_host(@p, params)
      await_jobs()

      assert {:ok, done} = MctlProvider.get_job(@p, job.id)
      assert done.state == "succeeded", inspect(done)

      assert done.result == %{
               "ssh_host_key" => @ed_fp,
               "pin" => "pinned",
               "ssm_public_key" => Ssm.Test.OwnKeyStub.default(),
               "username" => "root",
               "limited" => false
             }

      assert Hosts.get_host(String.to_integer(job.host_id)).key_fingerprint == @ed_fp
    end

    test "a pre-seeded fingerprint is verified, a different key fails the job" do
      MockClient.set_default_host_keys([@ed])

      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"key_fingerprint" => @ecdsa_fp}})
               )

      await_jobs()
      assert {:ok, failed} = MctlProvider.get_job(@p, job.id)
      assert failed.state == "failed"
      assert failed.error["code"] == "host_key_changed"
      assert failed.error["message"] =~ @ed_fp
      assert Hosts.get_host(String.to_integer(job.host_id)) == nil
    end

    test "after a failed job the same name and address can be posted again" do
      params = create_params()
      MockClient.set_default_host_keys([@ed])
      bad = put_in(params, ["attributes"], %{"key_fingerprint" => @ecdsa_fp})

      assert {:ok, _} = MctlProvider.create_host(@p, bad)
      await_jobs()
      assert Hosts.count_hosts() == 0

      assert {:ok, job} = MctlProvider.create_host(@p, params)
      await_jobs()
      assert {:ok, %{state: "succeeded"}} = MctlProvider.get_job(@p, job.id)
    end

    test "a successful job learns the machine_id HMAC over SSH" do
      MockClient.set_default_host_keys([@ed])
      MockClient.set_default_exec(%Ssm.Ssh.Result{stdout: "0123456789abcdef0123456789abcdef\n"})

      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      await_jobs()

      assert {:ok, %{identity: %{machine_id: @machine_id}}} =
               MctlProvider.get_host(@p, job.host_id)
    end

    test "a failed machine_id read does not fail the job" do
      MockClient.set_default_host_keys([@ed])
      MockClient.set_default_exec(%Ssm.Ssh.Result{exit_code: 1})

      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      await_jobs()

      assert {:ok, %{state: "succeeded"}} = MctlProvider.get_job(@p, job.id)
      assert {:ok, %{identity: %{machine_id: nil}}} = MctlProvider.get_host(@p, job.host_id)
    end

    test "a disabled host is created without SSH; the job succeeds unpinned" do
      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"disabled" => true}})
               )

      await_jobs()

      assert {:ok, %{state: "succeeded", result: %{"pin" => "skipped_disabled"}}} =
               MctlProvider.get_job(@p, job.id)

      assert MockClient.calls().probe == []
    end

    test "only mode pull (or none) is supported" do
      for mode <- ~w(push snmp) do
        assert {:error, {:validation, %{"mode" => ["not supported by ssm"]}}} =
                 MctlProvider.create_host(@p, create_params(%{"mode" => mode}))
      end

      assert {:ok, _} = MctlProvider.create_host(@p, create_params(%{"mode" => nil}))
      await_jobs()
    end

    test "validation: exactly one address, known customer/groups, valid attributes" do
      assert {:error, {:validation, %{"addresses" => _}}} =
               MctlProvider.create_host(@p, create_params(%{"addresses" => []}))

      assert {:error, {:validation, %{"addresses" => _}}} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"addresses" => ["1.1.1.1", "2.2.2.2"]})
               )

      assert {:error, {:validation, %{"customer" => _}}} =
               MctlProvider.create_host(@p, create_params(%{"customer" => "ghost"}))

      assert {:error, {:validation, %{"attributes.port" => _}}} =
               MctlProvider.create_host(@p, create_params(%{"attributes" => %{"port" => "x"}}))

      assert {:error, {:validation, %{"attributes.key_fingerprint" => _}}} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"key_fingerprint" => "MD5:aa"}})
               )

      assert Hosts.count_hosts() == 0
    end

    test "username follows the SSH field rules (default root)" do
      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      assert Hosts.get_host(String.to_integer(job.host_id)).username == "root"
      await_jobs()

      for bad <- ["-oProxyCommand=x", "a b", "user@host", ""] do
        assert {:error, {:validation, %{"attributes.username" => _}}} =
                 MctlProvider.create_host(
                   @p,
                   create_params(%{"attributes" => %{"username" => bad}})
                 )
      end
    end

    test "jump_via names an existing ssm host by id or by name" do
      bastion = host_fixture(%{name: "bastion"})

      for ref <- [to_string(bastion.id), bastion.id, "bastion"] do
        assert {:ok, job} =
                 MctlProvider.create_host(
                   @p,
                   create_params(%{"attributes" => %{"jump_via" => ref}})
                 )

        assert Hosts.get_host(String.to_integer(job.host_id)).jump_via == bastion.id
        await_jobs()
      end

      for ghost <- ["ghost", "999999", 999_999, "", true] do
        assert {:error, {:validation, %{"attributes.jump_via" => _}}} =
                 MctlProvider.create_host(
                   @p,
                   create_params(%{"attributes" => %{"jump_via" => ghost}})
                 )
      end
    end

    test "a duplicate name or address is a conflict naming the field" do
      host = host_fixture(%{name: "dup"})

      assert {:error, {:conflict, _msg, %{"name" => ["already exists"]}}} =
               MctlProvider.create_host(@p, create_params(%{"name" => "dup"}))

      assert {:error, {:conflict, _msg, %{"address" => ["already exists"]}}} =
               MctlProvider.create_host(@p, create_params(%{"addresses" => [host.address]}))
    end
  end

  describe "create_host waits for ssm's key on the host" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ssm, :test_own_public_key)
        Application.put_env(:ssm, :mctl_login_wait, @wait)
      end)
    end

    defp wait_for_job(job_id, fun, tries \\ 200) do
      {:ok, job} = MctlProvider.get_job(@p, job_id)

      cond do
        fun.(job) -> job
        tries == 0 -> flunk("job never matched: #{inspect(job)}")
        true -> Process.sleep(5) && wait_for_job(job_id, fun, tries - 1)
      end
    end

    test "ssm_public_key is in the result while the job runs; the job succeeds once the key works" do
      Application.put_env(:ssm, :mctl_login_wait,
        timeout_ms: 10_000,
        first_delay_ms: 5,
        max_delay_ms: 5
      )

      MockClient.set_default_host_keys([@ed])
      MockClient.fail_probe_auth(1_000_000)

      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"key_fingerprint" => @ed_fp}})
               )

      running =
        wait_for_job(job.id, &(&1.state == "running" and &1.progress =~ "attempt"))

      assert running.result == %{
               "ssm_public_key" => Ssm.Test.OwnKeyStub.default(),
               "username" => "root",
               "limited" => false
             }

      assert running.progress =~ "root"

      # mctl authorizes the key through the dashboard; the next login works.
      MockClient.fail_probe_auth(0)
      await_jobs()

      assert {:ok, done} = MctlProvider.get_job(@p, job.id)
      assert done.state == "succeeded"
      assert done.result["ssm_public_key"] == Ssm.Test.OwnKeyStub.default()
      assert done.result["pin"] == "verified"
      assert done.result["ssh_host_key"] == @ed_fp
    end

    test "retries the login with backoff until it succeeds" do
      MockClient.set_default_host_keys([@ed])
      MockClient.fail_probe_auth(3)

      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      await_jobs()

      assert {:ok, %{state: "succeeded"}} = MctlProvider.get_job(@p, job.id)
      assert length(MockClient.calls().probe) == 4
    end

    test "gives up after the wait with auth_failed; the host is removed, the key stays readable" do
      MockClient.set_default_host_keys([@ed])
      MockClient.fail_probe_auth(1_000_000)

      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"username" => "deploy"}})
               )

      await_jobs()

      assert {:ok, failed} = MctlProvider.get_job(@p, job.id)
      assert failed.state == "failed"
      assert failed.error["code"] == "auth_failed"
      assert failed.error["message"] =~ "deploy"
      assert failed.error["message"] =~ "ssm_public_key"
      refute failed.error["message"] =~ "mock"
      assert failed.result["ssm_public_key"] == Ssm.Test.OwnKeyStub.default()
      assert length(MockClient.calls().probe) > 1
      assert Hosts.get_host(String.to_integer(job.host_id)) == nil
    end

    test "a different host key fails at once with host_key_changed, without retrying" do
      MockClient.set_default_host_keys([@ed])
      MockClient.fail_probe_auth(1_000_000)

      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"key_fingerprint" => @ecdsa_fp}})
               )

      await_jobs()

      assert {:ok, %{state: "failed", error: %{"code" => "host_key_changed"}}} =
               MctlProvider.get_job(@p, job.id)

      assert length(MockClient.calls().probe) == 1
    end

    test "other connect errors are not retried" do
      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      await_jobs()

      assert {:ok, %{state: "failed", error: %{"code" => "connect_failed"}}} =
               MctlProvider.get_job(@p, job.id)

      assert length(MockClient.calls().probe) == 1
    end

    test "without a usable SSH_KEY the job fails with ssm_key_unavailable before any SSH" do
      Application.put_env(:ssm, :test_own_public_key, :unavailable)
      MockClient.set_default_host_keys([@ed])

      assert {:ok, job} = MctlProvider.create_host(@p, create_params())
      await_jobs()

      assert {:ok, %{state: "failed", error: %{"code" => "ssm_key_unavailable"}}} =
               MctlProvider.get_job(@p, job.id)

      assert MockClient.calls().probe == []
      assert Hosts.count_hosts() == 0
    end

    test "a host behind a jump host is probed through it" do
      MockClient.set_default_host_keys([@ed])
      bastion = host_fixture(%{name: "bastion"})

      assert {:ok, job} =
               MctlProvider.create_host(
                 @p,
                 create_params(%{"attributes" => %{"jump_via" => "bastion"}})
               )

      await_jobs()
      assert {:ok, %{state: "succeeded"}} = MctlProvider.get_job(@p, job.id)
      host = Hosts.get_host(String.to_integer(job.host_id))
      assert Hosts.target_for(host).jump_target.host_id == bastion.id
    end
  end

  describe "customers and groups" do
    test "create, conflict, list, rename" do
      assert {:ok, %{slug: "kunde-a", name: "A"}} =
               MctlProvider.create_customer(@p, %{"slug" => "kunde-a", "name" => "A"})

      assert {:error, :conflict} =
               MctlProvider.create_customer(@p, %{"slug" => "kunde-a", "name" => "B"})

      assert {:ok, [%{slug: "kunde-a"}], nil} = MctlProvider.list_customers(@p, page())

      assert {:ok, %{slug: "kunde-a", name: "A2"}} =
               MctlProvider.update_customer(@p, "kunde-a", %{"name" => "A2"})

      assert {:error, :not_found} = MctlProvider.update_customer(@p, "ghost", %{"name" => "x"})

      assert {:ok, %{slug: "web"}} =
               MctlProvider.create_group(@p, %{"slug" => "web", "name" => "Web"})

      assert {:error, :conflict} =
               MctlProvider.create_group(@p, %{"slug" => "web", "name" => "Web"})

      assert {:ok, [%{slug: "web"}], nil} = MctlProvider.list_groups(@p, page())
    end

    test "list pages by slug" do
      for s <- ~w(b a c),
          do: {:ok, _} = MctlProvider.create_group(@p, %{"slug" => s, "name" => s})

      assert {:ok, [%{slug: "a"}, %{slug: "b"}], ["b"]} =
               MctlProvider.list_groups(@p, page(nil, 2))

      assert {:ok, [%{slug: "c"}], nil} = MctlProvider.list_groups(@p, page(["b"], 2))
    end
  end

  describe "jobs" do
    test "list_jobs filters by host_id; unknown job is not_found" do
      {:ok, job} =
        MctlProvider.create_host(@p, create_params(%{"attributes" => %{"disabled" => true}}))

      await_jobs()

      assert {:ok, [listed], nil} =
               MctlProvider.list_jobs(@p, page(nil, 10, %{"host_id" => job.host_id}))

      assert listed.id == job.id
      assert {:ok, [], nil} = MctlProvider.list_jobs(@p, page(nil, 10, %{"host_id" => "0"}))
      assert {:error, :not_found} = MctlProvider.get_job(@p, "999999")
    end
  end

  test "cursor_types" do
    assert MctlProvider.cursor_types("hosts") == [:integer]
    assert MctlProvider.cursor_types("jobs") == [:integer]
    assert MctlProvider.cursor_types("customers") == [:string]
    assert MctlProvider.cursor_types("groups") == [:string]
  end
end
