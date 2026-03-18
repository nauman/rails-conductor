Passwordless.configure do |config|
  config.parent_mailer = "ActionMailer::Base"
  config.default_from_address = "noreply@conductor.local"

  # Time-to-live for magic link tokens
  config.timeout_at = lambda { 10.minutes.from_now }

  # Expiration time for sessions
  config.expires_at = lambda { 30.days.from_now }

  # Redirect path after successful sign in
  config.success_redirect_path = "/"

  # Redirect path after sign out
  config.sign_out_redirect_path = "/"

  # Auto-create users on sign-in. First user becomes admin.
  config.after_session_save = lambda do |session, request|
    UserMailer.magic_link(session, session.token).deliver_now
  end
end

# Use application layout for login pages
Rails.application.config.after_initialize do
  Passwordless::SessionsController.layout "application"

  # Redirect already signed-in users away from sign-in page
  Passwordless::SessionsController.class_eval do
    prepend_before_action :redirect_if_already_signed_in, only: [:new, :create]

    private

    def redirect_if_already_signed_in
      if authenticate_by_session(User)
        redirect_to "/", notice: "You're already signed in."
      end
    end
  end
end
