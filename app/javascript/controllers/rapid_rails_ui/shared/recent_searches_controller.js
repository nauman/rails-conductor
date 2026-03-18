import { Controller } from "@hotwired/stimulus"

/**
 * Recent Searches Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Manages recent searches in localStorage with dropdown display.
 * Currently disabled - will be reimplemented with simplified approach.
 *
 * Future implementation will:
 * - Only save when user clicks a result link (not on typing)
 * - Store query + URL + title for direct navigation
 * - Show recent searches as clickable links to destinations
 */
export default class extends Controller {
  static targets = ["dropdown", "list", "clearButton", "input"]

  static values = {
    key: { type: String, default: "rui_recent_searches" },
    limit: { type: Number, default: 5 }
  }

  connect() {
    this.boundHideOnClickOutside = this.hideOnClickOutside.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHideOnClickOutside)
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  show(event) {
    if (event) event.preventDefault()

    const searches = this.getSearches()
    if (searches.length === 0) return

    this.renderList(searches)

    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.remove("hidden")
    }

    if (this.hasClearButtonTarget) {
      this.clearButtonTarget.classList.remove("hidden")
    }

    document.addEventListener("click", this.boundHideOnClickOutside)
    this.dispatch("shown")
  }

  showIfEmpty(event) {
    const input = event?.target || this.inputTarget
    if (input && input.value.trim() === "") {
      this.show()
    }
  }

  hide(event) {
    if (event) event.preventDefault()

    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.add("hidden")
    }

    document.removeEventListener("click", this.boundHideOnClickOutside)
    this.dispatch("hidden")
  }

  hideDelayed() {
    setTimeout(() => this.hide(), 150)
  }

  select(event) {
    if (event) event.preventDefault()

    const query = event.currentTarget.dataset.query
    if (!query) return

    this.hide()
    this.dispatch("selected", { detail: { query } })
  }

  clearAll(event) {
    if (event) event.preventDefault()

    try {
      localStorage.removeItem(this.keyValue)
    } catch (e) {
      console.warn("Failed to clear recent searches:", e)
    }

    this.hide()
    this.dispatch("cleared")
  }

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  getSearches() {
    try {
      const stored = localStorage.getItem(this.keyValue)
      return stored ? JSON.parse(stored) : []
    } catch (e) {
      return []
    }
  }

  saveSearch(query) {
    if (!query || !query.trim()) return

    try {
      let searches = this.getSearches()
      searches = searches.filter(s => s.toLowerCase() !== query.toLowerCase())
      searches.unshift(query.trim())
      searches = searches.slice(0, this.limitValue)
      localStorage.setItem(this.keyValue, JSON.stringify(searches))
    } catch (e) {
      console.warn("Failed to save recent search:", e)
    }
  }

  isVisible() {
    return this.hasDropdownTarget && !this.dropdownTarget.classList.contains("hidden")
  }

  // ==========================================================================
  // PRIVATE
  // ==========================================================================

  renderList(searches) {
    if (!this.hasListTarget) return

    this.listTarget.replaceChildren()

    const itemClass = "flex items-center gap-3 px-3 py-2 text-sm text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 cursor-pointer transition-colors"

    searches.forEach(query => {
      const item = document.createElement("div")
      item.className = itemClass
      item.dataset.query = query
      item.dataset.action = "click->recent-searches#select"
      item.setAttribute("role", "option")

      // Clock icon
      const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      icon.setAttribute("class", "w-4 h-4 text-zinc-400 shrink-0")
      icon.setAttribute("fill", "none")
      icon.setAttribute("viewBox", "0 0 24 24")
      icon.setAttribute("stroke", "currentColor")

      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
      path.setAttribute("stroke-linecap", "round")
      path.setAttribute("stroke-linejoin", "round")
      path.setAttribute("stroke-width", "2")
      path.setAttribute("d", "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z")
      icon.appendChild(path)

      const text = document.createElement("span")
      text.textContent = query

      item.appendChild(icon)
      item.appendChild(text)
      this.listTarget.appendChild(item)
    })
  }

  hideOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.hide()
    }
  }
}
