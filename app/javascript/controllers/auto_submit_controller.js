import { Controller } from "@hotwired/stimulus"

// Submits the owning form when a control changes, so a select acts as its own
// save button. Progressive enhancement: the form still has a real submit button
// (hidden via CSS only when JS is present), so it works without Stimulus.
export default class extends Controller {
  connect() {
    this.element.classList.add("js-auto-submit")
  }

  submit() {
    this.element.requestSubmit()
  }
}
