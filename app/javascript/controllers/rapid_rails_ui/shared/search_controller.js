import { Controller } from "@hotwired/stimulus"

/**
 * Search Filter Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A reusable controller for filtering lists with debounced search.
 * Hides/shows items based on text content matching the search term.
 *
 * Usage:
 *   <div data-controller="search"
 *        data-search-selector-value="[role='menuitem']"
 *        data-search-debounce-value="150">
 *     <input type="text" data-search-target="input" data-action="input->search#filter">
 *     <button role="menuitem">Apple</button>
 *     <button role="menuitem">Banana</button>
 *   </div>
 *
 * Can be composed with other controllers:
 *   <div data-controller="menu search" ...>
 *
 * Dispatches events:
 *   - search:filter - After filtering completes, with { term, visibleCount }
 */
export default class extends Controller {
  static targets = ["input"]

  static values = {
    selector: { type: String, default: '[role="menuitem"]' },
    debounce: { type: Number, default: 150 },
    attribute: { type: String, default: "" }
  }

  connect() {
    this._debounceTimeout = null
  }

  disconnect() {
    this._clearDebounce()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Filter items based on input value (debounced)
   */
  filter(event) {
    this._clearDebounce()

    this._debounceTimeout = setTimeout(() => {
      this._performFilter(event.target.value)
    }, this.debounceValue)
  }

  /**
   * Filter immediately without debounce
   */
  filterNow(event) {
    this._clearDebounce()
    this._performFilter(event.target.value)
  }

  /**
   * Clear search and show all items
   */
  clear() {
    this._clearDebounce()
    if (this.hasInputTarget) {
      this.inputTarget.value = ""
    }
    this._showAll()
  }

  // ==========================================================================
  // PRIVATE
  // ==========================================================================

  _performFilter(searchTerm) {
    const term = searchTerm.toLowerCase().trim()
    const items = this.element.querySelectorAll(this.selectorValue)
    let visibleCount = 0

    items.forEach(item => {
      const text = this._getSearchText(item)
      const wrapper = item.closest(".search-filterable") || item
      const matches = term === "" || text.includes(term)

      wrapper.style.display = matches ? "" : "none"
      if (matches) visibleCount++
    })

    this.dispatch("filter", {
      detail: { term: searchTerm, visibleCount, totalCount: items.length }
    })
  }

  _getSearchText(item) {
    // Use custom attribute if specified, otherwise use text content
    if (this.attributeValue) {
      return (item.getAttribute(this.attributeValue) || "").toLowerCase()
    }
    return item.textContent.toLowerCase()
  }

  _showAll() {
    const items = this.element.querySelectorAll(this.selectorValue)
    items.forEach(item => {
      const wrapper = item.closest(".search-filterable") || item
      wrapper.style.display = ""
    })

    this.dispatch("filter", {
      detail: { term: "", visibleCount: items.length, totalCount: items.length }
    })
  }

  _clearDebounce() {
    if (this._debounceTimeout) {
      clearTimeout(this._debounceTimeout)
      this._debounceTimeout = null
    }
  }
}
