# Whether strangers can create accounts on this instance (plan 02, open hosted
# sign-up). Defaults to invite-only, so a self-hosted install and an instance that
# never sets SIGNUP_MODE behave exactly as before.
#
# Anything that is only safe while every user was invited asks `open?` and
# refuses in open mode.
module SignupMode
  module_function

  def open?
    ENV["SIGNUP_MODE"].to_s.strip.downcase == "open"
  end
end
