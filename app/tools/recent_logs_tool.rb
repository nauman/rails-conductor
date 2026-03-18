class RecentLogsTool
  DEFINITION = {
    name: 'recent_logs',
    description: 'Show recent script run or deployment logs for a server or specific run.',
    input_schema: {
      type: 'object',
      properties: {
        server_id: {
          type: 'integer',
          description: 'Filter logs by server ID'
        },
        script_run_id: {
          type: 'integer',
          description: 'Get logs for a specific script run ID'
        },
        limit: {
          type: 'integer',
          description: 'Number of recent runs to return (default 5)'
        }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    if input['script_run_id'].present?
      run = ScriptRun.find_by(id: input['script_run_id'])
      return Result.fail("ScriptRun not found: #{input['script_run_id']}") unless run

      return Result.ok({
        id:        run.id,
        server:    run.server.name,
        script:    run.script.name,
        status:    run.status,
        started:   run.started_at&.strftime('%Y-%m-%d %H:%M'),
        duration:  run.duration,
        log:       run.log.to_s.last(3000)
      })
    end

    limit = [ (input['limit'] || 5).to_i, 20 ].min
    runs = ScriptRun.includes(:server, :script).recent.limit(limit)
    runs = runs.where(server_id: input['server_id']) if input['server_id'].present?

    data = runs.map do |run|
      {
        id:       run.id,
        server:   run.server.name,
        script:   run.script.name,
        status:   run.status,
        started:  run.started_at&.strftime('%Y-%m-%d %H:%M'),
        duration: run.duration
      }
    end

    Result.ok(data)
  end
end
