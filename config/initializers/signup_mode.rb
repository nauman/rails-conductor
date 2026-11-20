# Refuse to serve SIGNUP_MODE=open with no platform admin (plan 02 § 5.1).
#
# Only the web server is gated: db:prepare and other tasks boot the same
# environment and must still run against an empty database, or a fresh install
# could never create the schema it needs to bootstrap the admin.
Rails.application.config.after_initialize do
  next unless defined?(Rails::Server)
  next unless SignupMode.open?

  SignupMode.verify_boot!
end
