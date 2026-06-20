class DatabasePullJob < ApplicationJob
  queue_as :default

  def perform(database_pull_id)
    pull = DatabasePull.find(database_pull_id)
    DatabasePullService.new(pull).run
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("DatabasePullJob: DatabasePull #{database_pull_id} not found")
  end
end
