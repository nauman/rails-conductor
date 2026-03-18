import { Controller } from "@hotwired/stimulus"

/**
 * Time Picker Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A scrollable time picker for selecting hours and minutes.
 * Respects step value for minute increments (e.g., step: 900 = 15 minutes).
 */
export default class extends Controller {
  static targets = [
    "input",           // Hidden input
    "trigger",         // Visible trigger input
    "dropdown",        // Dropdown container
    "optionsContainer" // Container for time options
  ]

  static values = {
    open: { type: Boolean, default: false },
    step: { type: Number, default: 60 },       // Step in seconds (default 1 minute)
    min: { type: String, default: "" },        // Min time HH:MM
    max: { type: String, default: "" },        // Max time HH:MM
    selectedTime: { type: String, default: "" },
    color: { type: String, default: "default" }
  }

  static classes = {
    option: "px-4 py-2 text-sm text-gray-900 hover:bg-gray-100 cursor-pointer",
    optionSelected: "bg-blue-100 text-blue-700 font-semibold"
  }

  connect() {
    this.clickOutsideHandler = this.handleClickOutside.bind(this)
    this.renderOptions()
  }

  disconnect() {
    document.removeEventListener("click", this.clickOutsideHandler)
  }

  toggle(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this.openValue = !this.openValue
  }

  close() {
    this.openValue = false
  }

  openValueChanged() {
    if (this.openValue) {
      this.showDropdown()
    } else {
      this.hideDropdown()
    }
  }

  showDropdown() {
    if (!this.hasDropdownTarget) return

    // Use native dialog .show() method for non-modal popup
    // This is semantically correct and accessible
    if (typeof this.dropdownTarget.show === "function") {
      this.dropdownTarget.show()
    } else {
      // Fallback for browsers without dialog support
      this.dropdownTarget.setAttribute("open", "")
    }

    // Scroll to selected time
    setTimeout(() => {
      this.scrollToSelected()
      document.addEventListener("click", this.clickOutsideHandler)
    }, 0)
  }

  hideDropdown() {
    if (!this.hasDropdownTarget) return

    // Use native dialog .close() method
    if (typeof this.dropdownTarget.close === "function") {
      this.dropdownTarget.close()
    } else {
      // Fallback for browsers without dialog support
      this.dropdownTarget.removeAttribute("open")
    }

    document.removeEventListener("click", this.clickOutsideHandler)
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  selectTime(event) {
    event?.preventDefault()
    event?.stopPropagation()

    const time = event.currentTarget.dataset.time
    if (!time) return

    this.selectedTimeValue = time
    this.updateInputs()
    this.renderOptions()
    this.close()

    this.dispatch("select", { detail: { time } })
  }

  updateInputs() {
    if (this.hasInputTarget) {
      this.inputTarget.value = this.selectedTimeValue
      this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }

    if (this.hasTriggerTarget) {
      this.triggerTarget.value = this.formatDisplayTime(this.selectedTimeValue)
    }
  }

  renderOptions() {
    if (!this.hasOptionsContainerTarget) return

    const stepMinutes = Math.max(1, Math.floor(this.stepValue / 60))
    const options = this.generateTimeOptions(stepMinutes)

    let html = ""
    options.forEach(time => {
      const isSelected = time === this.selectedTimeValue
      const displayTime = this.formatDisplayTime(time)
      const classes = isSelected
        ? "px-4 py-2 text-sm cursor-pointer bg-blue-100 text-blue-700 font-semibold hover:bg-blue-200"
        : "px-4 py-2 text-sm text-gray-900 hover:bg-gray-100 cursor-pointer"

      html += `
        <div
          class="${classes}"
          data-time="${time}"
          data-action="click->time-picker#selectTime"
          role="option"
          ${isSelected ? 'aria-selected="true"' : ""}
        >${displayTime}</div>
      `
    })

    this.optionsContainerTarget.innerHTML = html
  }

  generateTimeOptions(stepMinutes) {
    const options = []
    const minTime = this.parseTime(this.minValue) || { hours: 0, minutes: 0 }
    const maxTime = this.parseTime(this.maxValue) || { hours: 23, minutes: 59 }

    for (let hours = 0; hours < 24; hours++) {
      for (let minutes = 0; minutes < 60; minutes += stepMinutes) {
        const totalMinutes = hours * 60 + minutes
        const minTotalMinutes = minTime.hours * 60 + minTime.minutes
        const maxTotalMinutes = maxTime.hours * 60 + maxTime.minutes

        if (totalMinutes >= minTotalMinutes && totalMinutes <= maxTotalMinutes) {
          const h = String(hours).padStart(2, "0")
          const m = String(minutes).padStart(2, "0")
          options.push(`${h}:${m}`)
        }
      }
    }

    return options
  }

  parseTime(timeStr) {
    if (!timeStr) return null
    const [hours, minutes] = timeStr.split(":").map(Number)
    return { hours: hours || 0, minutes: minutes || 0 }
  }

  formatDisplayTime(time) {
    if (!time) return ""
    const [hours, minutes] = time.split(":").map(Number)
    const period = hours >= 12 ? "PM" : "AM"
    const displayHours = hours === 0 ? 12 : hours > 12 ? hours - 12 : hours
    return `${displayHours}:${String(minutes).padStart(2, "0")} ${period}`
  }

  scrollToSelected() {
    if (!this.hasOptionsContainerTarget || !this.selectedTimeValue) return

    const selectedOption = this.optionsContainerTarget.querySelector(`[data-time="${this.selectedTimeValue}"]`)
    if (selectedOption) {
      selectedOption.scrollIntoView({ block: "center", behavior: "instant" })
    }
  }
}
