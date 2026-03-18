import { Controller } from "@hotwired/stimulus"

/**
 * Alert Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles dismissible alerts with optional auto-dismiss countdown,
 * progress bar, and undo functionality.
 *
 * All behavior is declarative via data attributes:
 * - data-controller="alert"
 * - data-alert-auto-dismiss-value="true"
 * - data-alert-dismiss-after-value="5"
 * - data-action="mouseenter->alert#pause mouseleave->alert#resume"
 * - data-action="click->alert#dismiss" (on close button)
 * - data-action="click->alert#undo" (on undo button)
 * - data-action="click->alert#navigate" (on clickable alert)
 */
export default class extends Controller {
  static targets = ["countdown", "progressBar"]

  static values = {
    autoDismiss: { type: Boolean, default: false },
    dismissAfter: { type: Number, default: 5 },
    // Buffer seconds to subtract from displayed countdown (UX: under-promise)
    countdownBuffer: { type: Number, default: 2 },
    animate: { type: Boolean, default: true },
    href: { type: String, default: "" },
    turboFrame: { type: String, default: "" },
    undoUrl: { type: String, default: "" },
    undoMethod: { type: String, default: "post" }
  }

  static classes = ["entering", "leaving", "hidden"]

  connect() {
    this.isPaused = false
    // Original duration never changes - used for progress bar calculation
    this.originalDuration = this.dismissAfterValue * 1000
    this.remainingMs = this.originalDuration

    if (this.animateValue) {
      this.enter()
    }

    if (this.autoDismissValue) {
      this.startCountdown()
    }
  }

  disconnect() {
    this.clearCountdown()
  }

  // ============================================================================
  // ACTIONS (called via data-action)
  // ============================================================================

  /**
   * Dismiss the alert
   * Usage: data-action="click->alert#dismiss"
   */
  dismiss(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    this.clearCountdown()

    if (this.animateValue) {
      this.leave(() => this.remove())
    } else {
      this.remove()
    }
  }

  /**
   * Handle undo action
   * Usage: data-action="click->alert#undo"
   */
  undo(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    this.clearCountdown()

    if (this.undoUrlValue) {
      this.sendUndoRequest()
    }

    this.dispatch("undo")
    this.leave(() => this.remove())
  }

  /**
   * Navigate to href (for clickable alerts)
   * Usage: data-action="click->alert#navigate"
   */
  navigate(event) {
    // Don't navigate if clicking on interactive elements
    if (event.target.closest("button, a, [data-action*='dismiss'], [data-action*='undo']")) {
      return
    }

    if (!this.hrefValue) return

    event.preventDefault()

    if (this.turboFrameValue && typeof Turbo !== "undefined") {
      Turbo.visit(this.hrefValue, { frame: this.turboFrameValue })
    } else if (typeof Turbo !== "undefined") {
      Turbo.visit(this.hrefValue)
    } else {
      window.location.href = this.hrefValue
    }
  }

  /**
   * Pause countdown on hover
   * Usage: data-action="mouseenter->alert#pause"
   */
  pause() {
    if (!this.autoDismissValue || this.isPaused) return

    this.isPaused = true

    // Update remainingMs to reflect current position
    if (this.startTime) {
      const elapsed = Date.now() - this.startTime
      this.remainingMs = Math.max(0, this.remainingMs - elapsed)
    }

    this.clearCountdown()
  }

  /**
   * Resume countdown after hover
   * Usage: data-action="mouseleave->alert#resume"
   */
  resume() {
    if (!this.autoDismissValue || !this.isPaused || this.remainingMs <= 0) return

    this.isPaused = false
    this.startTime = Date.now()
    this.lastSecond = Math.ceil(this.remainingMs / 1000)

    this.updateCountdown(this.lastSecond)
    this.runLoop()
  }

  // ============================================================================
  // PRIVATE METHODS
  // ============================================================================

  /**
   * Enter animation using CSS classes
   */
  enter() {
    // Use CSS classes for animation if available, otherwise use inline
    if (this.hasEnteringClass) {
      this.element.classList.add(this.enteringClass)
      requestAnimationFrame(() => {
        this.element.classList.remove(this.enteringClass)
      })
    } else {
      // Fallback inline animation
      this.element.style.opacity = "0"
      this.element.style.transform = "translateY(-0.5rem)"
      requestAnimationFrame(() => {
        this.element.style.transition = "opacity 300ms ease-out, transform 300ms ease-out"
        this.element.style.opacity = "1"
        this.element.style.transform = "translateY(0)"
      })
    }
  }

  /**
   * Leave animation using CSS classes
   */
  leave(callback) {
    const duration = 200

    if (this.hasLeavingClass) {
      this.element.classList.add(this.leavingClass)
    } else {
      this.element.style.transition = `opacity ${duration}ms ease-in, transform ${duration}ms ease-in`
      this.element.style.opacity = "0"
      this.element.style.transform = "translateY(-0.5rem)"
    }

    setTimeout(callback, duration)
  }

  /**
   * Remove element from DOM
   */
  remove() {
    this.dispatch("dismissed")
    this.element.remove()
  }

  /**
   * Start the auto-dismiss countdown
   */
  startCountdown() {
    this.startTime = Date.now()
    this.lastSecond = Math.ceil(this.remainingMs / 1000)

    this.updateCountdown(this.lastSecond)
    this.updateProgress(1)

    this.runLoop()
  }

  /**
   * Single animation loop for synced countdown and progress
   */
  runLoop() {
    const tick = () => {
      if (this.isPaused || !this.startTime) return

      const elapsed = Date.now() - this.startTime
      const remaining = Math.max(0, this.remainingMs - elapsed)
      // Progress is based on original duration so bar continues from where it paused
      const progress = remaining / this.originalDuration
      const seconds = Math.ceil(remaining / 1000)

      this.updateProgress(progress)

      if (seconds !== this.lastSecond) {
        this.lastSecond = seconds
        this.updateCountdown(seconds)
      }

      if (remaining <= 0) {
        this.dismiss()
        return
      }

      this.animationFrame = requestAnimationFrame(tick)
    }

    this.animationFrame = requestAnimationFrame(tick)
  }

  /**
   * Update countdown target text (applies buffer for UX)
   */
  updateCountdown(seconds) {
    if (this.hasCountdownTarget) {
      // Apply buffer: show lower number than actual (under-promise, over-deliver)
      const displaySeconds = Math.max(0, seconds - this.countdownBufferValue)
      this.countdownTarget.textContent = displaySeconds
    }
  }

  /**
   * Update progress bar width
   */
  updateProgress(progress) {
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${progress * 100}%`
    }
  }

  /**
   * Clear animation frame
   */
  clearCountdown() {
    if (this.animationFrame) {
      cancelAnimationFrame(this.animationFrame)
      this.animationFrame = null
    }
    this.startTime = null
  }

  /**
   * Send undo request via fetch with Turbo Stream support
   */
  async sendUndoRequest() {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    try {
      const response = await fetch(this.undoUrlValue, {
        method: this.undoMethodValue.toUpperCase(),
        headers: {
          "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
          "X-CSRF-Token": csrfToken || "",
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })

      if (response.ok) {
        const contentType = response.headers.get("Content-Type") || ""
        if (contentType.includes("text/vnd.turbo-stream.html") && typeof Turbo !== "undefined") {
          const html = await response.text()
          Turbo.renderStreamMessage(html)
        }
      }
    } catch (error) {
      console.error("Undo request failed:", error)
    }
  }
}
