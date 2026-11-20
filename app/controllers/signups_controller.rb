# Open hosted sign-up (plan 02 § 3). Off unless SIGNUP_MODE=open: in invite-only
# mode every action here is a 404, so the routes existing changes nothing.
#
# The response to a submitted email is the same whether or not the address has an
# account — an existing user gets an ordinary sign-in link, a new address gets a
# sign-up link — and both paths do the same work (one row, one queued mail), so
# neither the page nor its timing says which happened.
class SignupsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :set_current_organization
  skip_before_action :require_onboarding
  before_action :require_open_signup!

  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  def new
    redirect_to root_path and return if current_user
  end

  def create
    @email = SignupIntent.normalize(params[:email])
    @error = refusal_for(@email)
    return render(:new, status: :unprocessable_entity) if @error

    if SignupMailCap.take!
      if (user = User.find_by(email: @email))
        passwordless_session = Passwordless::Session.create!(authenticatable: user)
        UserMailer.magic_link(passwordless_session, passwordless_session.token).deliver_later
      else
        intent, raw_token = SignupIntent.start!(email: @email, ip: request.remote_ip)
        SignupMailer.verify(intent, raw_token).deliver_later
      end
    end

    redirect_to signup_sent_path
  end

  def sent; end

  # The emailed link. The account is created here, never earlier.
  def verify
    intent = SignupIntent.find_by_raw_token(params[:token])
    return render(:invalid, status: :not_found) unless intent

    user = intent.consume!
    sign_in(Passwordless::Session.create!(authenticatable: user))
    redirect_to card_check_path
  rescue SignupIntent::Refused => e
    @error = e.message
    render :invalid, status: :unprocessable_entity
  end

  private

  def require_open_signup!
    return if SignupMode.open? && User.admins.exists?

    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end

  # Errors about the FORM, never about whether an account exists.
  def refusal_for(email)
    return "Enter a valid email address." unless email.match?(EMAIL_FORMAT) && email.length <= 254
    return "Accept the terms to create an account." unless params[:terms] == "1"
    return "Use a permanent email address — disposable inboxes cannot sign up." if DisposableEmail.disposable?(email)
    return "The human check failed. Try again." unless Turnstile.new.verify(params["cf-turnstile-response"], remote_ip: request.remote_ip)

    nil
  end
end
