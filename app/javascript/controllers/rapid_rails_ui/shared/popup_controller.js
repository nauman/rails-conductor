import { Controller } from "@hotwired/stimulus"

/**
 * Popup Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A reusable controller for hover/focus triggered popup elements like tooltips and popovers.
 * Handles show/hide with optional delays, smooth transitions, and accessibility attributes.
 *
 * Usage:
 *   <span data-controller="popup"
 *         data-popup-delay-value="0"
 *         data-popup-hide-delay-value="0"
 *         data-popup-trigger-value="hover">
 *     <button data-popup-target="trigger"
 *             data-action="mouseenter->popup#show mouseleave->popup#hide
 *                          focusin->popup#show focusout->popup#hide">
 *       Hover me
 *     </button>
 *     <span data-popup-target="content" class="opacity-0 invisible">
 *       Tooltip content
 *     </span>
 *   </span>
 *
 * Can be composed with other controllers:
 *   <div data-controller="popup keyboard" ...>
 *
 * Dispatches events:
 *   - popup:show - Before showing (cancelable)
 *   - popup:shown - After shown
 *   - popup:hide - Before hiding (cancelable)
 *   - popup:hidden - After hidden
 */
export default class extends Controller {
  static targets = ["trigger", "content"]

  static values = {
    delay: { type: Number, default: 0 },
    hideDelay: { type: Number, default: 0 },
    trigger: { type: String, default: "hover" },
    open: { type: Boolean, default: false }
  }

  // CSS classes for show/hide states
  static SHOW_CLASSES = ["opacity-100", "visible"]
  static HIDE_CLASSES = ["opacity-0", "invisible"]

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this._showTimeout = null
    this._hideTimeout = null

    // Ensure initial hidden state
    this._applyHiddenState()

    // Setup click trigger if needed
    if (this.triggerValue === "click" && this.hasTriggerTarget) {
      this._setupClickBehavior()
    }
  }

  disconnect() {
    this._clearTimeouts()
    this._cleanupClickBehavior()
  }

  openValueChanged(newValue, oldValue) {
    if (oldValue === undefined) return // Skip initial
    newValue ? this._showImmediate() : this._hideImmediate()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Show the popup (with optional delay)
   */
  show(event) {
    // Cancel any pending hide
    this._clearHideTimeout()

    // Apply delay if configured
    if (this.delayValue > 0) {
      this._showTimeout = setTimeout(() => this._showImmediate(), this.delayValue)
    } else {
      this._showImmediate()
    }
  }

  /**
   * Hide the popup (with optional delay)
   */
  hide(event) {
    // Cancel any pending show
    this._clearShowTimeout()

    // Apply delay if configured
    if (this.hideDelayValue > 0) {
      this._hideTimeout = setTimeout(() => this._hideImmediate(), this.hideDelayValue)
    } else {
      this._hideImmediate()
    }
  }

  /**
   * Toggle the popup state
   */
  toggle(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    this.openValue ? this.hide() : this.show()
  }

  /**
   * Handle click outside to close (for click-triggered popups)
   */
  clickOutside(event) {
    if (this.triggerValue === "click" && this.openValue) {
      if (!this.element.contains(event.target)) {
        this.hide()
      }
    }
  }

  /**
   * Handle escape key to close
   */
  escape(event) {
    if (this.openValue) {
      event.preventDefault()
      this.hide()
      if (this.hasTriggerTarget) {
        this.triggerTarget.focus()
      }
    }
  }

  // ==========================================================================
  // PRIVATE: SHOW/HIDE IMPLEMENTATION
  // ==========================================================================

  _showImmediate() {
    if (this.openValue) return // Already open

    // Dispatch cancelable show event
    const showEvent = this.dispatch("show", {
      cancelable: true,
      detail: { trigger: this.hasTriggerTarget ? this.triggerTarget : null }
    })

    if (showEvent.defaultPrevented) return

    this.openValue = true
    this._applyShownState()

    // Dispatch shown event
    this.dispatch("shown", {
      detail: { trigger: this.hasTriggerTarget ? this.triggerTarget : null }
    })
  }

  _hideImmediate() {
    if (!this.openValue) return // Already closed

    // Dispatch cancelable hide event
    const hideEvent = this.dispatch("hide", {
      cancelable: true,
      detail: { trigger: this.hasTriggerTarget ? this.triggerTarget : null }
    })

    if (hideEvent.defaultPrevented) return

    this.openValue = false
    this._applyHiddenState()

    // Dispatch hidden event
    this.dispatch("hidden", {
      detail: { trigger: this.hasTriggerTarget ? this.triggerTarget : null }
    })
  }

  _applyShownState() {
    if (!this.hasContentTarget) return

    this.contentTarget.classList.remove(...this.constructor.HIDE_CLASSES)
    this.contentTarget.classList.add(...this.constructor.SHOW_CLASSES)
    this.contentTarget.setAttribute("aria-hidden", "false")

    if (this.hasTriggerTarget) {
      this.triggerTarget.setAttribute("aria-expanded", "true")
    }
  }

  _applyHiddenState() {
    if (!this.hasContentTarget) return

    this.contentTarget.classList.remove(...this.constructor.SHOW_CLASSES)
    this.contentTarget.classList.add(...this.constructor.HIDE_CLASSES)
    this.contentTarget.setAttribute("aria-hidden", "true")

    if (this.hasTriggerTarget) {
      this.triggerTarget.setAttribute("aria-expanded", "false")
    }
  }

  // ==========================================================================
  // PRIVATE: TIMEOUT MANAGEMENT
  // ==========================================================================

  _clearShowTimeout() {
    if (this._showTimeout) {
      clearTimeout(this._showTimeout)
      this._showTimeout = null
    }
  }

  _clearHideTimeout() {
    if (this._hideTimeout) {
      clearTimeout(this._hideTimeout)
      this._hideTimeout = null
    }
  }

  _clearTimeouts() {
    this._clearShowTimeout()
    this._clearHideTimeout()
  }

  // ==========================================================================
  // PRIVATE: CLICK BEHAVIOR
  // ==========================================================================

  _setupClickBehavior() {
    this._boundClickOutside = this.clickOutside.bind(this)
    document.addEventListener("click", this._boundClickOutside)
  }

  _cleanupClickBehavior() {
    if (this._boundClickOutside) {
      document.removeEventListener("click", this._boundClickOutside)
      this._boundClickOutside = null
    }
  }
}
