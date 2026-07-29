require "test_helper"

# App-transfer spec 26: DatabaseReplicator copies a Postgres DB source→target via
# R2 (dump→upload on source, download→restore on target).
class DatabaseReplicatorTest < ActiveSupport::TestCase
  # Records every command; returns success (or a scripted failure).
  class FakeSsh
    attr_reader :commands
    def initialize(fail_on: nil) = (@commands = []; @fail_on = fail_on)
    def execute_with_status(cmd)
      @commands << cmd
      { success: @fail_on.nil? || !cmd.include?(@fail_on), stderr: "err" }
    end
    def error = nil
  end

  Cred = Struct.new(:api_key, :api_secret, :account_id, :region, keyword_init: true)

  def cred = Cred.new(api_key: "AK", api_secret: "SK", account_id: "acc123", region: "auto")

  def replicate(source_ssh:, target_ssh:, **over)
    DatabaseReplicator.new(
      source_server: :src, source_url: "postgres://u:p@old-db:5432/app",
      target_server: :dst, target_url: "postgres://u:p@app-db:5432/app",
      credential: cred, bucket: "conductor-transfers", object_key: "transfers/app/1.sql.gz",
      source_ssh: source_ssh, target_ssh: target_ssh, **over
    ).run!
  end

  test "dumps+uploads on the source, downloads+restores on the target (R2)" do
    src = FakeSsh.new
    dst = FakeSsh.new
    assert replicate(source_ssh: src, target_ssh: dst)

    # Source: pg_dump | gzip, then aws s3 cp up to R2 with the account endpoint.
    assert(src.commands.any? { |c| c.match?(/pg_dump .*old-db.* \| gzip/) })
    upload = src.commands.find { |c| c.include?("aws s3 cp") }
    assert_includes upload, "s3://conductor-transfers/transfers/app/1.sql.gz"
    assert_includes upload, "--endpoint-url https://acc123.r2.cloudflarestorage.com"
    assert_includes upload, "AWS_ACCESS_KEY_ID=AK"

    # Target: aws s3 cp down, then gunzip | psql into the target DB.
    download = dst.commands.find { |c| c.include?("aws s3 cp s3://") }
    assert_includes download, "conductor-transfers/transfers/app/1.sql.gz"
    assert(dst.commands.any? { |c| c.match?(/gunzip -c .* \| psql .*app-db/) })
  end

  # A colocated dedicated DB resolves only by container DNS on the app's Docker
  # network, so the pg client must run there — not on the host, which fails with
  # "could not translate host name". aws/gzip stay on the host.
  test "runs the pg client inside the Docker network when one is given" do
    src = FakeSsh.new
    dst = FakeSsh.new
    assert replicate(source_ssh: src, target_ssh: dst, network: "kamal")

    dump = src.commands.find { |c| c.include?("pg_dump") }
    assert_match(%r{docker run --rm --network kamal postgres:16-alpine pg_dump .*old-db}, dump)
    assert_includes dump, "| gzip", "gzip still runs on the host"

    restore = dst.commands.find { |c| c.include?("psql") }
    assert_match(%r{gunzip -c .* \| docker run --rm -i --network kamal postgres:16-alpine psql .*app-db}, restore)

    # The R2 transfer stays on the host — only the DB dialogue moves to the network.
    assert(src.commands.any? { |c| c.include?("aws s3 cp") && !c.include?("docker run") })
  end

  test "raises with the failing step when a command fails" do
    src = FakeSsh.new(fail_on: "aws s3 cp") # upload fails
    err = assert_raises(DatabaseReplicator::Error) { replicate(source_ssh: src, target_ssh: FakeSsh.new) }
    assert_match(/upload/, err.message)
  end

  test "validates inputs before touching a server" do
    src = FakeSsh.new
    err = assert_raises(DatabaseReplicator::Error) do
      DatabaseReplicator.new(source_server: :s, source_url: "x", target_server: :t, target_url: "y",
                             credential: cred, bucket: "", object_key: "k", source_ssh: src, target_ssh: FakeSsh.new).run!
    end
    assert_match(/bucket/, err.message)
    assert_empty src.commands
  end
end
