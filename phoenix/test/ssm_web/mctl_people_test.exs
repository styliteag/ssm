defmodule SsmWeb.MctlPeopleTest do
  # contract section 10: delete_host and people (offboarding)
  use Ssm.DataCase, async: false

  import Ecto.Query
  import Ssm.Fixtures

  alias MctlContract.Principal
  alias Ssm.Accounts.Operator
  alias Ssm.Authorizations.Authorization
  alias Ssm.Hosts
  alias Ssm.Ssh.{MockClient, Result}
  alias Ssm.Users.UserKey
  alias SsmWeb.MctlProvider

  @iss "https://login.example.com/realms/ops"
  @email "ada@example.com"
  @key "oidc:#{@iss}|sub-ada"

  @p %Principal{
    id: 1,
    name: "mission-control",
    prefix: "ssm_abc",
    scopes: ~w(read commands setup),
    ip: "203.0.113.9"
  }

  setup do
    start_supervised!(MockClient)
    MockClient.set_default_exec(%Result{exit_code: 0})

    operator =
      Repo.insert!(%Operator{
        oidc_issuer: @iss,
        oidc_subject: "sub-ada",
        name: "Ada",
        email: @email,
        email_verified: true,
        verified_email: @email,
        role: "operator"
      })

    own = user_fixture(%{username: @email})
    own_key = key_fixture(own, %{key_base64: "AAAAADAOWN", name: "ada@laptop"})
    shared_user = user_fixture(%{username: "ops"})
    shared_key = key_fixture(shared_user, %{key_base64: "AAAAADASHARED", name: "ADA@example.com"})
    other_key = key_fixture(shared_user, %{key_base64: "AAAAOTHER", name: "bob"})

    web = host_fixture(%{name: "web"})
    db = host_fixture(%{name: "db"})
    authorization_fixture(own, web, %{login: "deploy"})
    authorization_fixture(shared_user, db, %{login: "root"})

    %{
      operator: operator,
      own: own,
      own_key: own_key,
      shared_key: shared_key,
      other_key: other_key,
      web: web,
      db: db
    }
  end

  defp await_jobs do
    for pid <- Task.Supervisor.children(Ssm.Mctl.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    :ok
  end

  defp finished(job) do
    await_jobs()
    {:ok, done} = MctlProvider.get_job(@p, job.id)
    done
  end

  describe "get_person/2" do
    test "operator, own and shared keys by e-mail, fingerprints only", ctx do
      assert {:ok, person} = MctlProvider.get_person(@p, @key)
      assert person.key == @key
      assert person.operator["email"] == @email
      assert person.operator["disabled"] == false

      assert [own, shared] = person.keys
      assert own.fingerprint =~ ~r/^SHA256:/
      assert own.comment == "ada@laptop"
      assert own.hosts == [ctx.web.id]
      assert shared.comment == "ADA@example.com"
      assert shared.hosts == [ctx.db.id]

      assert person.emails == [@email]
      assert own.matched_by == "ssh user #{@email} (verified e-mail of the operator)"
      assert shared.matched_by == "key comment ADA@example.com (verified e-mail of the operator)"

      assert person.authorizations == [
               %{
                 host_id: ctx.web.id,
                 remote_user: "deploy",
                 matched_by: "ssh user #{@email} (verified e-mail of the operator)"
               }
             ]

      refute inspect(person) =~ "AAAAADA"
    end

    test "an unverified or changed e-mail claim never matches users or keys", ctx do
      # the IdP claim says Ada, but it was never verified for this operator
      Repo.insert!(%Operator{
        oidc_issuer: @iss,
        oidc_subject: "sub-mallory",
        name: "Mallory",
        email: @email,
        email_verified: false,
        role: "operator"
      })

      assert {:ok, person} = MctlProvider.get_person(@p, "oidc:#{@iss}|sub-mallory")
      assert person.operator["name"] == "Mallory"
      assert person.emails == []
      assert person.keys == [] and person.authorizations == []
      _ = ctx
    end

    test "an email: key that is the verified e-mail of several operators is a conflict" do
      Repo.insert!(%Operator{
        oidc_issuer: "https://other-idp.example.com",
        oidc_subject: "sub-ada-2",
        name: "Ada 2",
        email: @email,
        email_verified: true,
        verified_email: @email,
        role: "viewer"
      })

      assert {:error, {:conflict, msg}} = MctlProvider.get_person(@p, "email:#{@email}")
      assert msg =~ "oidc:"
      assert {:error, {:conflict, _}} = MctlProvider.remove_person(@p, "email:#{@email}", %{})
    end

    test "an email: key finds the same records, case-insensitively" do
      assert {:ok, person} = MctlProvider.get_person(@p, "email:Ada@Example.com")
      assert length(person.keys) == 2
      assert person.operator["name"] == "Ada"
    end

    test "unknown person is not_found" do
      assert {:error, :not_found} = MctlProvider.get_person(@p, "email:nobody@example.com")
      assert {:error, :not_found} = MctlProvider.get_person(@p, "oidc:#{@iss}|other")
    end
  end

  describe "remove_person/3" do
    test "database only: deletes records, marks hosts, disables the operator, writes nothing",
         ctx do
      assert {:ok, job} = MctlProvider.remove_person(@p, @key, %{})
      assert job.kind == "remove_person"
      done = finished(job)
      assert done.state == "succeeded"

      assert done.result["hosts"] == []
      assert done.result["pending_keys"] == []
      assert done.result["kept_shared_keys"] == []
      assert to_string(ctx.web.id) in done.result["revocation_pending"]

      # only a user's Sync in ssm writes to a host
      assert MockClient.calls().exec == []
      assert Ssm.Diffs.Revocations.pending?(ctx.web.id)
      assert Ssm.Diffs.Revocations.pending?(ctx.db.id)

      assert Repo.all(from a in Authorization, where: a.user_id == ^ctx.own.id) == []
      assert Repo.get(UserKey, ctx.shared_key.id) == nil
      assert Repo.get(UserKey, ctx.other_key.id)
      assert Repo.get(Operator, ctx.operator.id).disabled_at
    end

    test "with hosts: only those hosts, shared keys stay in the database", ctx do
      {:ok, job} = MctlProvider.remove_person(@p, @key, %{"hosts" => [to_string(ctx.web.id)]})
      done = finished(job)

      assert done.result["hosts"] == []
      assert done.result["revocation_pending"] == [to_string(ctx.web.id)]
      assert MockClient.calls().exec == []
      assert Repo.get(UserKey, ctx.shared_key.id)
      assert done.result["kept_shared_keys"] == [Ssm.People.fingerprint("AAAAADASHARED")]
    end

    test "bad host ids are a validation error, an unknown person not_found" do
      assert {:error, {:validation, %{"hosts" => _}}} =
               MctlProvider.remove_person(@p, @key, %{"hosts" => ["x"]})

      assert {:error, :not_found} =
               MctlProvider.remove_person(@p, "email:nobody@example.com", %{})
    end
  end

  describe "delete_host/2" do
    test "deletes the host and its authorizations; job succeeded", ctx do
      assert {:ok, job} = MctlProvider.delete_host(@p, to_string(ctx.web.id))
      assert job.kind == "delete_host"
      assert job.state == "succeeded"
      assert job.result == %{"deleted" => true}
      assert Hosts.get_host(ctx.web.id) == nil
      assert Repo.all(from a in Authorization, where: a.host_id == ^ctx.web.id) == []
    end

    test "a jump host in use is a conflict; unknown is not_found", ctx do
      host_fixture(%{name: "behind", jump_via: ctx.db.id})

      assert {:error, {:conflict, "jump host of behind"}} =
               MctlProvider.delete_host(@p, to_string(ctx.db.id))

      assert Hosts.get_host(ctx.db.id)
      assert {:error, :not_found} = MctlProvider.delete_host(@p, "999999")
    end
  end
end
