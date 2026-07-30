class ToolRegistry
  # The wire surface is a set of flat `action`-enum tools. Each delegates via
  # EnumDispatch to the single-purpose `*_tool.rb` implementation classes,
  # which remain as internal handlers (not registered).
  TOOLS = [
    ConductorReadTool,
    ConductorAppTool,
    ConductorAppConfigTool,
    ConductorServerTool,
    ConductorDatabaseTool,
    ConductorDomainTool,
    ConductorGithubTool,
    ConductorRunbookTool,
    ConductorStorageTool,
    ConductorCronTool
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

    input ||= {}
    action = input["action"].to_s
    read_only_call = ToolAuthorization.read_only?(name, action)

    if Current.read_only && !read_only_call
      return Result.fail("This token is read-only; '#{name}' action '#{action}' requires a deploy-scoped token.")
    end

    # Same OperatorPolicy as the web layer: mutating tools execute real
    # infrastructure, so a plain member cannot run them even with a self-minted
    # deploy token — only an owner, editor, or platform admin can.
    unless read_only_call || OperatorPolicy.operator?(user, Current.organization)
      return Result.fail("This action requires an organization owner or editor.")
    end

    # Owner-only bands, resolved per ACTION (and per input field) before the
    # handler runs — EnumDispatch invokes the handler immediately, so this
    # cannot be checked after dispatch. See ToolAuthorization.
    capability = ToolAuthorization.capability_for(name, action, input)
    if capability && !OperatorPolicy.can?(user, Current.organization, capability)
      return Result.fail("'#{name}' action '#{action}' requires an organization owner (#{capability}).")
    end

    tool_class.new(user: user).call(input)
  rescue => e
    Result.fail(e.message)
  end
end
