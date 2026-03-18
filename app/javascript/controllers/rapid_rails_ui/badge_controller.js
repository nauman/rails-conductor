import { Controller } from "@hotwired/stimulus"

/**
 * Badge Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles badge visibility toggling, dismissal, and removal.
 */
export default class extends Controller {
  static targets = ["badge"]

  connect() {
  }

  toggle() {
    this.element.classList.toggle("hidden")
  }

  close() {
    this.element.remove()
  }

  dismiss() {
    this.element.classList.add("hidden")
  }
}
