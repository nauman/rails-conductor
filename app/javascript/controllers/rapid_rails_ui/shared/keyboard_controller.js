import { Controller } from "@hotwired/stimulus"

/**
 * Keyboard Navigation Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A reusable controller for keyboard navigation in menus, lists, and other
 * interactive elements. Handles arrow keys, escape, enter, and home/end.
 *
 * Usage:
 *   <div data-controller="keyboard"
 *        data-keyboard-selector-value="[role='menuitem']"
 *        data-keyboard-wrap-value="true">
 *     <button role="menuitem">Item 1</button>
 *     <button role="menuitem">Item 2</button>
 *   </div>
 *
 * Can be composed with other controllers:
 *   <div data-controller="menu keyboard" ...>
 *
 * Dispatches events for parent controllers to hook into:
 *   - keyboard:escape - Escape key pressed
 *   - keyboard:select - Enter/Space on focused item
 */
export default class extends Controller {
  static values = {
    selector: { type: String, default: '[role="menuitem"]:not([disabled])' },
    wrap: { type: Boolean, default: true },
    orientation: { type: String, default: "vertical" }
  }

  connect() {
    this.currentIndex = -1
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Navigate to next item (down arrow for vertical, right for horizontal)
   */
  next(event) {
    event.preventDefault()
    this._navigate(1)
  }

  /**
   * Navigate to previous item (up arrow for vertical, left for horizontal)
   */
  previous(event) {
    event.preventDefault()
    this._navigate(-1)
  }

  /**
   * Navigate to first item (Home key)
   */
  first(event) {
    event.preventDefault()
    const items = this._getItems()
    if (items.length > 0) {
      this.currentIndex = 0
      items[0].focus()
    }
  }

  /**
   * Navigate to last item (End key)
   */
  last(event) {
    event.preventDefault()
    const items = this._getItems()
    if (items.length > 0) {
      this.currentIndex = items.length - 1
      items[this.currentIndex].focus()
    }
  }

  /**
   * Handle escape key - dispatches event for parent to handle
   */
  escape(event) {
    event.preventDefault()
    this.dispatch("escape", { detail: { originalEvent: event } })
  }

  /**
   * Handle enter/space on focused item - dispatches event for parent
   */
  select(event) {
    const focused = document.activeElement
    if (focused && this.element.contains(focused)) {
      this.dispatch("select", { detail: { item: focused, originalEvent: event } })
    }
  }

  /**
   * Focus a specific item by index
   */
  focusIndex(index) {
    const items = this._getItems()
    if (index >= 0 && index < items.length) {
      this.currentIndex = index
      items[index].focus()
    }
  }

  /**
   * Focus first item (useful for menu open)
   */
  focusFirst() {
    this.focusIndex(0)
  }

  // ==========================================================================
  // PRIVATE
  // ==========================================================================

  _navigate(direction) {
    const items = this._getItems()
    if (items.length === 0) return

    // Find current focused item
    const currentFocused = document.activeElement
    const currentIdx = items.indexOf(currentFocused)

    let nextIndex
    if (currentIdx === -1) {
      // No item focused, start from beginning or end
      nextIndex = direction > 0 ? 0 : items.length - 1
    } else if (this.wrapValue) {
      // Wrap around
      nextIndex = (currentIdx + direction + items.length) % items.length
    } else {
      // No wrap - clamp to bounds
      nextIndex = Math.max(0, Math.min(items.length - 1, currentIdx + direction))
    }

    this.currentIndex = nextIndex
    items[nextIndex].focus()
  }

  _getItems() {
    return Array.from(this.element.querySelectorAll(this.selectorValue))
  }
}
