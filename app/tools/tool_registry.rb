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

  # Tools a read-only token may call. conductor_read is the only non-mutating
  # tool; everything else mutates infra and needs a deploy-scoped token.
  READ_ONLY_TOOLS = %w[conductor_read].freeze

  def self.call(name, input, user:)
    tool_class = find(name)
    return Result.fail("Unknown tool: #{name}") unless tool_class

    if Current.read_only && !READ_ONLY_TOOLS.include?(name)
      return Result.fail("This token is read-only; '#{name}' requires a deploy-scoped token.")
    end

    # Same OperatorPolicy as the web layer: mutating tools execute real
    # infrastructure, so a plain member cannot run them even with a self-minted
    # deploy token — only an org owner or platform admin can.
    unless READ_ONLY_TOOLS.include?(name) || OperatorPolicy.operator?(user, Current.organization)
      return Result.fail("This action requires an organization owner.")
    end

    tool_class.new(user: user).call(input)
  rescue => e
    Result.fail(e.message)
  end
end
