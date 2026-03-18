class ProcessMessageJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    message = Message.find(message_id)
    message.process_now
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("ProcessMessageJob: Message #{message_id} not found")
  end
end
