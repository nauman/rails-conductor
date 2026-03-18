import { Controller } from "@hotwired/stimulus"

/**
 * Checkbox Switch Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles animation of the switch thumb when checkbox state changes.
 * Applies transform to thumb based on input's checked state.
 *
 * The switch has three main parts:
 * 1. Hidden checkbox input (.peer)
 * 2. Track (background color changes with peer-checked)
 * 3. Thumb (needs JavaScript to apply transform)
 *
 * Values:
 * - distanceXs, distanceSm, distanceBase, distanceLg, distanceXl: Translate distances
 */
export default class extends Controller {
  static targets = ["input", "thumb"]

  // Translate distances for each size (matching checkbox component)
  static values = {
    distanceXs: "calc(32px - 12px - 4px)",    // 16px
    distanceSm: "calc(36px - 16px - 4px)",    // 16px
    distanceBase: "calc(44px - 20px - 4px)",  // 20px
    distanceLg: "calc(56px - 24px - 4px)",    // 28px
    distanceXl: "calc(64px - 28px - 4px)"     // 32px
  }

  connect() {
    // Apply initial thumb position based on checked state
    this.updateThumbPosition()

    // Listen for changes to the input
    this.inputTarget.addEventListener("change", () => this.updateThumbPosition())
  }

  updateThumbPosition() {
    const isChecked = this.inputTarget.checked
    const distance = this.getTranslateDistance()

    if (isChecked) {
      this.thumbTarget.style.transform = `translateX(${distance})`
    } else {
      this.thumbTarget.style.transform = "translateX(0)"
    }
  }

  getTranslateDistance() {
    // Get the size from the input's data attribute or use default
    const size = this.inputTarget.dataset.checkboxSwitchSize || "base"

    // Stimulus static values are accessed with 'Value' suffix
    const distanceKey = `distance${this.capitalizeFirstLetter(size)}Value`
    return this[distanceKey] || this.distanceBaseValue
  }

  capitalizeFirstLetter(str) {
    return str.charAt(0).toUpperCase() + str.slice(1)
  }
}
