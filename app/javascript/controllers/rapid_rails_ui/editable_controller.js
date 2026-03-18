import { Controller } from "@hotwired/stimulus"

/**
 * Editable Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Inline editing component that integrates with Turbo for seamless updates.
 * Click to edit, blur/Enter to save via Turbo-compatible fetch, Escape to cancel.
 *
 * Turbo Integration:
 * - Sends PATCH requests with proper Turbo headers
 * - Handles Turbo Stream responses for error feedback
 * - Can be combined with Turbo Frames for partial updates
 *
 * Usage:
 *   <span data-controller="editable"
 *         data-editable-url-value="/posts/1"
 *         data-editable-field-value="post[title]"
 *         data-editable-current-value="My Post">
 *     <span data-editable-target="display"
 *           data-action="click->editable#edit">My Post</span>
 *     <input data-editable-target="input" class="hidden">
 *     <span data-editable-target="saving" class="hidden">Saving...</span>
 *     <span data-editable-target="error" class="hidden"></span>
 *   </span>
 *
 * Events dispatched:
 *   - editable:edit - Before entering edit mode (cancelable)
 *   - editable:save - Before saving (cancelable)
 *   - editable:saved - After successful save
 *   - editable:error - On save error
 *   - editable:cancel - On cancel
 */
export default class extends Controller {
  static targets = ["display", "input", "saving", "error", "icon"]

  static values = {
    url: String,
    field: String,
    current: String,
    inputType: { type: String, default: "text" },
    placeholder: { type: String, default: "Click to edit" },
    required: { type: Boolean, default: false },
    maxlength: Number,
    minlength: Number,
    min: Number,
    max: Number,
    rows: { type: Number, default: 3 }
  }

  // CSS classes for state management
  static SAVING_CLASSES = ["opacity-60", "pointer-events-none"]
  static ERROR_CLASSES = ["ring-2", "ring-red-500"]
  static PLACEHOLDER_CLASSES = ["text-zinc-400", "dark:text-zinc-500", "italic"]
  static SUCCESS_CLASSES = ["bg-green-100", "dark:bg-green-900/30"]
  static TRANSITION_CLASSES = ["transition-colors", "duration-500"]

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this.isEditing = false
    this.isSaving = false
    this.originalValue = this.currentValue
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Switch to edit mode
   * Show input, hide display, focus and select all
   */
  edit(event) {
    if (this.isEditing || this.isSaving) return

    // Dispatch cancelable event
    const editEvent = this.dispatch("edit", {
      cancelable: true,
      detail: { value: this.currentValue }
    })
    if (editEvent.defaultPrevented) return

    this.isEditing = true
    this.originalValue = this.currentValue

    // Match input width to display text width
    const displayWidth = this.displayTarget.offsetWidth
    this.inputTarget.style.width = `${Math.max(displayWidth, 50)}px`

    // Toggle visibility
    this._showInput()
    this._hideError()

    // Set value and focus
    this.inputTarget.value = this.currentValue
    this.inputTarget.focus()

    // Select text based on input type
    if (this.inputTypeValue !== "textarea") {
      this.inputTarget.select()
    } else {
      // For textarea, move cursor to end
      const len = this.inputTarget.value.length
      this.inputTarget.setSelectionRange(len, len)
    }
  }

  /**
   * Save the edited value via Turbo-compatible fetch
   * Called on blur or Enter key
   */
  async save(event) {
    if (!this.isEditing || this.isSaving) return

    const newValue = this.inputTarget.value.trim()

    // Validate required
    if (this.requiredValue && !newValue) {
      this._showError("This field is required")
      this.inputTarget.focus()
      return
    }

    // If value hasn't changed, just cancel
    if (newValue === this.originalValue) {
      this.cancel()
      return
    }

    // Client-side validation
    const validationError = this._validate(newValue)
    if (validationError) {
      this._showError(validationError)
      this.inputTarget.focus()
      return
    }

    // Dispatch cancelable save event
    const saveEvent = this.dispatch("save", {
      cancelable: true,
      detail: { oldValue: this.originalValue, newValue }
    })
    if (saveEvent.defaultPrevented) return

    // Save to server
    await this._submitToServer(newValue)
  }

  /**
   * Handle Enter key for text/number input
   */
  saveOnEnter(event) {
    if (this.inputTypeValue === "textarea") return
    event.preventDefault()
    this.save()
  }

  /**
   * Cancel editing, revert to original value
   */
  cancel(event) {
    if (!this.isEditing) return

    this.isEditing = false
    this.inputTarget.value = this.originalValue

    this._hideInput()
    this._hideError()

    this.dispatch("cancel", {
      detail: { value: this.originalValue }
    })
  }

  // ==========================================================================
  // TURBO-COMPATIBLE SERVER SUBMISSION
  // ==========================================================================

  /**
   * Submit value to server using Turbo-compatible fetch
   * Handles both JSON and Turbo Stream responses
   */
  async _submitToServer(newValue) {
    this.isSaving = true
    this._showSaving()

    const csrfToken = this._getCSRFToken()

    // Build form data
    const formData = new FormData()
    formData.append(this.fieldValue, newValue)

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": csrfToken,
          // Turbo-compatible Accept header - prefer Turbo Streams
          "Accept": "text/vnd.turbo-stream.html, text/html, application/json"
        },
        body: formData
      })

      await this._handleResponse(response, newValue)
    } catch (error) {
      console.error("[Editable] Network error:", error)
      this._handleError("Network error. Please try again.")
    } finally {
      this.isSaving = false
      this._hideSaving()
    }
  }

  /**
   * Handle server response (Turbo Stream, JSON, or HTML)
   */
  async _handleResponse(response, newValue) {
    const contentType = response.headers.get("content-type") || ""

    if (response.ok) {
      // Success - update display
      this.currentValue = newValue
      this._updateDisplay(newValue)
      this._exitEditMode()
      this._showSuccess()

      // Handle Turbo Stream response if present
      if (contentType.includes("text/vnd.turbo-stream.html")) {
        const html = await response.text()
        // Use Turbo's built-in stream rendering
        if (window.Turbo) {
          Turbo.renderStreamMessage(html)
        }
      }

      // Dispatch success event
      this.dispatch("saved", {
        detail: { value: newValue }
      })
    } else {
      // Error response
      let errorMessage = "Failed to save"

      if (contentType.includes("application/json")) {
        const json = await response.json()
        errorMessage = json.error || json.errors?.join(", ") || errorMessage
      } else if (contentType.includes("text/vnd.turbo-stream.html")) {
        // Let Turbo handle error streams (e.g., validation messages)
        const html = await response.text()
        if (window.Turbo) {
          Turbo.renderStreamMessage(html)
        }
      }

      this._handleError(errorMessage)
    }
  }

  /**
   * Handle save error
   */
  _handleError(message) {
    this._showError(message)
    this.inputTarget.focus()

    this.dispatch("error", {
      detail: { message }
    })
  }

  // ==========================================================================
  // STATE MANAGEMENT
  // ==========================================================================

  /**
   * Update display text with new value
   */
  _updateDisplay(newValue) {
    if (newValue) {
      this.displayTarget.textContent = newValue
      this.element.classList.remove(...this.constructor.PLACEHOLDER_CLASSES)
    } else {
      this.displayTarget.textContent = this.placeholderValue
      this.element.classList.add(...this.constructor.PLACEHOLDER_CLASSES)
    }
  }

  /**
   * Exit edit mode after successful save
   */
  _exitEditMode() {
    this.isEditing = false
    this._hideInput()
    this._hideError()
  }

  // ==========================================================================
  // VISIBILITY HELPERS
  // ==========================================================================

  _showInput() {
    this.displayTarget.style.display = "none"
    if (this.hasIconTarget) this.iconTarget.style.display = "none"
    this.inputTarget.classList.remove("hidden")
  }

  _hideInput() {
    this.inputTarget.classList.add("hidden")
    this.inputTarget.style.width = "" // Reset width
    this.displayTarget.style.display = ""
    if (this.hasIconTarget) this.iconTarget.style.display = ""
  }

  _showSaving() {
    if (this.hasSavingTarget) {
      this.savingTarget.classList.remove("hidden")
    }
    this.element.classList.add(...this.constructor.SAVING_CLASSES)
  }

  _hideSaving() {
    if (this.hasSavingTarget) {
      this.savingTarget.classList.add("hidden")
    }
    this.element.classList.remove(...this.constructor.SAVING_CLASSES)
  }

  _showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message
      this.errorTarget.classList.remove("hidden")
    }
    this.element.classList.add(...this.constructor.ERROR_CLASSES)
  }

  _hideError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = ""
      this.errorTarget.classList.add("hidden")
    }
    this.element.classList.remove(...this.constructor.ERROR_CLASSES)
  }

  _showSuccess() {
    // Add transition for smooth fade
    this.element.classList.add(...this.constructor.TRANSITION_CLASSES)
    this.element.classList.add(...this.constructor.SUCCESS_CLASSES)

    // Fade out after 1.5 seconds
    setTimeout(() => {
      this.element.classList.remove(...this.constructor.SUCCESS_CLASSES)

      // Clean up transition classes after animation completes
      setTimeout(() => {
        this.element.classList.remove(...this.constructor.TRANSITION_CLASSES)
      }, 500)
    }, 1500)
  }

  // ==========================================================================
  // VALIDATION
  // ==========================================================================

  /**
   * Client-side validation
   * Returns error message or null if valid
   */
  _validate(value) {
    if (this.hasMaxlengthValue && value.length > this.maxlengthValue) {
      return `Maximum ${this.maxlengthValue} characters allowed`
    }

    if (this.hasMinlengthValue && value.length < this.minlengthValue) {
      return `Minimum ${this.minlengthValue} characters required`
    }

    if (this.inputTypeValue === "number") {
      const num = parseFloat(value)
      if (isNaN(num)) return "Please enter a valid number"
      if (this.hasMinValue && num < this.minValue) {
        return `Minimum value is ${this.minValue}`
      }
      if (this.hasMaxValue && num > this.maxValue) {
        return `Maximum value is ${this.maxValue}`
      }
    }

    return null
  }

  // ==========================================================================
  // UTILITIES
  // ==========================================================================

  /**
   * Get CSRF token from meta tag
   */
  _getCSRFToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }
}
