class UserMailer < ApplicationMailer
  def magic_link(passwordless_session, token)
    @passwordless_session = passwordless_session
    @user = passwordless_session.authenticatable
    @token = token
    @magic_link = confirm_user_sign_in_url(id: @passwordless_session.identifier, token: @token)

    mail(
      to: @user.email,
      subject: "Your magic link to sign in to Conductor"
    )
  end
end
