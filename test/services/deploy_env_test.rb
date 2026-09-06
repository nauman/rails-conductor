require "test_helper"

# One place that knows how an app's env reaches a container. There were two —
# AppDeployer and DockerRollback each had their own deploy_env_flags — and they had
# already drifted: the deploy path redacted secrets from its logs, the rollback path
# did not redact at all. Duplicated logic does not stay in step; it just fails in
# whichever copy nobody is looking at.
class DeployEnvTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "de@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.90")
    @subject = @org.apps.create!(name: "appone", slug: "appone", server: @server, deploy_method: "docker",
                                 port: 3000, repository_url: "https://github.com/x/y.git")
    @subject.env_variables.create!(key: "API_TOKEN", value: "s3cr3t-value", secret: true)
    @subject.env_variables.create!(key: "PUBLIC_URL", value: "https://example.com", secret: false)
    @env = DeployEnv.new(@subject, server: @server, deployment_id: 42)
  end

  # A sensitive value in argv is readable in the host process table for the life of
  # the command, and by anything that records commands.
  test "a sensitive value is never an argv element" do
    assert_no_match(/s3cr3t-value/, @env.flags)
    assert_match(/--env-file/, @env.flags)
  end

  # Ordinary values stay legible: hiding them only makes a deploy log less useful.
  test "non-sensitive values stay on the command line" do
    assert_match(/-e PUBLIC_URL=/, @env.flags)
  end

  test "an app with no sensitive values needs no file" do
    @subject.env_variables.where(secret: true).destroy_all

    env = DeployEnv.new(@subject.reload, server: @server, deployment_id: 42)

    assert_no_match(/--env-file/, env.flags)
    assert_not env.file_needed?
  end

  # `docker run --env-file` reads one KEY=VALUE per line with no continuation, so a
  # multiline value arrives TRUNCATED TO ITS FIRST LINE — verified against real
  # Docker. A private key or service-account JSON is exactly what gets marked
  # sensitive, and delivering the first line of one fails later, far from here.
  test "a multiline sensitive value is refused rather than silently truncated" do
    @subject.env_variables.create!(key: "PRIVATE_KEY", value: "-----BEGIN-----\nabc\n-----END-----", secret: true)
    env = DeployEnv.new(@subject.reload, server: @server, deployment_id: 42)

    error = assert_raises(DeployEnv::Unsupported) { env.flags }

    assert_match(/PRIVATE_KEY/, error.message)
    assert_no_match(/BEGIN/, error.message, "the message must not quote the value")
  end

  # The file travels as CONTENT over scp, never as part of a command. Writing it with
  # a heredoc would leave the value in the SSH command string — which is the exposure
  # this exists to remove, wearing a different shape. That mistake was made twice.
  test "the file is uploaded, not echoed into a shell command" do
    ssh = FakeSsh.new
    @env.upload!(ssh)

    assert_equal 1, ssh.uploads.size
    content, path, mode = ssh.uploads.first
    assert_match(/API_TOKEN=s3cr3t-value/, content)
    assert_equal 0o600, mode
    assert_includes path, "42", "the path is per-deploy, so two deploys cannot collide"
    assert_empty ssh.commands.grep(/s3cr3t-value/), "no command may carry the value"
  end

  test "removal is by path and tolerates a file that is already gone" do
    ssh = FakeSsh.new
    @env.remove!(ssh)

    assert ssh.commands.any? { |c| c.include?("rm -f") }
  end

  class FakeSsh
    attr_reader :uploads, :commands
    def initialize = (@uploads = []; @commands = [])
    def upload_content(content, path, mode: nil) = (@uploads << [ content, path, mode ]; true)
    def execute_with_status(cmd) = (@commands << cmd; { success: true, stdout: "", stderr: "" })
    def error = nil
  end
end
