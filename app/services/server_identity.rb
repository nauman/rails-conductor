require "shellwords"

# Conductor's OWN key on the box, installed by Conductor.
#
# Until now it generated a keypair and — per its own tool description — handed the
# operator the public half "to add to your servers' authorized_keys". So the
# automated identity was never installed by the automation. It was a manual errand
# documented as a feature, and it is why a cross-box deploy failed until a human
# edited a file.
#
# The deeper version of the same mistake is in provisioning, which copies ROOT's
# authorized_keys onto the deploy user. That is a migration step — "let deploy work
# the way root did" — wearing the clothes of an identity step. On the box you
# registered from they are indistinguishable, because the operator's key is the key
# in both. They diverge on every other box, which is exactly where this broke.
#
# Registration is the right moment: it is the one time Conductor legitimately holds
# root (see docs/learnings/root-is-a-registration-only-credential.md). Everything
# after that is repair, and repair runs as the ordinary SSH user.
class ServerIdentity
  Result = Struct.new(:ok, :action, :reason, keyword_init: true) do
    def ok? = ok
  end

  # Proof-of-life for a connection made WITH the key we just authorized.
  PROBE = "echo CONDUCTOR_IDENTITY_OK".freeze

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
  end

  def ensure!
    key = @server.ssh_key
    # The OPENSSH LINE, not the PEM in `public_key`. sshd reads one line of
    # `<type> <blob> [comment]` and silently ignores anything else, so installing
    # the PEM would authorize nothing and say nothing.
    public_key = key&.authorized_keys_line(comment: "conductor@#{@server.name}").to_s.strip
    if public_key.blank?
      return Result.new(ok: false, reason: "no ssh key is stored for #{@server.name}, so there is " \
                                           "no identity to install")
    end

    return verify("already-authorized") if authorized?(public_key)

    append!(public_key)
    verify("installed")
  end

  private

  # `grep -qF` — FIXED string, not a pattern. A public key contains `+` and `/`,
  # which a regex would read as operators.
  def authorized?(public_key)
    @ssh.execute_with_status(
      "grep -qF #{Shellwords.escape(public_key)} ~/.ssh/authorized_keys 2>/dev/null"
    )[:success]
  end

  # Idempotent by construction: the grep runs again inside the shell, so a race
  # between check and append cannot duplicate the line. Permissions are set every
  # time because sshd silently ignores an authorized_keys file it considers too
  # open — a failure mode with no error message anywhere.
  def append!(public_key)
    escaped = Shellwords.escape(public_key)
    @ssh.execute_with_status(
      "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && " \
      "chmod 600 ~/.ssh/authorized_keys && " \
      "grep -qF #{escaped} ~/.ssh/authorized_keys || echo #{escaped} >> ~/.ssh/authorized_keys"
    )
  end

  # VERIFY BY USING IT. A write that returned zero proves the file was edited, not
  # that the key authenticates — and a recorded authorization nobody tested is the
  # stale-fact pattern this fleet keeps paying for (ADR 0010). sshd may reject the
  # file's permissions, the key may be the wrong type for the host's config, or the
  # append may have gone to a different user's home than the one we log in as.
  def verify(action)
    result = @ssh.execute_with_status(PROBE)
    return Result.new(ok: true, action: action) if result[:success] && result[:stdout].to_s.include?("CONDUCTOR_IDENTITY_OK")

    Result.new(ok: false, action: action,
               reason: "wrote the key to #{@server.name} but could not authenticate with it afterwards" \
                       "#{" (#{@ssh.error})" if @ssh.error.present?}")
  end
end
