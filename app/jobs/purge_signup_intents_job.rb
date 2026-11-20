# Unclicked (and spent) sign-up intents older than 24 hours are deleted (plan 02
# § 3, delegated default). An intent was never an account, so nothing else goes.
class PurgeSignupIntentsJob < ApplicationJob
  queue_as :ops

  def perform(now: Time.current)
    SignupIntent.purgeable(now).delete_all
  end
end
