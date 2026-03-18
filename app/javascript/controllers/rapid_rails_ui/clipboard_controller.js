import { Controller } from "@hotwired/stimulus"

/**
 * Clipboard Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Copies text from a target element to clipboard with visual feedback.
 * Uses modern Clipboard API (supported in all modern browsers).
 *
 * Targets:
 * - defaultMessage: Element shown by default (icon + "Copy")
 * - successMessage: Element shown after copy (icon + "Copied!")
 * - tooltipDefault: Optional tooltip default text
 * - tooltipSuccess: Optional tooltip success text
 *
 * Values:
 * - target: ID of the element to copy text from
 */
export default class extends Controller {
  static targets = ["defaultMessage", "successMessage", "tooltipDefault", "tooltipSuccess"]
  static values = { target: String }

  async copy(event) {
    event.preventDefault()

    const element = document.getElementById(this.targetValue)
    if (!element) return

    const text = element.value ?? element.textContent?.trim()
    if (!text) return

    try {
      await navigator.clipboard.writeText(text)
      this.showSuccess()
    } catch (error) {
      console.error("Clipboard: Failed to copy", error)
    }
  }

  showSuccess() {
    this.defaultMessageTarget.classList.add("opacity-0", "pointer-events-none")
    this.successMessageTarget.classList.remove("opacity-0", "pointer-events-none")

    if (this.hasTooltipDefaultTarget) {
      this.tooltipDefaultTarget.classList.add("opacity-0")
      this.tooltipSuccessTarget.classList.remove("opacity-0")
    }

    setTimeout(() => this.reset(), 2000)
  }

  reset() {
    this.defaultMessageTarget.classList.remove("opacity-0", "pointer-events-none")
    this.successMessageTarget.classList.add("opacity-0", "pointer-events-none")

    if (this.hasTooltipDefaultTarget) {
      this.tooltipDefaultTarget.classList.remove("opacity-0")
      this.tooltipSuccessTarget.classList.add("opacity-0")
    }
  }
}
