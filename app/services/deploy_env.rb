require "shellwords"

# How an app's environment reaches its container — in ONE place.
#
# There were two. AppDeployer and DockerRollback each carried their own
# `deploy_env_flags`, and they had already drifted: the deploy path redacted secrets
# from its logs, the rollback path did not redact at all. Duplicated logic does not
# stay in step, it fails in whichever copy nobody is reading.
#
# WHAT THIS BUYS, precisely: a value marked sensitive is not an argv element, so it
# is not readable in the host process table for the life of the command, nor by
# anything that records commands.
#
# WHAT IT DOES NOT BUY, stated so the flag cannot over-promise: the value is still
# in the container's environment and still visible to `docker inspect`. That is
# inherent to environment variables — anyone who can reach the Docker daemon is
# already root-equivalent on that box. Protection from THAT needs mounted secret
# files or a runtime secret manager, not an env var.
class DeployEnv
  # Raised when a value cannot be carried safely. Refusing is deliberate: the
  # alternatives are silently truncating a credential or silently putting it back on
  # the command line, and both fail far from here.
  class Unsupported < StandardError; end

  # Conductor sets these itself at the call site; carrying them here would let an
  # app's stored value quietly override the deploy's own decision.
  RESERVED = %w[PORT RAILS_ENV RAILS_LOG_TO_STDOUT].freeze

  def initialize(app, server: nil, deployment_id: nil)
    @app = app
    @server = server || app.server
    @deployment_id = deployment_id
  end

  # Ordinary values as `-e`, sensitive ones behind `--env-file`. Ordinary values stay
  # legible on purpose: hiding them only makes a deploy log less useful.
  def flags(redacted: false)
    parts = ordinary_pairs.map { |key, value| "-e #{key}=#{Shellwords.escape(value.to_s)}" }
    return parts.join(" ") unless file_needed?

    sensitive_pairs.each { |key, value| assert_carriable!(key, value) }
    parts << (redacted ? "--env-file #{file_path} [#{sensitive_pairs.size} sensitive]"
                       : "--env-file #{Shellwords.escape(file_path)}")
    parts.join(" ")
  end

  def file_needed? = sensitive_pairs.any?

  # A PRIVATE DIRECTORY, not shared /tmp. scp's receiver opens an existing
  # destination without O_EXCL or O_NOFOLLOW, so an attacker-planted symlink or a
  # pre-created file keeps its own permissions and `mode: 0600` guarantees nothing.
  # Creating the directory 0700 first means the path we write cannot already exist
  # as someone else's file.
  #
  # PER DEPLOY, so two deploys of the same app cannot overwrite each other's file
  # mid-flight — a build takes minutes and overlapping deploys are ordinary.
  def file_dir = "/tmp/conductor-env-#{@app.resource_key}-#{@deployment_id}"
  def file_path = "#{file_dir}/env"

  # UPLOADED AS CONTENT, never echoed into a command. Writing it with a heredoc
  # leaves the value in the SSH command string — the exposure this exists to remove,
  # wearing a different shape. That mistake has been made twice; scp moves bytes over
  # the encrypted channel and they never appear as an argument anywhere. scp also
  # applies the mode at creation, so the file is never briefly world-readable, and it
  # follows no symlink a predictable path might have had planted at it.
  def upload!(ssh)
    return true unless file_needed?

    sensitive_pairs.each { |key, value| assert_carriable!(key, value) }

    # `mkdir` without -p FAILS if the path exists — including as a symlink someone
    # planted. That refusal is the point: -p would happily accept whatever is there.
    prepared = ssh.execute_with_status(
      "rm -rf #{Shellwords.escape(file_dir)} && mkdir -m 700 #{Shellwords.escape(file_dir)}"
    )
    return false unless prepared[:success]

    body = sensitive_pairs.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n"
    ssh.upload_content(body, file_path, mode: 0o600)
  end

  # Best effort, and safe to call twice: once the container exists the values live in
  # its environment, so a leftover file is a tidiness problem rather than a reason to
  # fail a deploy that otherwise worked. It must still run on the failure path — a
  # 0600 file of live credentials outliving the thing that needed it is the worse
  # outcome.
  # Returns whether the removal actually succeeded, so a caller can say so. An
  # earlier version returned true unconditionally, which made a failed cleanup
  # indistinguishable from a clean one — the file staying behind is the whole risk.
  def remove!(ssh)
    return true unless file_needed?

    ssh.execute_with_status("rm -rf #{Shellwords.escape(file_dir)}")[:success]
  end

  def sensitive_pairs
    @sensitive_pairs ||= pairs.select { |key, _| secret_keys.include?(key) }
  end

  def ordinary_pairs
    @ordinary_pairs ||= pairs.reject { |key, _| secret_keys.include?(key) }
  end

  private

  def pairs = @pairs ||= @app.deploy_env_pairs(server: @server).reject { |key, _| RESERVED.include?(key) }

  def secret_keys = @secret_keys ||= @app.deploy_secret_keys(server: @server)

  # A NEWLINE. `docker run --env-file` reads one KEY=VALUE per line and has no
  # continuation syntax, so a multiline value arrives truncated to its first line —
  # verified against real Docker, not inferred. A private key or a service-account
  # JSON is exactly the kind of thing marked sensitive, and handing an app the first
  # line of one produces a failure far from the deploy that caused it.
  #
  # The message names the key and never the value.
  def assert_carriable!(key, value)
    return unless value.to_s.include?("\n")

    raise Unsupported,
          "#{key} is marked sensitive and contains a newline. `docker run --env-file` cannot " \
          "carry multiline values — it would silently deliver only the first line. Store it " \
          "single-line (base64 it and decode in the app), or deploy this app with Kamal."
  end
end
