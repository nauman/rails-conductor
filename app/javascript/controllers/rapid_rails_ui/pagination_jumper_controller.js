import { Controller } from "@hotwired/stimulus"

/**
 * Pagination Jumper Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles go-to-page functionality for the Pagination component.
 * Supports both standard navigation and Turbo Frame integration.
 *
 * Usage:
 *   <div data-controller="rapid-rails-ui--pagination-jumper"
 *        data-rapid-rails-ui--pagination-jumper-base-url-value="/posts"
 *        data-rapid-rails-ui--pagination-jumper-page-param-value="page"
 *        data-rapid-rails-ui--pagination-jumper-total-pages-value="20">
 *     <input type="number" data-rapid-rails-ui--pagination-jumper-target="input" />
 *   </div>
 */
export default class extends Controller {
  static targets = ["input"]
  static values = {
    baseUrl: String,
    pageParam: { type: String, default: "page" },
    totalPages: Number
  }

  /**
   * Navigate to the page entered in the input
   */
  navigate(event) {
    // Prevent default form submission if applicable
    if (event.type === "keydown") {
      event.preventDefault()
    }

    const page = parseInt(this.inputTarget.value, 10)

    // Validate page number
    if (isNaN(page) || page < 1 || page > this.totalPagesValue) {
      // Reset to valid range
      this.inputTarget.value = Math.max(1, Math.min(page || 1, this.totalPagesValue))
      return
    }

    // Build the URL
    const url = this._buildUrl(page)

    // Check for Turbo Frame
    const turboFrame = this.element.dataset.turboFrame
    if (turboFrame) {
      // Use Turbo to visit the URL within the frame
      const frame = document.getElementById(turboFrame)
      if (frame) {
        frame.src = url
      } else {
        // Fallback to Turbo visit
        Turbo.visit(url)
      }
    } else {
      // Standard navigation
      window.location.href = url
    }
  }

  /**
   * Build the URL with the page parameter
   * @param {number} page - The page number
   * @returns {string} - The constructed URL
   */
  _buildUrl(page) {
    try {
      const url = new URL(this.baseUrlValue, window.location.origin)
      url.searchParams.set(this.pageParamValue, page.toString())
      return url.toString()
    } catch (e) {
      // Fallback for relative URLs
      const separator = this.baseUrlValue.includes("?") ? "&" : "?"
      return `${this.baseUrlValue}${separator}${this.pageParamValue}=${page}`
    }
  }
}
