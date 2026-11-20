import { Controller } from "@hotwired/stimulus"

// Collects a card with Stripe Elements and confirms a SetupIntent (verify, never
// charge). The server creates the SetupIntent and checks the result with Stripe;
// this controller only moves the card between the page and Stripe.
export default class extends Controller {
  static targets = ["card", "error", "submit"]
  static values = { publishableKey: String, intentUrl: String, returnUrl: String, csrf: String }

  connect() {
    if (!window.Stripe) {
      this.showError("Card form could not load. Check your connection and reload.")
      return
    }
    this.stripe = window.Stripe(this.publishableKeyValue)
    this.card = this.stripe.elements().create("card")
    this.card.mount(this.cardTarget)
  }

  disconnect() {
    this.card?.destroy()
  }

  async submit(event) {
    event.preventDefault()
    this.submitTarget.disabled = true
    this.showError("")

    const response = await fetch(this.intentUrlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": this.csrfValue, "Accept": "application/json" }
    })
    const body = await response.json()
    if (!response.ok) return this.fail(body.error)

    const result = await this.stripe.confirmCardSetup(body.client_secret, { payment_method: { card: this.card } })
    if (result.error) return this.fail(result.error.message)

    window.location.assign(`${this.returnUrlValue}?setup_intent=${encodeURIComponent(result.setupIntent.id)}`)
  }

  fail(message) {
    this.showError(message || "The card could not be verified.")
    this.submitTarget.disabled = false
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.hidden = !message
  }
}
