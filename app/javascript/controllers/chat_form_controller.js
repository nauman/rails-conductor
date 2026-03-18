import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  // Submit on Enter, newline on Shift+Enter
  submitOnEnter(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.element.closest("form").requestSubmit()
    }
  }

  // Auto-resize textarea
  resize() {
    const input = this.inputTarget
    input.style.height = "auto"
    input.style.height = Math.min(input.scrollHeight, 160) + "px"
  }
}
