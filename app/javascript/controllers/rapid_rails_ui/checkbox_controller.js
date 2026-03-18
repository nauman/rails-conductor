import { Controller } from "@hotwired/stimulus"

/**
 * Checkbox Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles "Select All" functionality with indeterminate state support.
 *
 * Features:
 * - Select/deselect all checkboxes
 * - Indeterminate state when some (but not all) items are selected
 * - Automatically updates select all state when individual checkboxes change
 *
 * Targets:
 *   selectAll - The "Select All" checkbox
 *   item - Individual checkbox items
 *
 * Actions:
 *   toggleAll - Toggle all checkboxes when select all is clicked
 *   updateSelectAll - Update select all state when individual checkbox changes
 *
 * Note: Indeterminate styling via CSS :indeterminate pseudo-class.
 */
export default class extends Controller {
  static targets = ["selectAll", "item"]

  // Initialize - set initial select all state
  connect() {
    if (this.hasSelectAllTarget) {
      this.updateSelectAllState()
    }
  }

  // Toggle all checkboxes when select all is clicked
  toggleAll(event) {
    const checked = event.target.checked

    this.itemTargets.forEach((checkbox) => {
      if (!checkbox.disabled) {
        checkbox.checked = checked
      }
    })

    // Clear indeterminate state - CSS handles the visual via :indeterminate pseudo-class
    this.selectAllTarget.indeterminate = false
  }

  // Update select all state when individual checkbox changes
  updateSelectAll() {
    this.updateSelectAllState()
  }

  // Update select all checkbox state based on item checkboxes
  // CSS handles indeterminate styling via :indeterminate pseudo-class with background-image
  updateSelectAllState() {
    const total = this.itemTargets.length
    const checked = this.itemTargets.filter((cb) => cb.checked).length

    if (checked === 0) {
      // None checked
      this.selectAllTarget.checked = false
      this.selectAllTarget.indeterminate = false
    } else if (checked === total) {
      // All checked
      this.selectAllTarget.checked = true
      this.selectAllTarget.indeterminate = false
    } else {
      // Some checked (indeterminate) - CSS shows minus icon automatically
      this.selectAllTarget.checked = false
      this.selectAllTarget.indeterminate = true
    }
  }
}
