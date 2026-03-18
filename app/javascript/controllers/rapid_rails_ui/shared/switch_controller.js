import { Controller } from "@hotwired/stimulus"

/**
 * Switch Toggle Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A reusable controller for toggle switch visual behavior.
 * Handles the CSS class toggling for track and knob elements.
 *
 * Usage:
 *   <label data-controller="switch">
 *     <span>Dark Mode</span>
 *     <button type="button"
 *             role="switch"
 *             aria-checked="false"
 *             data-switch-target="track"
 *             data-action="click->switch#toggle keydown.enter->switch#toggle keydown.space->switch#toggle">
 *       <span data-switch-target="knob"></span>
 *     </button>
 *     <input type="hidden" data-switch-target="input" value="0">
 *   </label>
 *
 * Can be composed with other controllers:
 *   <div data-controller="menu switch" ...>
 *
 * Dispatches events:
 *   - switch:change - After toggle, with { checked }
 */
export default class extends Controller {
  static targets = ["track", "knob", "input"]

  // CSS classes for toggle states (can be customized via values)
  static values = {
    trackOffClasses: { type: Array, default: ["bg-zinc-200", "dark:bg-zinc-700"] },
    trackOnClasses: { type: Array, default: ["bg-blue-600"] },
    knobOffClasses: { type: Array, default: ["translate-x-0"] },
    knobOnClasses: { type: Array, default: ["translate-x-5"] }
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Toggle the switch state
   */
  toggle(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    if (!this.hasTrackTarget || this.trackTarget.disabled) return

    const isChecked = this.trackTarget.getAttribute("aria-checked") === "true"
    const newChecked = !isChecked

    this._updateState(newChecked)
    this.dispatch("change", { detail: { checked: newChecked } })
  }

  /**
   * Set switch to specific state
   */
  setChecked(checked) {
    this._updateState(checked)
  }

  /**
   * Get current checked state
   */
  get checked() {
    if (!this.hasTrackTarget) return false
    return this.trackTarget.getAttribute("aria-checked") === "true"
  }

  // ==========================================================================
  // PRIVATE
  // ==========================================================================

  _updateState(checked) {
    // Update aria attributes
    this.trackTarget.setAttribute("aria-checked", checked.toString())

    // Find parent label and update its aria-checked too
    const label = this.trackTarget.closest("label")
    if (label) {
      label.setAttribute("aria-checked", checked.toString())
    }

    // Update track classes
    if (checked) {
      this.trackTarget.classList.remove(...this.trackOffClassesValue)
      this.trackTarget.classList.add(...this.trackOnClassesValue)
    } else {
      this.trackTarget.classList.remove(...this.trackOnClassesValue)
      this.trackTarget.classList.add(...this.trackOffClassesValue)
    }

    // Update knob classes
    if (this.hasKnobTarget) {
      if (checked) {
        this.knobTarget.classList.remove(...this.knobOffClassesValue)
        this.knobTarget.classList.add(...this.knobOnClassesValue)
      } else {
        this.knobTarget.classList.remove(...this.knobOnClassesValue)
        this.knobTarget.classList.add(...this.knobOffClassesValue)
      }
    }

    // Update hidden input
    if (this.hasInputTarget) {
      this.inputTarget.value = checked ? "1" : "0"
    }
  }
}
