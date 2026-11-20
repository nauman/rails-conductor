# The card check before onboarding (plan 02 § 3 step 3a). A Stripe SetupIntent:
# the browser collects and confirms the card with Stripe.js, then Conductor asks
# Stripe — not the browser — whether it verified. Nothing is ever charged; see
# StripeCardCheck for why that is structural.
class CardChecksController < ApplicationController
  before_action :require_card_check_pending!

  def show; end

  # JSON: a fresh SetupIntent's client_secret for Stripe.js.
  def create
    client_secret = StripeCardCheck.new.start!(current_organization, email: current_user.email)
    render json: { client_secret: client_secret }
  rescue StripeCardCheck::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Stripe.js redirects here after confirmCardSetup.
  def complete
    StripeCardCheck.new.complete!(current_organization, params[:setup_intent])
    redirect_to onboarding_path, notice: "Card verified — it was not charged."
  rescue StripeCardCheck::Error => e
    redirect_to card_check_path, alert: e.message
  end

  private

  def require_card_check_pending!
    redirect_to root_path unless current_organization&.card_check_required?
  end
end
