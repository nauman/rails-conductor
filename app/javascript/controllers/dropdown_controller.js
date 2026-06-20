import { Controller } from "@hotwired/stimulus"

// Lightweight click-to-open dropdown that closes on outside-click or Escape.
// Usage:
//   <div data-controller="dropdown">
//     <button data-action="dropdown#toggle">…</button>
//     <div data-dropdown-target="menu" class="hidden">…</div>
//   </div>
export default class extends Controller {
  static targets = ["menu"]

  connect() {
    this._onDocClick = this.onDocClick.bind(this)
    this._onKey = this.onKey.bind(this)
  }

  disconnect() {
    this.unbind()
  }

  toggle(event) {
    event.preventDefault()
    this.menuTarget.classList.contains("hidden") ? this.open() : this.close()
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    document.addEventListener("click", this._onDocClick)
    document.addEventListener("keydown", this._onKey)
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.unbind()
  }

  unbind() {
    document.removeEventListener("click", this._onDocClick)
    document.removeEventListener("keydown", this._onKey)
  }

  onDocClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  onKey(event) {
    if (event.key === "Escape") this.close()
  }
}
