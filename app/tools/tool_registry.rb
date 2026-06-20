class ToolRegistry
  TOOLS = [
    FleetStatusTool,
    RunScriptTool,
    RecentLogsTool,
    AddDomainTool,
    RemoveDomainTool,
    DeployAppTool,
    RegisterServerTool,
    RegisterDatabaseClusterTool,
    ProvisionDatabaseTool,
    CreateAppTool,
    SetEnvVariableTool,
    UpdateAppTool,
    SyncAppStatusTool,
    GenerateDeployKeyTool,
    DeploymentLogTool,
    SetGithubTokenTool,
    SetGithubAppTool,
    GithubInstallationsTool
  ].freeze

  def self.definitions
    TOOLS.map { |t| t::DEFINITION }
  end

  def self.find(name)
    TOOLS.find { |t| t::DEFINITION[:name] == name }
  end

  # Tools a read-only token may call. Everything else mutates infra and needs a
  # deploy-scoped token.
  READ_ONLY_TOOLS = %w[fleet_status recent_logs deployment_log].freeze

  def self.call(name, input, user:)
    tool_class = find(name)
    return Result.fail("Unknown tool: #{name}") unless tool_class

    if Current.read_only && !READ_ONLY_TOOLS.include?(name)
      return Result.fail("This token is read-only; '#{name}' requires a deploy-scoped token.")
    end

    tool_class.new(user: user).call(input)
  rescue => e
    Result.fail(e.message)
  end
end
