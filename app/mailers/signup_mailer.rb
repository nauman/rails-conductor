class SignupMailer < ApplicationMailer
  def verify(intent, raw_token)
    @verify_url = verify_signup_url(token: raw_token)
    mail(to: intent.email, subject: "Confirm your email to create your Conductor account")
  end
end
