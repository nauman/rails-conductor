import { Controller } from "@hotwired/stimulus"

/**
 * CSS Highlight Navigation Controller
 * @gem rapid_rails_ui
 * @version 0.32.0
 * @updated 2026-01-27
 *
 * Reusable controller for CSS-based keyboard navigation in lists.
 * Adds/removes CSS classes to highlight items while keeping DOM focus
 * elsewhere (e.g., on a search input).
 *
 * Best for:
 * - Search autocomplete results (user keeps typing while browsing)
 * - Recent searches dropdown
 * - Any list where user types while browsing options
 *
 * Usage:
 *   <div data-controller="css-highlight-nav"
 *        data-css-highlight-nav-selector-value="[data-navigable]"
 *        data-css-highlight-nav-wrap-value="true">
 *     <div data-css-highlight-nav-target="container">
 *       <a href="#" data-navigable>Item 1</a>
 *       <a href="#" data-navigable>Item 2</a>
 *     </div>
 *   </div>
 *
 * Can be composed with other controllers:
 *   <div data-controller="live-search css-highlight-nav"
 *        data-action="keydown.down->css-highlight-nav#next
 *                     keydown.up->css-highlight-nav#prev
 *                     keydown.enter->css-highlight-nav#select
 *                     css-highlight-nav:selected->live-search#onResultSelected">
 *
 * Events dispatched:
 *   - css-highlight-nav:changed - { index, element } when highlight changes
 *   - css-highlight-nav:selected - { element } when item selected (clicked)
 *   - css-highlight-nav:cleared - when highlight cleared
 */
export default class extends Controller {
  static targets = ["container"]

  static values = {
    selector: { type: String, default: "[data-navigable]" },
    wrap: { type: Boolean, default: true },
    highlightClass: { type: String, default: "rui-highlight" },
    bgClass: { type: String, default: "bg-zinc-100" },
    darkBgClass: { type: String, default: "dark:bg-zinc-800" }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this.currentIndex = -1
  }

  disconnect() {
    this.clear()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Navigate to next item (down arrow)
   */
  next(event) {
    if (event) event.preventDefault()
    this.navigate(1)
  }

  /**
   * Navigate to previous item (up arrow)
   */
  prev(event) {
    if (event) event.preventDefault()
    this.navigate(-1)
  }

  /**
   * Navigate to first item (Home key)
   */
  first(event) {
    if (event) event.preventDefault()
    const items = this.getItems()
    if (items.length > 0) {
      this.highlightIndex(0)
    }
  }

  /**
   * Navigate to last item (End key)
   */
  last(event) {
    if (event) event.preventDefault()
    const items = this.getItems()
    if (items.length > 0) {
      this.highlightIndex(items.length - 1)
    }
  }

  /**
   * Select (click) the currently highlighted item
   * If the highlighted element is a container, find and click the first link or button inside
   */
  select(event) {
    if (event) event.preventDefault()

    const items = this.getItems()
    if (this.currentIndex >= 0 && this.currentIndex < items.length) {
      const element = items[this.currentIndex]
      const clickable = this._findClickableElement(element)
      if (clickable) {
        clickable.click()
        this.dispatch("selected", { detail: { element: clickable } })
      }
    } else if (items.length > 0) {
      // No highlight - select first item
      const clickable = this._findClickableElement(items[0])
      if (clickable) {
        clickable.click()
        this.dispatch("selected", { detail: { element: clickable } })
      }
    }
  }

  /**
   * Clear current highlight
   */
  clear(event) {
    if (event) event.preventDefault()

    const items = this.getItems()
    if (this.currentIndex >= 0 && this.currentIndex < items.length) {
      this.removeHighlightClasses(items[this.currentIndex])
    }
    this.currentIndex = -1
    this.dispatch("cleared")
  }

  /**
   * Reset navigation (clear and reset index)
   * Call this when the list content changes (e.g., new search results)
   */
  reset(event) {
    if (event) event.preventDefault()
    this.clear()
  }

  // ==========================================================================
  // PUBLIC API (for programmatic use)
  // ==========================================================================

  /**
   * Check if any item is currently highlighted
   * @returns {boolean}
   */
  hasHighlight() {
    return this.currentIndex >= 0
  }

  /**
   * Get the currently highlighted element
   * @returns {Element|null}
   */
  getHighlighted() {
    const items = this.getItems()
    if (this.currentIndex >= 0 && this.currentIndex < items.length) {
      return items[this.currentIndex]
    }
    return null
  }

  /**
   * Get current highlight index
   * @returns {number} -1 if none highlighted
   */
  getIndex() {
    return this.currentIndex
  }

  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================

  /**
   * Navigate by direction
   * @param {number} direction - 1 for next, -1 for previous
   */
  navigate(direction) {
    const items = this.getItems()
    if (items.length === 0) return

    // Clear previous highlight
    if (this.currentIndex >= 0 && this.currentIndex < items.length) {
      this.removeHighlightClasses(items[this.currentIndex])
    }

    // Calculate new index
    if (this.currentIndex < 0) {
      // No current selection - start at beginning or end
      this.currentIndex = direction > 0 ? 0 : items.length - 1
    } else {
      this.currentIndex += direction

      // Handle wrapping
      if (this.wrapValue) {
        if (this.currentIndex < 0) this.currentIndex = items.length - 1
        if (this.currentIndex >= items.length) this.currentIndex = 0
      } else {
        // Clamp to bounds
        if (this.currentIndex < 0) this.currentIndex = 0
        if (this.currentIndex >= items.length) this.currentIndex = items.length - 1
      }
    }

    // Apply highlight
    this.highlightIndex(this.currentIndex)
  }

  /**
   * Highlight item at specific index
   * @param {number} index
   */
  highlightIndex(index) {
    const items = this.getItems()
    if (index < 0 || index >= items.length) return

    // Clear previous
    if (this.currentIndex >= 0 && this.currentIndex < items.length && this.currentIndex !== index) {
      this.removeHighlightClasses(items[this.currentIndex])
    }

    this.currentIndex = index
    const element = items[index]

    this.addHighlightClasses(element)
    this.scrollIntoViewIfNeeded(element)

    this.dispatch("changed", { detail: { index, element } })
  }

  /**
   * Get all navigable items from the first visible container
   * Supports multiple container targets - navigates the first visible one with items
   * @returns {Element[]}
   */
  getItems() {
    if (!this.hasContainerTarget) return []

    // Check all container targets, return items from first visible one with content
    for (const container of this.containerTargets) {
      // Skip if container is actually hidden (check computed style, not just class)
      if (this.isElementHidden(container)) continue

      const items = Array.from(container.querySelectorAll(this.selectorValue))
        .filter(el => !el.hidden && !el.classList.contains("hidden"))

      if (items.length > 0) return items
    }

    return []
  }

  /**
   * Check if element is actually hidden (using computed style)
   * Handles cases like dialog[open] with "hidden" class but "open:flex" override
   * @param {Element} element
   * @returns {boolean}
   */
  isElementHidden(element) {
    if (!element) return true

    // Check the element itself
    const style = window.getComputedStyle(element)
    if (style.display === "none" || style.visibility === "hidden") return true

    // Walk up the DOM to check ancestors
    let parent = element.parentElement
    while (parent && parent !== document.body) {
      const parentStyle = window.getComputedStyle(parent)
      if (parentStyle.display === "none" || parentStyle.visibility === "hidden") return true
      parent = parent.parentElement
    }

    return false
  }

  /**
   * Add highlight classes to element
   * @param {Element} element
   */
  addHighlightClasses(element) {
    if (!element) return
    element.classList.add(this.highlightClassValue, this.bgClassValue, this.darkBgClassValue)
  }

  /**
   * Remove highlight classes from element
   * @param {Element} element
   */
  removeHighlightClasses(element) {
    if (!element) return
    element.classList.remove(this.highlightClassValue, this.bgClassValue, this.darkBgClassValue)
  }

  /**
   * Scroll element into view if needed
   * @param {Element} element
   */
  scrollIntoViewIfNeeded(element) {
    if (!element) return
    element.scrollIntoView({ block: "nearest", behavior: "smooth" })
  }

  /**
   * Find a clickable element - either the element itself or the first clickable child
   * Used for cases where data-navigable is on a container div with a link inside
   * @param {Element} element
   * @returns {Element|null} The clickable element (link or button)
   * @private
   */
  _findClickableElement(element) {
    if (!element) return null

    // If element itself is a link or button, return it
    if (element.tagName === 'A' || element.tagName === 'BUTTON') {
      return element
    }

    // Otherwise find the first clickable child (link or button)
    return element.querySelector('a[href], button')
  }
}
