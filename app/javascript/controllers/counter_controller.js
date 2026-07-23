import { Controller } from "@hotwired/stimulus"

// Counts a number up from 0 to its target when it scrolls into view (easeOutCubic).
// Progressive enhancement: the final value is in the HTML, so without JS it just
// shows. Honors prefers-reduced-motion. Optional prefix/suffix (e.g. "%", "+").
export default class extends Controller {
  static values = {
    target: Number,
    duration: { type: Number, default: 1200 },
    prefix: { type: String, default: "" },
    suffix: { type: String, default: "" }
  }

  connect() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return this.#render(this.targetValue)

    this.#render(0)
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          this.observer.disconnect()
          this.#animate()
        }
      })
    }, { threshold: 0.6 })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    if (this.raf) cancelAnimationFrame(this.raf)
  }

  #animate() {
    const start = performance.now()
    const step = (now) => {
      const p = Math.min((now - start) / this.durationValue, 1)
      const eased = 1 - Math.pow(1 - p, 3)
      this.#render(Math.round(eased * this.targetValue))
      if (p < 1) this.raf = requestAnimationFrame(step)
    }
    this.raf = requestAnimationFrame(step)
  }

  #render(n) {
    this.element.textContent = `${this.prefixValue}${n}${this.suffixValue}`
  }
}
