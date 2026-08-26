# Update an existing server's config — notably to ATTACH an SSH key and set the
# login user, which is what lets Conductor actually reach a registered host.
# (SSH keys are created in the UI, where the private key is encrypted and never
# logged — this tool only attaches an existing key by id or name.)
class UpdateServerTool
  include ActorScoped

  UPDATABLE = %w[name ip_address ssh_user ssh_port provider region build_role].freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    attrs = UPDATABLE.each_with_object({}) { |k, h| h[k] = input[k] if input.key?(k) }

    if input.key?("ssh_key_id")
      if input["ssh_key_id"].nil?
        attrs["ssh_key_id"] = nil # explicit detach
      else
        # Resolve through the scoped collection — never trust a raw id, or a
        # tenant could attach another org's private key to a server.
        key = visible_ssh_keys.find_by(id: input["ssh_key_id"])
        return Result.fail("SSH key not found: #{input['ssh_key_id']}") unless key
        attrs["ssh_key_id"] = key.id
      end
    elsif input["ssh_key_name"].present?
      key = visible_ssh_keys.find_by(name: input["ssh_key_name"])
      return Result.fail("SSH key not found: #{input['ssh_key_name']}. Available: #{visible_ssh_keys.pluck(:name).join(', ').presence || '(none — add one in the UI)'}") unless key
      attrs["ssh_key_id"] = key.id
    end

    return Result.fail("Nothing to update. Provide at least one of: #{(UPDATABLE + %w[ssh_key_id ssh_key_name]).join(', ')}.") if attrs.empty?
    return Result.fail(server.errors.full_messages.join(", ")) unless server.update(attrs)

    Result.ok({
      id:            server.id,
      name:          server.name,
      ip_address:    server.ip_address,
      ssh_user:      server.ssh_user,
      ssh_key:       server.ssh_key&.name,
      provider:      server.provider,
      region:        server.region,
      build_role:    server.build_role,
      message:       "Updated #{server.name}." + (attrs.key?("ssh_key_id") ? " Run action: test_connection to verify." : ""),
      _organization: server.organization
    })
  end
end
