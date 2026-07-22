import { Controller } from "@hotwired/stimulus"

// Fades + lifts an element into view as it scrolls in. Progressive enhancement:
// without JS the element is simply visible. Honors prefers-reduced-motion.
// Optional data-reveal-delay-value (ms) staggers grouped items.
export default class extends Controller {
  static values = { delay: { type: Number, default: 0 } }

  connect() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    this.element.style.opacity = "0"
    this.element.style.transform = "translateY(14px)"
    this.element.style.transition = "opacity .55s ease, transform .55s ease"
    this.element.style.transitionDelay = `${this.delayValue}ms`

    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.style.opacity = "1"
          e.target.style.transform = "none"
          this.observer.unobserve(e.target)
        }
      })
    }, { threshold: 0.12 })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
  }
}
