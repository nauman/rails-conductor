import { Controller } from "@hotwired/stimulus"

/**
 * Dialog Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A minimal Stimulus controller for native HTML <dialog> element.
 * Leverages browser-native behavior for focus trapping, Escape key, and accessibility.
 *
 * Native <dialog> handles:
 * - Focus trapping with showModal()
 * - Escape key to close (fires 'cancel' event)
 * - Backdrop via ::backdrop pseudo-element
 * - ARIA attributes (role="dialog", aria-modal="true")
 * - Inertness of background content
 *
 * This controller adds:
 * - Backdrop click to close (not native)
 * - Turbo Frame integration (auto-open on load, auto-close on success)
 * - Custom events for lifecycle hooks
 * - Animation coordination
 *
 * Usage:
 *   <div data-controller="dialog"
 *        data-dialog-dismissible-value="true"
 *        data-dialog-position-value="center">
 *     <dialog data-dialog-target="dialog">
 *       Content here
 *     </dialog>
 *   </div>
 *
 * Actions:
 *   data-action="dialog#open"      - Opens the dialog
 *   data-action="dialog#close"     - Closes the dialog
 *   data-action="dialog#toggle"    - Toggles open/close
 *
 * Turbo Integration:
 *   data-action="turbo:frame-load->dialog#frameLoad"
 *   data-action="turbo:submit-end->dialog#submitEnd"
 */
export default class extends Controller {
  static targets = ["dialog", "blurBackdrop"]

  static values = {
    dismissible: { type: Boolean, default: true },
    position: { type: String, default: "center" },
    staticBackdrop: { type: Boolean, default: false },
    autofocus: { type: String, default: "" },
    // Responsive behavior values
    responsive: { type: Boolean, default: false },
    breakpoint: { type: Number, default: 768 },
    mobilePosition: { type: String, default: "bottom" }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    if (!this.hasDialogTarget) {
      console.warn("[Dialog] No dialog target found")
      return
    }

    // Bind event handlers
    this._boundHandleClose = this._handleClose.bind(this)
    this._boundHandleCancel = this._handleCancel.bind(this)
    this._boundHandleClick = this._handleClick.bind(this)

    // Listen for native dialog events
    this.dialogTarget.addEventListener("close", this._boundHandleClose)
    this.dialogTarget.addEventListener("cancel", this._boundHandleCancel)
    this.dialogTarget.addEventListener("click", this._boundHandleClick)

    // Setup responsive behavior if enabled
    if (this.responsiveValue) {
      this._setupResponsiveHandling()
    }

    // Note: Auto-open only happens via frameLoad action (Turbo Frame)
    // Static dialogs should be opened explicitly via showModal() or open action
  }

  disconnect() {
    if (!this.hasDialogTarget) return

    this.dialogTarget.removeEventListener("close", this._boundHandleClose)
    this.dialogTarget.removeEventListener("cancel", this._boundHandleCancel)
    this.dialogTarget.removeEventListener("click", this._boundHandleClick)

    // Cleanup responsive listener
    if (this._mediaQuery) {
      this._mediaQuery.removeEventListener("change", this._boundMediaChange)
    }
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Open the dialog as a modal
   * Uses native showModal() for focus trapping and inertness
   */
  open() {
    if (!this.hasDialogTarget || this.dialogTarget.open) return

    // Add opening animation class
    this.dialogTarget.classList.add("dialog-opening")

    // Show custom blur backdrop if present
    this._showBlurBackdrop()

    // Show as modal (native focus trap, Esc handling, backdrop)
    this.dialogTarget.showModal()

    // Handle autofocus
    this._handleAutofocus()

    // Remove animation class after animation completes
    requestAnimationFrame(() => {
      this.dialogTarget.classList.remove("dialog-opening")
    })

    // Dispatch custom event
    this._dispatch("open")
  }

  /**
   * Close the dialog
   * Optionally pass a return value for form handling
   */
  close(event) {
    if (!this.hasDialogTarget || !this.dialogTarget.open) return

    // Get return value if closing from a button with value
    const returnValue = event?.target?.value || ""

    // Close with optional return value
    this.dialogTarget.close(returnValue)
  }

  /**
   * Toggle dialog open/close state
   */
  toggle() {
    if (this.dialogTarget.open) {
      this.close()
    } else {
      this.open()
    }
  }

  // ==========================================================================
  // TURBO INTEGRATION
  // ==========================================================================

  /**
   * Called when Turbo Frame loads content
   * Opens the dialog if content was loaded
   */
  frameLoad(event) {
    // Only open if the frame now has content
    if (this._hasContent()) {
      this.open()
    }
  }

  /**
   * Called after Turbo form submission completes
   * Closes dialog on success, keeps open on failure (validation errors)
   */
  submitEnd(event) {
    if (event.detail.success) {
      this.close()
    }
    // On failure (status: :unprocessable_entity), dialog stays open
    // for user to see and fix validation errors
  }

  // ==========================================================================
  // PRIVATE HANDLERS
  // ==========================================================================

  /**
   * Handle native 'close' event
   * Fires when dialog closes (via close() method or form submission)
   */
  _handleClose(event) {
    // Hide custom blur backdrop if present
    this._hideBlurBackdrop()

    this._dispatch("closed", {
      returnValue: this.dialogTarget.returnValue
    })
  }

  /**
   * Handle native 'cancel' event
   * Fires when user presses Escape key
   */
  _handleCancel(event) {
    // If static backdrop is enabled, prevent Escape from closing
    if (this.staticBackdropValue) {
      event.preventDefault()
      // Optional: add shake animation to indicate dialog won't close
      this._shakeDialog()
      return
    }

    // Allow default behavior (close dialog)
    this._dispatch("cancel")
  }

  /**
   * Handle click events on dialog element
   * Implements backdrop click to close (not native behavior)
   */
  _handleClick(event) {
    // Only handle clicks directly on the dialog element (backdrop area)
    // Clicks on content inside dialog won't trigger this
    if (event.target !== this.dialogTarget) return

    // Check if dismissible
    if (!this.dismissibleValue) {
      // Optional: shake to indicate dialog won't close
      this._shakeDialog()
      return
    }

    // Close on backdrop click
    this.close()
    this._dispatch("backdropClick")
  }

  /**
   * Handle click on custom blur backdrop
   * Called via data-action on the blur backdrop div
   */
  backdropClick(event) {
    // Prevent clicks from bubbling
    event.stopPropagation()

    // Check if dismissible
    if (!this.dismissibleValue) {
      this._shakeDialog()
      return
    }

    // Close on backdrop click
    this.close()
    this._dispatch("backdropClick")
  }

  // ==========================================================================
  // PRIVATE HELPERS
  // ==========================================================================

  /**
   * Check if dialog has actual content (not just empty frame)
   */
  _hasContent() {
    if (!this.hasDialogTarget) return false

    // Check if there's visible content inside the dialog
    const content = this.dialogTarget.innerHTML.trim()
    // Empty Turbo frames have minimal content
    return content.length > 50
  }

  /**
   * Handle autofocus on open
   */
  _handleAutofocus() {
    if (this.autofocusValue) {
      // Focus specific element if selector provided
      const target = this.dialogTarget.querySelector(this.autofocusValue)
      if (target) {
        requestAnimationFrame(() => target.focus())
        return
      }
    }

    // Default: native dialog behavior focuses first focusable element
    // or element with autofocus attribute
  }

  /**
   * Show custom blur backdrop
   */
  _showBlurBackdrop() {
    if (this.hasBlurBackdropTarget) {
      this.blurBackdropTarget.classList.remove("hidden")
    }
  }

  /**
   * Hide custom blur backdrop
   */
  _hideBlurBackdrop() {
    if (this.hasBlurBackdropTarget) {
      this.blurBackdropTarget.classList.add("hidden")
    }
  }

  /**
   * Shake animation for static backdrop feedback
   */
  _shakeDialog() {
    this.dialogTarget.classList.add("dialog-shake")
    this.dialogTarget.addEventListener("animationend", () => {
      this.dialogTarget.classList.remove("dialog-shake")
    }, { once: true })
  }

  /**
   * Dispatch custom event
   */
  _dispatch(name, detail = {}) {
    const event = new CustomEvent(`dialog:${name}`, {
      bubbles: true,
      cancelable: true,
      detail: {
        dialog: this.dialogTarget,
        ...detail
      }
    })
    this.element.dispatchEvent(event)
  }

  // ==========================================================================
  // RESPONSIVE HANDLING
  // ==========================================================================

  /**
   * Setup responsive viewport detection using matchMedia
   * CSS handles the visual transformation; this enables event dispatching
   */
  _setupResponsiveHandling() {
    const query = `(min-width: ${this.breakpointValue}px)`
    this._mediaQuery = window.matchMedia(query)

    // Store current mode (true = desktop, false = mobile)
    this._isDesktopMode = this._mediaQuery.matches

    // Listen for viewport changes
    this._boundMediaChange = this._handleMediaChange.bind(this)
    this._mediaQuery.addEventListener("change", this._boundMediaChange)
  }

  /**
   * Handle viewport size changes
   * Dispatches event so external code can react to mode changes
   */
  _handleMediaChange(event) {
    const wasDesktop = this._isDesktopMode
    this._isDesktopMode = event.matches

    // Only dispatch if mode actually changed
    if (wasDesktop !== this._isDesktopMode) {
      this._dispatch("responsive", {
        isDesktop: this._isDesktopMode,
        position: this._isDesktopMode ? this.positionValue : this.mobilePositionValue
      })
    }
  }

  /**
   * Get the effective position based on current viewport
   * Useful for external code that needs to know current position
   */
  get effectivePosition() {
    if (!this.responsiveValue) {
      return this.positionValue
    }
    return this._isDesktopMode ? this.positionValue : this.mobilePositionValue
  }
}
