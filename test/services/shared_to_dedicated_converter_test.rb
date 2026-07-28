require "test_helper"

class SharedToDedicatedConverterTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "conv@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git",
                             database_mode: "shared", database_placement: "colocated")
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://shared/appone")
    @cred = @org.credentials.create!(name: "r2", provider: "aws", api_key: "k", api_secret: "s", account_id: "a1")
  end

  FakeCluster = Struct.new(:container_name)
  FakeDB = Struct.new(:database_url, :database_cluster)

  def fake_provisioner(url: "postgres://appone-db:5432/appone_production", container: "appone-db")
    prov = Object.new
    prov.define_singleton_method(:provision!) { FakeDB.new(url, FakeCluster.new(container)) }
    ->(_app) { prov }
  end

  def recording_replicator(into:)
    ->(**kw) do
      into << kw
      rep = Object.new
      rep.define_singleton_method(:run!) { true }
      rep
    end
  end

  test "converts: provisions dedicated, copies data, drops the manual DATABASE_URL env" do
    calls = []
    res = SharedToDedicatedConverter.new(@app, provisioner_for: fake_provisioner, replicator_for: recording_replicator(into: calls))
      .call(credential: @cred, bucket: "appone-db-transfer")

    assert res.ok?, res.message
    assert_equal "dedicated", @app.reload.database_mode
    assert_nil @app.env_variables.find_by(key: "DATABASE_URL"), "manual DATABASE_URL removed so the derived dedicated DSN takes over"
    assert_equal "postgres://shared/appone", calls.first[:source_url]
    assert_equal "postgres://appone-db:5432/appone_production", calls.first[:target_url]
    assert_equal @cred, calls.first[:credential]
  end

  test "rejects an already-dedicated app" do
    @app.update!(database_mode: "dedicated")
    res = SharedToDedicatedConverter.new(@app).call(credential: @cred, bucket: "b")

    refute res.ok?
    assert_match(/already dedicated/, res.message)
  end

  test "rolls back the mode flip when the copy fails, leaving the shared DB intact" do
    boom = ->(**_kw) do
      rep = Object.new
      rep.define_singleton_method(:run!) { raise DatabaseReplicator::Error, "dump failed" }
      rep
    end
    res = SharedToDedicatedConverter.new(@app, provisioner_for: fake_provisioner, replicator_for: boom)
      .call(credential: @cred, bucket: "b")

    refute res.ok?
    assert_match(/rolled back to shared/, res.message)
    assert_equal "shared", @app.reload.database_mode
    assert @app.env_variables.find_by(key: "DATABASE_URL"), "shared DATABASE_URL is untouched on failure"
  end
end
