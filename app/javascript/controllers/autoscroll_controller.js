import { Controller } from "@hotwired/stimulus"

// Keeps the messages container scrolled to the bottom as new messages appear.
export default class extends Controller {
  connect() {
    this.#scrollToBottom()
    this.#observer = new MutationObserver(() => this.#scrollToBottom())
    this.#observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.#observer?.disconnect()
  }

  // Private

  #observer = null

  #scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight
  }
}
