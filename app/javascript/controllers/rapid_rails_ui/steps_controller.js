import { Controller } from "@hotwired/stimulus"

/**
 * Steps Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Manages multi-step wizard navigation with Turbo Frame integration.
 * Handles step transitions via form submission with direction parameter.
 *
 * Usage:
 *   <div data-controller="rapid-rails-ui--steps"
 *        data-rapid-rails-ui--steps-current-value="0"
 *        data-rapid-rails-ui--steps-total-value="3">
 *     <form data-rapid-rails-ui--steps-target="form">
 *       <input type="hidden" name="direction" data-rapid-rails-ui--steps-target="directionInput">
 *       <!-- step content -->
 *       <button data-action="rapid-rails-ui--steps#back">Back</button>
 *       <button data-action="rapid-rails-ui--steps#next">Next</button>
 *     </form>
 *   </div>
 *
 * Events dispatched:
 *   - steps:before-navigate - Before step transition (cancelable)
 *   - steps:after-navigate - After form submitted
 *   - steps:step-changed - When step value changes
 */
export default class extends Controller {
  static targets = [
    "form",
    "indicator",
    "content",
    "nextButton",
    "backButton",
    "directionInput"
  ]

  static values = {
    current: { type: Number, default: 0 },
    total: { type: Number, default: 0 },
    navigation: { type: String, default: "linear" },
    cacheLocally: { type: Boolean, default: true },
    storageKey: { type: String, default: "" },
    clientValidation: { type: Boolean, default: true },
    errorStep: { type: Number, default: -1 }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this._loadFromStorage()
    this._updateIndicatorStates()
  }

  // ==========================================================================
  // VALUE CHANGE CALLBACKS
  // ==========================================================================

  currentValueChanged(value, previousValue) {
    if (previousValue !== undefined) {
      this._saveToStorage()
      this._updateIndicatorStates()
      this.dispatch("step-changed", {
        detail: { current: value, previous: previousValue, total: this.totalValue }
      })
    }
  }

  // ==========================================================================
  // NAVIGATION ACTIONS
  // ==========================================================================

  /**
   * Navigate to the next step
   * Sets direction input to "next" and submits the form
   * Validates form if client validation is enabled
   */
  next(event) {
    if (event) event.preventDefault()

    // Run client-side validation if enabled
    if (this.clientValidationValue && !this._validateForm()) {
      return
    }

    // Dispatch cancelable before event
    const beforeEvent = this.dispatch("before-navigate", {
      detail: { direction: "next", currentStep: this.currentValue },
      cancelable: true
    })

    if (beforeEvent.defaultPrevented) return

    this._setDirection("next")
    this._submitForm()

    this.dispatch("after-navigate", {
      detail: { direction: "next", currentStep: this.currentValue }
    })
  }

  /**
   * Navigate to the previous step
   * Sets direction input to "back" and submits the form
   */
  back(event) {
    if (event) event.preventDefault()

    // Don't proceed if already on first step
    if (this.currentValue <= 0) return

    // Dispatch cancelable before event
    const beforeEvent = this.dispatch("before-navigate", {
      detail: { direction: "back", currentStep: this.currentValue },
      cancelable: true
    })

    if (beforeEvent.defaultPrevented) return

    this._setDirection("back")
    this._submitForm()

    this.dispatch("after-navigate", {
      detail: { direction: "back", currentStep: this.currentValue }
    })
  }

  /**
   * Navigate to a specific step (for non-linear navigation modes)
   * @param {Event} event - Click event with data-step attribute
   */
  goToStep(event) {
    if (event) event.preventDefault()

    const stepIndex = parseInt(event.currentTarget.dataset.step, 10)
    if (isNaN(stepIndex)) return

    // Check if navigation to this step is allowed
    if (!this._canNavigateTo(stepIndex)) return

    // Dispatch cancelable before event
    const beforeEvent = this.dispatch("before-navigate", {
      detail: { direction: `goto:${stepIndex}`, currentStep: this.currentValue },
      cancelable: true
    })

    if (beforeEvent.defaultPrevented) return

    this._setDirection(`goto:${stepIndex}`)
    this._submitForm()

    this.dispatch("after-navigate", {
      detail: { direction: `goto:${stepIndex}`, currentStep: this.currentValue }
    })
  }

  // ==========================================================================
  // HELPER METHODS
  // ==========================================================================

  /**
   * Check if navigation to a step is allowed based on navigation mode
   * @param {number} stepIndex - Target step index
   * @returns {boolean}
   */
  _canNavigateTo(stepIndex) {
    // Validate bounds
    if (stepIndex < 0 || stepIndex >= this.totalValue) return false

    switch (this.navigationValue) {
      case "free":
        // Can navigate to any step
        return true

      case "completed_only":
        // Can navigate to completed steps or the next available step
        return stepIndex <= this.currentValue + 1

      case "linear":
      default:
        // Can only go forward/back one step at a time (via next/back buttons)
        return Math.abs(stepIndex - this.currentValue) === 1
    }
  }

  /**
   * Set the direction input value before form submission
   * @param {string} direction - "next", "back", or "goto:N"
   */
  _setDirection(direction) {
    if (this.hasDirectionInputTarget) {
      this.directionInputTarget.value = direction
    }
  }

  /**
   * Submit the form via Turbo
   */
  _submitForm() {
    if (this.hasFormTarget) {
      this.formTarget.requestSubmit()
    }
  }

  /**
   * Validate the form using HTML5 validation API
   * @returns {boolean} true if valid, false if invalid
   */
  _validateForm() {
    if (!this.hasFormTarget) return true

    // Check form validity
    if (this.formTarget.checkValidity()) {
      return true
    }

    // Show validation messages for invalid fields
    this.formTarget.reportValidity()

    // Dispatch validation-failed event
    this.dispatch("validation-failed", {
      detail: { currentStep: this.currentValue }
    })

    return false
  }

  /**
   * Update visual states of step indicators
   */
  _updateIndicatorStates() {
    this.indicatorTargets.forEach((indicator, index) => {
      const stepIndex = parseInt(indicator.dataset.stepIndex, 10)
      const state = this._getStepState(stepIndex)

      // Update data attribute for CSS styling
      indicator.dataset.state = state

      // Update aria attributes
      const isActive = state === "active"
      if (isActive) {
        indicator.setAttribute("aria-current", "step")
      } else {
        indicator.removeAttribute("aria-current")
      }
    })
  }

  /**
   * Get the state of a step based on current position
   * @param {number} index - Step index
   * @returns {string} "completed", "active", "pending", or "error"
   */
  _getStepState(index) {
    if (index === this.errorStepValue) return "error"
    if (index < this.currentValue) return "completed"
    if (index === this.currentValue) return "active"
    return "pending"
  }

  // ==========================================================================
  // LOCALSTORAGE CACHING
  // ==========================================================================

  /**
   * Save current step to localStorage
   * Only saves if caching is enabled and storage key is set
   */
  _saveToStorage() {
    if (!this.cacheLocallyValue || !this.storageKeyValue) return

    try {
      const data = {
        currentStep: this.currentValue,
        timestamp: Date.now()
      }
      localStorage.setItem(this.storageKeyValue, JSON.stringify(data))
    } catch (e) {
      // localStorage may be unavailable or full
      console.warn("[Steps] Failed to save to localStorage:", e)
    }
  }

  /**
   * Load cached step from localStorage
   * Note: Server step takes precedence, this is just for UI feedback
   */
  _loadFromStorage() {
    if (!this.cacheLocallyValue || !this.storageKeyValue) return

    try {
      const cached = localStorage.getItem(this.storageKeyValue)
      if (!cached) return

      const { currentStep, timestamp } = JSON.parse(cached)

      // Only use cache if less than 24 hours old
      const maxAge = 24 * 60 * 60 * 1000 // 24 hours in ms
      if (Date.now() - timestamp > maxAge) {
        localStorage.removeItem(this.storageKeyValue)
        return
      }

      // Note: We don't override currentValue because server is source of truth
      // This method is mainly for analytics/logging or future use
      // The server-rendered currentValue is always correct
    } catch (e) {
      // Invalid JSON or localStorage unavailable
      console.warn("[Steps] Failed to load from localStorage:", e)
    }
  }

  /**
   * Clear cached step from localStorage
   * Call this when wizard is completed or reset
   */
  clearStorage() {
    if (!this.storageKeyValue) return

    try {
      localStorage.removeItem(this.storageKeyValue)
    } catch (e) {
      console.warn("[Steps] Failed to clear localStorage:", e)
    }
  }

  // ==========================================================================
  // KEYBOARD NAVIGATION
  // ==========================================================================

  /**
   * Handle keyboard navigation on step indicators
   * @param {KeyboardEvent} event
   */
  handleKeydown(event) {
    // Only handle keyboard events on indicator elements
    const indicator = event.target.closest("[data-rapid-rails-ui--steps-target='indicator']")
    if (!indicator) return

    const currentIndex = parseInt(indicator.dataset.stepIndex, 10)
    if (isNaN(currentIndex)) return

    let targetIndex = null
    let shouldActivate = false

    switch (event.key) {
      case "ArrowRight":
      case "ArrowDown":
        event.preventDefault()
        targetIndex = Math.min(currentIndex + 1, this.totalValue - 1)
        break

      case "ArrowLeft":
      case "ArrowUp":
        event.preventDefault()
        targetIndex = Math.max(currentIndex - 1, 0)
        break

      case "Home":
        event.preventDefault()
        targetIndex = 0
        break

      case "End":
        event.preventDefault()
        targetIndex = this.totalValue - 1
        break

      case "Enter":
      case " ":
        event.preventDefault()
        shouldActivate = true
        targetIndex = currentIndex
        break

      default:
        return
    }

    if (targetIndex !== null) {
      // Focus the target indicator
      const targetIndicator = this.indicatorTargets[targetIndex]
      if (targetIndicator) {
        const focusableElement = targetIndicator.querySelector("button, [tabindex='0']")
        if (focusableElement) {
          focusableElement.focus()
        }

        // If Enter/Space was pressed, try to activate the step
        if (shouldActivate && this._canNavigateTo(targetIndex)) {
          this._navigateToStep(targetIndex)
        }
      }
    }
  }

  /**
   * Navigate directly to a specific step
   * @param {number} stepIndex - Target step index
   */
  _navigateToStep(stepIndex) {
    if (!this._canNavigateTo(stepIndex)) return

    const beforeEvent = this.dispatch("before-navigate", {
      detail: { direction: `goto:${stepIndex}`, currentStep: this.currentValue },
      cancelable: true
    })

    if (beforeEvent.defaultPrevented) return

    this._setDirection(`goto:${stepIndex}`)
    this._submitForm()

    this.dispatch("after-navigate", {
      detail: { direction: `goto:${stepIndex}`, currentStep: this.currentValue }
    })
  }

  // ==========================================================================
  // ERROR STATE MANAGEMENT
  // ==========================================================================

  /**
   * Set error state on a specific step
   * @param {number} stepIndex - Index of step with error
   */
  setError(stepIndex) {
    if (stepIndex < 0 || stepIndex >= this.totalValue) return

    this.errorStepValue = stepIndex
    this._updateIndicatorStates()

    this.dispatch("error-set", {
      detail: { errorStep: stepIndex }
    })
  }

  /**
   * Clear error state from a specific step
   * @param {number} stepIndex - Index of step to clear error from
   */
  clearError(stepIndex) {
    if (this.errorStepValue === stepIndex) {
      this.errorStepValue = -1
      this._updateIndicatorStates()

      this.dispatch("error-cleared", {
        detail: { clearedStep: stepIndex }
      })
    }
  }

  /**
   * Clear all error states
   */
  clearAllErrors() {
    if (this.errorStepValue >= 0) {
      const previousError = this.errorStepValue
      this.errorStepValue = -1
      this._updateIndicatorStates()

      this.dispatch("error-cleared", {
        detail: { clearedStep: previousError }
      })
    }
  }

  // ==========================================================================
  // PUBLIC GETTERS
  // ==========================================================================

  get isFirstStep() {
    return this.currentValue === 0
  }

  get isLastStep() {
    return this.currentValue === this.totalValue - 1
  }

  get hasError() {
    return this.errorStepValue >= 0
  }
}
