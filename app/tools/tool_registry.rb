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
    GenerateDeployKeyTool
  ].freeze

  def self.definitions
    TOOLS.map { |t| t::DEFINITION }
  end

  def self.find(name)
    TOOLS.find { |t| t::DEFINITION[:name] == name }
  end

  def self.call(name, input, user:)
    tool_class = find(name)
    return Result.fail("Unknown tool: #{name}") unless tool_class

    tool_class.new(user: user).call(input)
  rescue => e
    Result.fail(e.message)
  end
end
