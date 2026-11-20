# A daily ceiling on mail the sign-up form can make this instance send, so a
# flood of sign-ups cannot burn the sender's reputation (plan 02 § 5.2).
# SIGNUP_DAILY_MAIL_CAP overrides the default.
module SignupMailCap
  DEFAULT = 500

  module_function

  def limit = (ENV["SIGNUP_DAILY_MAIL_CAP"].presence || DEFAULT).to_i

  # True when another mail may go out today (and counts it).
  def take!(now: Time.current)
    count = TenantLimits.store.increment("signup-mail:#{now.utc.to_date}", 1, expires_in: 2.days)
    return true if count.nil? || count <= limit

    Rails.logger.warn("[signup] daily mail cap #{limit} reached; not sending")
    false
  end
end
