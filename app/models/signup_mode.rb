# Whether strangers can create accounts on this instance (plan 02, open hosted
# sign-up). Defaults to invite-only, so a self-hosted install and an instance that
# never sets SIGNUP_MODE behave exactly as before.
#
# Anything that is only safe while every user was invited asks `open?` and
# refuses in open mode.
module SignupMode
  class BootRefused < StandardError; end

  module_function

  def open?
    ENV["SIGNUP_MODE"].to_s.strip.downcase == "open"
  end

  # The one address allowed to become the first admin of an open instance. In
  # open mode the empty-database bootstrap ("first email wins") is off: a public
  # instance whose database is ever empty — a fresh region, a restore gone wrong —
  # would otherwise hand admin to whoever typed an email first.
  def bootstrap_admin_email
    ENV["BOOTSTRAP_ADMIN_EMAIL"].to_s.strip.downcase.presence
  end

  # Refuse to serve an open instance that has no admin. Called from an
  # initializer when the web server boots; also callable from a deploy check.
  # Open with zero admins means nobody can suspend an abuser, so the door stays
  # shut until an operator exists (BOOTSTRAP_ADMIN_EMAIL or
  # `bin/rails conductor:bootstrap_admin`).
  def verify_boot!(admins_exist: -> { User.admins.exists? })
    return unless open?
    return if admins_exist.call

    raise BootRefused,
          "SIGNUP_MODE=open with no platform admin. Create one first " \
          "(bin/rails conductor:bootstrap_admin EMAIL=you@example.com), or set SIGNUP_MODE=invite_only."
  end
end
