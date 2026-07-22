import { Controller } from "@hotwired/stimulus"

// Types a terminal out line-by-line when it scrolls into view, trailing a blinking
// cursor — so the MCP session on the landing page feels live. Progressive
// enhancement: the full transcript renders in HTML; we hide it on connect and
// reveal it in sequence. Honors prefers-reduced-motion (shows everything at once).
export default class extends Controller {
  static targets = ["line", "cursor"]
  static values = { delay: { type: Number, default: 460 } }

  connect() {
    this.timers = []
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (this.reduced) return this.#revealAll()

    this.lineTargets.forEach((l) => {
      l.style.opacity = "0"
      l.style.transform = "translateY(3px)"
      l.style.transition = "opacity .28s ease, transform .28s ease"
    })
    this.#observe()
  }

  disconnect() {
    this.observer?.disconnect()
    this.timers.forEach(clearTimeout)
  }

  // Play once, the first time it enters the viewport.
  #observe() {
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          this.observer.disconnect()
          this.#play()
        }
      })
    }, { threshold: 0.3 })
    this.observer.observe(this.element)
  }

  #play() {
    this.lineTargets.forEach((line, i) => {
      this.timers.push(setTimeout(() => this.#show(line), i * this.delayValue))
    })
  }

  #show(line) {
    line.style.opacity = "1"
    line.style.transform = "translateY(0)"
    if (this.hasCursorTarget) line.appendChild(this.cursorTarget) // cursor trails the newest line
  }

  #revealAll() {
    this.lineTargets.forEach((l) => { l.style.opacity = "1"; l.style.transform = "none" })
  }
}
