import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dockerFields"]

  // Lifecycle

  connect() {
    this.#toggle()
  }

  // Actions

  change() {
    this.#toggle()
  }

  // Private

  #toggle() {
    const selected = this.element.querySelector("input[name='app[deploy_method]']:checked")
    const isDocker = !selected || selected.value === "docker"

    this.dockerFieldsTargets.forEach(el => {
      el.style.display = isDocker ? "" : "none"
    })
  }
}
