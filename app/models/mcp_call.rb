class McpCall < ApplicationRecord
  STATUSES = %w[success failed].freeze

  belongs_to :user, optional: true

  validates :tool_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def success?
    status == "success"
  end

  # Records a single MCP tool invocation. `result` is a Result-like object
  # responding to #success? and #value/#error; timing is measured by the caller.
  def self.record(tool_name:, arguments:, result:, duration_ms:, user: nil)
    create!(
      user: user,
      tool_name: tool_name.to_s,
      arguments: arguments || {},
      status: result.success? ? "success" : "failed",
      result: (result.value.to_json if result.success? && !result.value.nil?),
      error: (result.error unless result.success?),
      duration_ms: duration_ms
    )
  rescue StandardError => e
    Rails.logger.warn("McpCall.record failed: #{e.message}")
    nil
  end
end
