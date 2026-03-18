import { Controller } from "@hotwired/stimulus"

/**
 * Input Validation Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Provides real-time validation feedback for all input types.
 *
 * Features:
 * - Real-time validation on input and blur
 * - Visual feedback with border color changes
 * - Validation messages shown below input
 * - Password show/hide toggle
 * - Phone number formatting (North American)
 * - URL auto-formatting (adds https://)
 * - Uses HTML5 Constraint Validation API
 *
 * Targets:
 *   input - The input element
 *   message - Validation message element
 *   iconShow - Eye icon (password visible state)
 *   iconHide - Eye-off icon (password hidden state)
 */
// Actions:
//   validate - Validate input and show feedback
//   togglePassword - Toggle password visibility
//   formatPhoneNumber - Format phone as (XXX) XXX-XXXX
//   formatUrl - Auto-add https:// prefix
//
// Usage:
//   <div data-controller="input-validation">
//     <input data-input-validation-target="input"
//            data-action="input->input-validation#validate blur->input-validation#validate">
//     <p data-input-validation-target="message"></p>
//   </div>
export default class extends Controller {
  static targets = ["input", "message", "iconShow", "iconHide"]

  // CSS classes for visual feedback
  static classes = {
    valid: "border-green-500 dark:border-green-500 focus:ring-green-500",
    invalid: "border-red-500 dark:border-red-500 focus:ring-red-500",
    validText: "text-green-600 dark:text-green-400",
    invalidText: "text-red-600 dark:text-red-400"
  }

  connect() {
    // Don't validate on connect - wait for user interaction
    // This prevents showing errors before user has typed anything
  }

  // ============================================================================
  // VALIDATION
  // ============================================================================

  /**
   * Validate the input and update visual feedback
   * Called on input and blur events
   */
  validate() {
    if (!this.hasInputTarget || !this.hasMessageTarget) return

    const input = this.inputTarget
    const message = this.messageTarget

    // Don't validate empty optional fields
    if (!input.required && input.value === "") {
      this.clearValidation()
      return
    }

    // Don't validate until user has entered something
    if (input.value === "") {
      this.clearValidation()
      return
    }

    if (input.validity.valid) {
      this.showValid()
    } else {
      this.showInvalid(this.getErrorMessage(input))
    }
  }

  /**
   * Show valid state with specific field name
   */
  showValid() {
    const input = this.inputTarget
    const message = this.messageTarget

    // Update input border
    this.removeValidationClasses()
    input.classList.add("border-green-500", "dark:border-green-500")

    // Show success message with checkmark and specific field name
    const fieldName = this.getFieldName(input).toLowerCase()
    message.textContent = `✓ Valid ${fieldName}`
    message.className = "text-sm min-h-[1.25rem] text-green-600 dark:text-green-400"
  }

  /**
   * Show invalid state with error message
   * @param {string} errorMessage - The error message to display
   */
  showInvalid(errorMessage) {
    const input = this.inputTarget
    const message = this.messageTarget

    // Update input border
    this.removeValidationClasses()
    input.classList.add("border-red-500", "dark:border-red-500")

    // Show error message
    message.textContent = errorMessage
    message.className = "text-sm min-h-[1.25rem] text-red-600 dark:text-red-400"
  }

  /**
   * Clear validation state (neutral)
   */
  clearValidation() {
    const input = this.inputTarget
    const message = this.messageTarget

    this.removeValidationClasses()
    message.textContent = ""
    message.className = "text-sm min-h-[1.25rem]"
  }

  /**
   * Remove validation border classes
   */
  removeValidationClasses() {
    const input = this.inputTarget
    input.classList.remove(
      "border-green-500", "dark:border-green-500",
      "border-red-500", "dark:border-red-500"
    )
  }

  /**
   * Get user-friendly error message based on validity state
   * @param {HTMLInputElement} input - The input element
   * @returns {string} Error message
   */
  getErrorMessage(input) {
    const fieldName = this.getFieldName(input)

    if (input.validity.valueMissing) {
      return `${fieldName} is required`
    }

    if (input.validity.typeMismatch) {
      switch (input.type) {
        case "email":
          return "Please enter a valid email address (e.g., user@example.com)"
        case "url":
          return "Please enter a valid URL (e.g., https://example.com)"
        default:
          return `Please enter a valid ${fieldName.toLowerCase()}`
      }
    }

    if (input.validity.tooShort) {
      return `Must be at least ${input.minLength} characters`
    }

    if (input.validity.tooLong) {
      return `Must be no more than ${input.maxLength} characters`
    }

    if (input.validity.rangeUnderflow) {
      return `Value must be at least ${input.min}`
    }

    if (input.validity.rangeOverflow) {
      return `Value must be no more than ${input.max}`
    }

    if (input.validity.stepMismatch) {
      return `Value must be a multiple of ${input.step}`
    }

    if (input.validity.patternMismatch) {
      // Use title attribute if available for custom pattern message
      if (input.title) {
        return input.title
      }
      return `${fieldName} format is invalid`
    }

    if (input.validity.badInput) {
      return `Please enter a valid value`
    }

    if (input.validity.customError) {
      return input.validationMessage
    }

    return `Invalid ${fieldName.toLowerCase()}`
  }

  /**
   * Get human-readable field name from input
   * @param {HTMLInputElement} input - The input element
   * @returns {string} Field name
   */
  getFieldName(input) {
    // Try to get label text
    if (input.labels && input.labels.length > 0) {
      const labelText = input.labels[0].textContent.replace("*", "").trim()
      if (labelText) return labelText
    }

    // Try to get from name attribute
    if (input.name) {
      return input.name
        .replace(/\[|\]/g, " ")
        .replace(/_/g, " ")
        .trim()
        .replace(/\b\w/g, l => l.toUpperCase())
    }

    // Fallback based on type
    switch (input.type) {
      case "email": return "Email"
      case "password": return "Password"
      case "tel": return "Phone number"
      case "url": return "URL"
      case "number": return "Number"
      case "search": return "Search"
      default: return "This field"
    }
  }

  // ============================================================================
  // PASSWORD TOGGLE
  // ============================================================================

  /**
   * Toggle password visibility
   */
  togglePassword() {
    if (!this.hasInputTarget) return

    const input = this.inputTarget
    const isPassword = input.type === "password"

    // Toggle input type
    input.type = isPassword ? "text" : "password"

    // Toggle icon visibility
    if (this.hasIconShowTarget) {
      this.iconShowTarget.classList.toggle("hidden", isPassword)
    }
    if (this.hasIconHideTarget) {
      this.iconHideTarget.classList.toggle("hidden", !isPassword)
    }

    // Keep focus on input
    input.focus()
  }

  // ============================================================================
  // PHONE NUMBER FORMATTING
  // ============================================================================

  /**
   * Format phone number as (XXX) XXX-XXXX
   * Called on input event for tel type
   */
  formatPhoneNumber() {
    if (!this.hasInputTarget) return

    const input = this.inputTarget
    let value = input.value.replace(/\D/g, "")

    // Limit to 10 digits
    value = value.substring(0, 10)

    // Format as (XXX) XXX-XXXX
    if (value.length > 0) {
      if (value.length <= 3) {
        value = `(${value}`
      } else if (value.length <= 6) {
        value = `(${value.slice(0, 3)}) ${value.slice(3)}`
      } else {
        value = `(${value.slice(0, 3)}) ${value.slice(3, 6)}-${value.slice(6)}`
      }
    }

    input.value = value

    // Set custom validity for incomplete phone numbers
    if (value.length > 0 && value.length < 14) {
      input.setCustomValidity("Please enter a complete phone number")
    } else {
      input.setCustomValidity("")
    }

    this.validate()
  }

  // ============================================================================
  // URL FORMATTING
  // ============================================================================

  /**
   * Auto-add https:// prefix if missing
   * Called on blur event for url type
   */
  formatUrl() {
    if (!this.hasInputTarget) return

    const input = this.inputTarget
    let value = input.value.trim()

    if (!value) return

    // Add https:// if no protocol
    if (value && !value.match(/^https?:\/\//i)) {
      value = "https://" + value.replace(/^[\/\\]+/, "")
      input.value = value
    }

    // Validate URL format
    try {
      new URL(value)
      input.setCustomValidity("")
    } catch {
      input.setCustomValidity("Please enter a valid URL")
    }

    this.validate()
  }
}
