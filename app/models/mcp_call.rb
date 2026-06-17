class McpCall < ApplicationRecord
  STATUSES = %w[success failed].freeze

  belongs_to :user, optional: true
  belongs_to :organization, optional: true

  validates :tool_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def success?
    status == "success"
  end

  # Records a single MCP tool invocation. `result` is a Result-like object
  # responding to #success? and #value/#error; timing is measured by the caller.
  # `organization` is optional: the org a call touched, for the audit log
  # (nil for admin-global calls that don't act on a single org's resource).
  def self.record(tool_name:, arguments:, result:, duration_ms:, user: nil, organization: nil)
    create!(
      user: user,
      organization: organization,
      tool_name: tool_name.to_s,
      arguments: arguments || {},
      status: result.success? ? "success" : "failed",
      result: (serialized_result(result.value) if result.success? && !result.value.nil?),
      error: (result.error unless result.success?),
      duration_ms: duration_ms
    )
  rescue StandardError => e
    Rails.logger.warn("McpCall.record failed: #{e.message}")
    nil
  end

  # Strip the internal `_organization` marker (an Organization record some tools
  # embed for audit logging) so it never lands in the stored result JSON.
  def self.serialized_result(value)
    value = value.except(:_organization) if value.is_a?(Hash)
    value.to_json
  end
end
