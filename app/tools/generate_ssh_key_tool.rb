# Generate a deploy keypair on the Conductor server and store it (the Hatchbox
# model). Returns ONLY the public key — the private half stays encrypted in
# Conductor's DB and is never returned or logged. Attach the resulting key to a
# server with conductor_server action: update, then test_connection.
class GenerateSshKeyTool
  include ActorScoped
  include OrgResolvable

  def initialize(user:)
    @user = user
  end

  def call(input)
    org, error = resolve_organization(input)
    return Result.fail(error) if error

    keypair = DeployKeyGenerator.generate(comment: "conductor-#{org.name.parameterize}")
    key = org.ssh_keys.new(name: input["name"].presence || "Conductor deploy key")
    key.private_key = keypair[:private_key]
    return Result.fail(key.errors.full_messages.join(", ")) unless key.save

    # Store ssh-keygen's authoritative OpenSSH public key (an authorized_keys line).
    key.update_columns(public_key: keypair[:public_key], fingerprint: keypair[:fingerprint])

    Result.ok({
      id:            key.id,
      name:          key.name,
      public_key:    keypair[:public_key],
      fingerprint:   keypair[:fingerprint],
      message:       "Deploy key created. Add this public key to the server's authorized_keys (as the deploy/root user), " \
                     "then attach it with conductor_server action: update (ssh_key_id: #{key.id}) and run test_connection.",
      _organization: org
    })
  rescue DeployKeyGenerator::Error => e
    Result.fail("Key generation failed: #{e.message}")
  end
end
