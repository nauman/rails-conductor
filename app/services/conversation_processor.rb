class ConversationProcessor
  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are Conductor — an ops assistant for an indie developer managing a fleet of self-hosted Rails apps.

    Your job is to help the user:
    - Understand the current state of their fleet (servers, apps, deployments)
    - Provision new servers and run setup scripts
    - Deploy apps and check deployment logs
    - Manage Caddy routes for custom domains

    Use the available tools to take real actions. Always confirm before running destructive operations.
    Be concise. Show key details (IDs, statuses, durations) without unnecessary prose.
  PROMPT

  def initialize(message:, model: default_model)
    @message      = message
    @conversation = message.conversation
    @user         = @conversation.user
    @model        = model
  end

  def process
    @message.mark_streaming!
    configure_ruby_llm

    response = call_ai(build_history)
    handle_response(response)

    Result.ok
  rescue => e
    @message.mark_error!("Error: #{e.message}")
    Result.fail(e.message)
  end

  private

  # ── AI call ────────────────────────────────────────────────────────────────

  def call_ai(history)
    RubyLLM.chat(
      model:    @model,
      messages: history,
      tools:    ruby_llm_tools,
      system:   SYSTEM_PROMPT
    )
  end

  def handle_response(response)
    # Keep calling AI until it gives a final text response (no more tool calls)
    loop do
      if response.tool_calls?
        tool_results = execute_tool_calls(response.tool_calls)
        response = call_ai(build_history + tool_result_messages(response, tool_results))
      else
        @message.mark_complete!(response.content)
        @conversation.auto_title_from(@message.content) if @conversation.messages.count == 2
        break
      end
    end
  end

  # ── Tool execution ──────────────────────────────────────────────────────────

  def execute_tool_calls(tool_calls)
    tool_calls.map do |tc|
      execution = ToolExecution.create!(
        message:    @message,
        tool_name:  tc.name,
        tool_input: tc.arguments,
        status:     'pending'
      )

      execution.start!
      result = ToolRegistry.call(tc.name, tc.arguments.stringify_keys, user: @user)
      # Tools may embed an internal `_organization` marker in their Hash payload
      # (used for MCP audit logging). Strip it before exposing output to the LLM.
      output =
        if result.success?
          value = result.value
          value.is_a?(Hash) ? value.except(:_organization) : value
        else
          { error: result.error }
        end
      execution.finish!(output: output, success: result.success?)

      { id: tc.id, name: tc.name, output: execution.tool_output }
    end
  end

  def tool_result_messages(ai_response, tool_results)
    assistant_msg = { role: 'assistant', content: ai_response.content || '', tool_calls: ai_response.tool_calls }
    tool_msg = { role: 'tool', content: tool_results.map { |r| { type: 'tool_result', tool_use_id: r[:id], content: r[:output].to_json } } }
    [ assistant_msg, tool_msg ]
  end

  # ── Message history ─────────────────────────────────────────────────────────

  def build_history
    @conversation.messages.complete.map do |msg|
      { role: msg.role, content: msg.content.to_s }
    end
  end

  # ── Tool definitions for ruby_llm ──────────────────────────────────────────

  def ruby_llm_tools
    ToolRegistry.definitions.map do |defn|
      RubyLLM::Tool.new(
        name:        defn[:name],
        description: defn[:description],
        parameters:  defn[:input_schema][:properties].transform_values { |v| v.slice(:type, :description) },
        required:    defn[:input_schema][:required] || []
      )
    end
  rescue
    # If RubyLLM::Tool API differs, fall back to raw definitions
    ToolRegistry.definitions
  end

  # ── Config ─────────────────────────────────────────────────────────────────

  def configure_ruby_llm
    RubyLLM.configure do |c|
      c.anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY', '')
      c.openai_api_key    = ENV['OPENAI_API_KEY']
    end
  end

  def default_model
    ENV.fetch('CONDUCTOR_MODEL', 'claude-opus-4-6')
  end
end
