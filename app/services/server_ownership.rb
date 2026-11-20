require "securerandom"
require "shellwords"

# Proof of control (plan 02 § 5.4). A server registered by an org the operator
# did not vet is `verified` only after Conductor connects with the org's own key
# and finds THIS registration's nonce in the login user's authorized_keys — the
# nonce rides in the key line's comment, so installing the one line we show is
# the whole proof. Until then SshConnection refuses every other connection.
class ServerOwnership
  Result = Struct.new(:ok, :detail, keyword_init: true) do
    def ok? = ok
  end

  NONCE_PREFIX = "conductor-verify-".freeze

  def self.issue_nonce!(server)
    server.update!(ownership_nonce: SecureRandom.hex(16), ownership_verified_at: nil)
    server.ownership_nonce
  end

  # The line the tenant appends to ~/.ssh/authorized_keys of the login user.
  def self.authorized_keys_line(server)
    server.ssh_key&.authorized_keys_line(comment: "#{NONCE_PREFIX}#{server.ownership_nonce}")
  end

  # Prints the nonce iff a line carrying it is in the login user's
  # authorized_keys. -F: the nonce is matched literally, never as a pattern.
  # Missing file, empty file and no match all print nothing and exit non-zero.
  def self.probe_command(nonce)
    marker = Shellwords.escape("#{NONCE_PREFIX}#{nonce}")
    %(grep -qF -- #{marker} "$HOME/.ssh/authorized_keys" && printf '%s\\n' #{marker})
  end

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server, ownership_probe: true)
  end

  def verify!
    nonce = @server.ownership_nonce
    return fail("no verification nonce issued — start the verification step again") if nonce.blank?

    output = @ssh.with_only_stored_key { |s| s.execute(self.class.probe_command(nonce)) }
    if output.to_s.lines.map(&:strip).include?("#{NONCE_PREFIX}#{nonce}")
      @server.update!(ownership_verified_at: Time.current)
      Result.new(ok: true, detail: "Verified: Conductor's key for this server is installed.")
    else
      fail(@ssh.error.presence || "Connected, but the verification line is not in ~/.ssh/authorized_keys")
    end
  end

  private

  def fail(detail)
    Result.new(ok: false, detail: detail)
  end
end
