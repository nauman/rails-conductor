import { Controller } from "@hotwired/stimulus"

/**
 * Textarea Validation Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Provides real-time validation, character counting, and auto-resize for textarea elements.
 *
 * Features:
 * - Real-time validation on input and blur
 * - Visual feedback with border color changes
 * - Validation messages shown below textarea
 * - Character counter with maxlength enforcement
 * - Auto-resize with min/max row constraints
 * - Uses HTML5 Constraint Validation API
 *
 * Targets:
 * - textarea: The textarea element
 * - message: Validation message element
 * - counter: Character counter element
 *
 * Values:
 * - autoResize: Boolean - Enable auto-resize
 * - minRows: Number - Minimum rows (from rows attribute)
 * - maxRows: Number - Maximum rows (optional)
 * - maxlength: Number - Maximum character length
 *
 * Actions:
 * - validate: Validate textarea and show feedback
 * - updateCounter: Update character count
 * - autoResize: Resize textarea based on content
 */
export default class extends Controller {
  static targets = ["textarea", "message", "counter"]
  static values = {
    autoResize: { type: Boolean, default: false },
    minRows: { type: Number, default: 4 },
    maxRows: Number,
    maxlength: Number
  }

  connect() {
    // Initialize auto-resize if enabled
    if (this.autoResizeValue && this.hasTextareaTarget) {
      this.autoResize()
    }

    // Initialize character counter if present
    if (this.hasCounterTarget && this.hasTextareaTarget) {
      this.updateCounter()
    }
  }

  // ============================================================================
  // VALIDATION
  // ============================================================================

  /**
   * Validate the textarea and update visual feedback
   */
  validate() {
    if (!this.hasTextareaTarget || !this.hasMessageTarget) return

    const textarea = this.textareaTarget
    const message = this.messageTarget

    // Don't validate empty optional fields
    if (!textarea.required && textarea.value === "") {
      this.clearValidation()
      return
    }

    // Don't validate until user has entered something
    if (textarea.value === "") {
      this.clearValidation()
      return
    }

    if (textarea.validity.valid) {
      this.showValid()
    } else {
      this.showInvalid(this.getErrorMessage(textarea))
    }
  }

  /**
   * Show valid state
   */
  showValid() {
    const textarea = this.textareaTarget
    const message = this.messageTarget

    // Update textarea border
    this.removeValidationClasses()
    textarea.classList.add("border-green-500", "dark:border-green-500")

    // Show success message
    const fieldName = this.getFieldName(textarea).toLowerCase()
    message.textContent = `✓ Valid ${fieldName}`
    message.className = "text-sm min-h-[1.25rem] text-green-600 dark:text-green-400"
  }

  /**
   * Show invalid state with error message
   */
  showInvalid(errorMessage) {
    const textarea = this.textareaTarget
    const message = this.messageTarget

    // Update textarea border
    this.removeValidationClasses()
    textarea.classList.add("border-red-500", "dark:border-red-500")

    // Show error message
    message.textContent = errorMessage
    message.className = "text-sm min-h-[1.25rem] text-red-600 dark:text-red-400"
  }

  /**
   * Clear validation state
   */
  clearValidation() {
    const textarea = this.textareaTarget
    const message = this.messageTarget

    this.removeValidationClasses()
    message.textContent = ""
    message.className = "text-sm min-h-[1.25rem]"
  }

  /**
   * Remove validation border classes
   */
  removeValidationClasses() {
    const textarea = this.textareaTarget
    textarea.classList.remove(
      "border-green-500", "dark:border-green-500",
      "border-red-500", "dark:border-red-500"
    )
  }

  /**
   * Get error message based on validity state
   */
  getErrorMessage(textarea) {
    const fieldName = this.getFieldName(textarea)

    if (textarea.validity.valueMissing) {
      return `${fieldName} is required`
    }

    if (textarea.validity.tooShort) {
      return `Must be at least ${textarea.minLength} characters`
    }

    if (textarea.validity.tooLong) {
      return `Must be no more than ${textarea.maxLength} characters`
    }

    if (textarea.validity.customError) {
      return textarea.validationMessage
    }

    return `Invalid ${fieldName.toLowerCase()}`
  }

  /**
   * Get human-readable field name
   */
  getFieldName(textarea) {
    // Try to get label text
    if (textarea.labels && textarea.labels.length > 0) {
      const labelText = textarea.labels[0].textContent.replace("*", "").trim()
      if (labelText) return labelText
    }

    // Try to get from name attribute
    if (textarea.name) {
      return textarea.name
        .replace(/\[|\]/g, " ")
        .replace(/_/g, " ")
        .trim()
        .replace(/\b\w/g, l => l.toUpperCase())
    }

    return "This field"
  }

  // ============================================================================
  // CHARACTER COUNTER
  // ============================================================================

  /**
   * Update character counter
   */
  updateCounter() {
    if (!this.hasCounterTarget || !this.hasTextareaTarget) return

    const textarea = this.textareaTarget
    const counter = this.counterTarget
    const currentLength = textarea.value.length

    // Build counter text
    let counterText
    if (this.hasMaxlengthValue) {
      counterText = `${currentLength} / ${this.maxlengthValue} characters`
    } else {
      counterText = `${currentLength} characters`
    }

    counter.textContent = counterText

    // Update styling if over limit
    if (this.hasMaxlengthValue && currentLength > this.maxlengthValue) {
      counter.className = "text-xs text-red-600 dark:text-red-400 font-medium"
    } else {
      counter.className = "text-xs text-zinc-500 dark:text-zinc-400"
    }
  }

  // ============================================================================
  // AUTO-RESIZE
  // ============================================================================

  /**
   * Auto-resize textarea based on content
   */
  autoResize() {
    if (!this.autoResizeValue || !this.hasTextareaTarget) return

    const textarea = this.textareaTarget

    // Reset height to auto to get accurate scrollHeight
    textarea.style.height = "auto"

    // Get computed styles
    const computed = window.getComputedStyle(textarea)
    const lineHeight = parseFloat(computed.lineHeight)
    const paddingTop = parseFloat(computed.paddingTop)
    const paddingBottom = parseFloat(computed.paddingBottom)
    const borderTop = parseFloat(computed.borderTopWidth)
    const borderBottom = parseFloat(computed.borderBottomWidth)

    // Calculate heights
    const contentHeight = textarea.scrollHeight
    const minHeight = (lineHeight * this.minRowsValue) + paddingTop + paddingBottom + borderTop + borderBottom
    const maxHeight = this.hasMaxRowsValue
      ? (lineHeight * this.maxRowsValue) + paddingTop + paddingBottom + borderTop + borderBottom
      : Infinity

    // Clamp between min and max
    const newHeight = Math.max(minHeight, Math.min(contentHeight, maxHeight))

    // Set new height
    textarea.style.height = `${newHeight}px`

    // Add scrollbar if content exceeds max height
    if (contentHeight > maxHeight) {
      textarea.style.overflowY = "auto"
    } else {
      textarea.style.overflowY = "hidden"
    }
  }
}
