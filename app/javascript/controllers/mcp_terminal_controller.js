import { Controller } from "@hotwired/stimulus"

// A tabbed MCP terminal. Each tab is a scene (a short agent session) that types
// itself out line-by-line with a trailing cursor. Scene 0 auto-plays when the
// terminal scrolls into view; clicking a tab replays that scene. Progressive
// enhancement (all scenes render in HTML) + prefers-reduced-motion aware.
export default class extends Controller {
  static targets = ["tab", "scene", "cursor"]
  static values = { delay: { type: Number, default: 420 } }

  connect() {
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.timers = []
    this.#activate(0)

    if (this.reduced) return this.#reveal(0)

    this.#hide(0)
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          this.observer.disconnect()
          this.#play(0)
        }
      })
    }, { threshold: 0.3 })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.#clear()
  }

  select(event) {
    this.#play(Number(event.currentTarget.dataset.index))
  }

  // — internals —

  #clear() { this.timers.forEach(clearTimeout); this.timers = [] }

  #lines(i) { return Array.from(this.sceneTargets[i].querySelectorAll("[data-line]")) }

  #activate(i) {
    this.sceneTargets.forEach((s, idx) => (s.hidden = idx !== i))
    this.tabTargets.forEach((t, idx) => {
      const on = idx === i
      t.classList.toggle("bg-white/10", on)
      t.classList.toggle("text-white", on)
      t.classList.toggle("text-white/45", !on)
      t.setAttribute("aria-selected", String(on))
    })
  }

  #hide(i) {
    this.#lines(i).forEach((l) => {
      l.style.opacity = "0"
      l.style.transform = "translateY(3px)"
      l.style.transition = "opacity .26s ease, transform .26s ease"
    })
  }

  #reveal(i) {
    const lines = this.#lines(i)
    lines.forEach((l) => { l.style.opacity = "1"; l.style.transform = "none" })
    if (this.hasCursorTarget && lines.length) lines[lines.length - 1].appendChild(this.cursorTarget)
  }

  #play(i) {
    this.#clear()
    this.#activate(i)
    if (this.reduced) return this.#reveal(i)

    const lines = this.#lines(i)
    this.#hide(i)
    lines.forEach((line, idx) => {
      this.timers.push(setTimeout(() => {
        line.style.opacity = "1"
        line.style.transform = "translateY(0)"
        if (this.hasCursorTarget) line.appendChild(this.cursorTarget)
      }, idx * this.delayValue))
    })
  }
}
