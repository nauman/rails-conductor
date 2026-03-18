import { Controller } from "@hotwired/stimulus"

/**
 * Date Picker Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A beautiful, full-featured date picker with range support.
 * Inspired by Flowbite and FluxUI design patterns.
 *
 * Features:
 * - Single date selection
 * - Date range selection with visual highlighting
 * - Multiple months display
 * - Preset buttons (Today, Last 7 days, etc.)
 * - Min/max date constraints
 * - Unavailable dates
 * - Month/year picker views
 * - Keyboard navigation
 * - Beautiful dark mode support
 */
export default class extends Controller {
  static targets = [
    "input",          // Single date hidden input
    "startInput",     // Range start hidden input
    "endInput",       // Range end hidden input
    "trigger",        // Visible input trigger
    "dropdown",       // Calendar dropdown
    "calendarsContainer", // Container for calendar month(s)
    "presetsPanel",   // Presets panel
    "timeContainer",  // Time picker container (for datetime)
    "timeTrigger",    // Time picker trigger button
    "timeDropdown",   // Time picker dropdown list
    "timeOptionsContainer" // Container for time options
  ]

  static values = {
    open: { type: Boolean, default: false },
    range: { type: Boolean, default: false },
    months: { type: Number, default: 1 },
    startDay: { type: Number, default: 0 },
    min: { type: String, default: "" },
    max: { type: String, default: "" },
    unavailable: { type: Array, default: [] },
    selectedDate: { type: String, default: "" },
    startDate: { type: String, default: "" },
    endDate: { type: String, default: "" },
    viewDate: { type: String, default: "" },
    selectingEnd: { type: Boolean, default: false },
    hoverDate: { type: String, default: "" },
    view: { type: String, default: "days" }, // days, months, years
    presets: { type: Object, default: {} },
    color: { type: String, default: "default" },
    colorClasses: { type: Object, default: {} }, // Dynamic color classes from server
    // Time picker for datetime type
    showTime: { type: Boolean, default: false },
    selectedTime: { type: String, default: "" },
    timeStep: { type: Number, default: 60 },
    timeOpen: { type: Boolean, default: false }
  }

  // Color-specific classes for selection states
  // NOTE: Semantic colors have explicit entries. Tailwind colors use fallback to default.
  // The server-side colorClassesValue should provide the correct colors for ALL colors.
  // This static map is only a fallback for tests and edge cases.
  static colorClasses = {
    default: {
      selected: "bg-zinc-700 text-white hover:bg-zinc-600",
      rangeStart: "bg-zinc-700 text-white",
      rangeEnd: "bg-zinc-700 text-white",
      inRange: "bg-zinc-100 text-zinc-700",
      today: "text-zinc-600 bg-gray-100"
    },
    // Semantic colors (map to Tailwind colors via ColorBuilderHelper)
    primary: {
      selected: "bg-zinc-700 text-white hover:bg-zinc-600",
      rangeStart: "bg-zinc-700 text-white",
      rangeEnd: "bg-zinc-700 text-white",
      inRange: "bg-zinc-100 text-zinc-700",
      today: "text-zinc-600 bg-gray-100"
    },
    success: {
      selected: "bg-green-600 text-white hover:bg-green-500",
      rangeStart: "bg-green-600 text-white",
      rangeEnd: "bg-green-600 text-white",
      inRange: "bg-green-100 text-green-700",
      today: "text-green-600 bg-gray-100"
    },
    warning: {
      selected: "bg-yellow-500 text-white hover:bg-yellow-400",
      rangeStart: "bg-yellow-500 text-white",
      rangeEnd: "bg-yellow-500 text-white",
      inRange: "bg-yellow-100 text-yellow-700",
      today: "text-yellow-600 bg-gray-100"
    },
    danger: {
      selected: "bg-red-600 text-white hover:bg-red-500",
      rangeStart: "bg-red-600 text-white",
      rangeEnd: "bg-red-600 text-white",
      inRange: "bg-red-100 text-red-700",
      today: "text-red-600 bg-gray-100"
    },
    info: {
      selected: "bg-cyan-600 text-white hover:bg-cyan-500",
      rangeStart: "bg-cyan-600 text-white",
      rangeEnd: "bg-cyan-600 text-white",
      inRange: "bg-cyan-100 text-cyan-700",
      today: "text-cyan-600 bg-gray-100"
    },
    // Tailwind colors - for fallback when server doesn't provide colorClassesValue
    // NOTE: These MUST match what the server generates in Date::Styles.build_day_selected_classes
    zinc: {
      selected: "bg-zinc-700 text-white hover:bg-zinc-600",
      rangeStart: "bg-zinc-700 text-white",
      rangeEnd: "bg-zinc-700 text-white",
      inRange: "bg-zinc-100 text-zinc-700",
      today: "text-zinc-600 bg-gray-100"
    },
    red: {
      selected: "bg-red-600 text-white hover:bg-red-500",
      rangeStart: "bg-red-600 text-white",
      rangeEnd: "bg-red-600 text-white",
      inRange: "bg-red-100 text-red-700",
      today: "text-red-600 bg-gray-100"
    },
    orange: {
      selected: "bg-orange-600 text-white hover:bg-orange-500",
      rangeStart: "bg-orange-600 text-white",
      rangeEnd: "bg-orange-600 text-white",
      inRange: "bg-orange-100 text-orange-700",
      today: "text-orange-600 bg-gray-100"
    },
    yellow: {
      selected: "bg-yellow-500 text-white hover:bg-yellow-400",
      rangeStart: "bg-yellow-500 text-white",
      rangeEnd: "bg-yellow-500 text-white",
      inRange: "bg-yellow-100 text-yellow-700",
      today: "text-yellow-600 bg-gray-100"
    },
    green: {
      selected: "bg-green-600 text-white hover:bg-green-500",
      rangeStart: "bg-green-600 text-white",
      rangeEnd: "bg-green-600 text-white",
      inRange: "bg-green-100 text-green-700",
      today: "text-green-600 bg-gray-100"
    },
    blue: {
      selected: "bg-blue-600 text-white hover:bg-blue-500",
      rangeStart: "bg-blue-600 text-white",
      rangeEnd: "bg-blue-600 text-white",
      inRange: "bg-blue-100 text-blue-700",
      today: "text-blue-600 bg-gray-100"
    },
    purple: {
      selected: "bg-purple-600 text-white hover:bg-purple-500",
      rangeStart: "bg-purple-600 text-white",
      rangeEnd: "bg-purple-600 text-white",
      inRange: "bg-purple-100 text-purple-700",
      today: "text-purple-600 bg-gray-100"
    },
    pink: {
      selected: "bg-pink-600 text-white hover:bg-pink-500",
      rangeStart: "bg-pink-600 text-white",
      rangeEnd: "bg-pink-600 text-white",
      inRange: "bg-pink-100 text-pink-700",
      today: "text-pink-600 bg-gray-100"
    }
  }

  // Weekday names
  static dayNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
  static dayNamesFull = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

  // Month names
  static monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
  ]
  static monthNamesShort = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  ]

  // CSS Classes - Flowbite design (always light mode for calendar popup)
  // Reference: https://flowbite.com/docs/components/datepicker/
  // Calendar popup is always white/light - no dark mode variants
  static classes = {
    // Header with month/year and navigation
    calendarHeader: "flex items-center justify-between mb-4",
    navButton: "p-2.5 rounded-lg bg-white text-gray-500 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-gray-200",
    monthYear: "text-sm font-semibold text-gray-900 px-5 py-2.5 rounded-lg bg-white hover:bg-gray-100 focus:outline-none focus:ring-2 focus:ring-gray-200 cursor-pointer",

    // Weekday header row - matches day cell width
    weekdayHeader: "grid grid-cols-7 gap-1 mb-2",
    weekdayCell: "w-10 h-6 text-center text-xs font-medium text-gray-500 leading-6",

    // Days grid - fixed width for consistent sizing with comfortable spacing
    daysGrid: "grid grid-cols-7 gap-1",

    // Day cells - Fixed size w-10 h-10 (40px × 40px) for better touch targets and visibility
    dayBase: "w-10 h-10 cursor-pointer rounded-lg border-0 text-center text-sm font-semibold leading-10 hover:bg-gray-100",
    dayDefault: "text-gray-900",
    // Note: dayToday, daySelected, dayRangeStart, dayRangeEnd, dayInRange are now color-dependent
    // and use colorClasses[color].today, colorClasses[color].selected, etc.
    dayRangeStartShape: "rounded-l-lg rounded-r-none",
    dayRangeEndShape: "rounded-r-lg rounded-l-none",
    dayInRangeShape: "rounded-none",
    dayOutside: "text-gray-400",
    dayDisabled: "text-gray-400 cursor-not-allowed line-through",

    // Month picker grid
    monthGrid: "grid grid-cols-3 gap-2 p-2",
    monthCell: "px-2 py-2 text-sm font-medium text-gray-900 rounded-lg cursor-pointer hover:bg-gray-100 text-center",
    monthCellCurrent: "text-zinc-600 bg-gray-100",
    monthCellSelected: "bg-zinc-700 text-white hover:bg-zinc-600",

    // Year picker grid
    yearGrid: "grid grid-cols-4 gap-2 p-2",
    yearCell: "px-2 py-2 text-sm font-medium text-gray-900 rounded-lg cursor-pointer hover:bg-gray-100 text-center",
    yearCellCurrent: "text-zinc-600 bg-gray-100",
    yearCellSelected: "bg-zinc-700 text-white hover:bg-zinc-600",

    // Preset buttons
    presetActive: "bg-zinc-100 text-zinc-700 font-semibold",

    // Time picker (for datetime type) - matches standalone time picker styling
    timeContainer: "border-t border-gray-200 mt-4 pt-4",
    timeLabel: "text-sm font-medium text-gray-900 mb-2",
    timeDropdownWrapper: "relative",
    timeTrigger: "w-full px-3 py-2 text-sm bg-gray-50 border border-gray-300 rounded-lg focus:ring-zinc-500 focus:border-zinc-500 cursor-pointer text-left",
    timeDropdown: "absolute z-50 mt-1 w-full bg-white border border-gray-200 rounded-lg shadow-lg max-h-60 overflow-y-auto",
    timeOption: "px-4 py-2 text-sm text-gray-900 hover:bg-gray-100 cursor-pointer",
    timeOptionSelected: "px-4 py-2 text-sm cursor-pointer bg-zinc-100 text-zinc-700 font-semibold hover:bg-zinc-200"
  }

  connect() {
    // Initialize view date
    if (!this.viewDateValue) {
      if (this.rangeValue && this.startDateValue) {
        this.viewDateValue = this.startDateValue
      } else if (this.selectedDateValue) {
        this.viewDateValue = this.selectedDateValue
      } else {
        this.viewDateValue = this.formatDate(new Date())
      }
    }

    // Bind handlers
    this.clickOutsideHandler = this.handleClickOutside.bind(this)
    this.keydownHandler = this.handleKeydown.bind(this)

    // Render initial calendar
    this.renderCalendars()
  }

  disconnect() {
    document.removeEventListener("click", this.clickOutsideHandler)
    document.removeEventListener("keydown", this.keydownHandler)
  }

  // ============================================================================
  // ACTIONS
  // ============================================================================

  toggle(event) {
    event?.preventDefault()
    event?.stopPropagation()

    // Prevent double-toggle from focus + click
    if (this._justOpened) {
      this._justOpened = false
      return
    }

    this.openValue = !this.openValue

    if (this.openValue) {
      this._justOpened = true
      setTimeout(() => { this._justOpened = false }, 100)
    }
  }

  open(event) {
    event?.stopPropagation()
    if (!this.openValue) {
      this.openValue = true
    }
  }

  close() {
    this.openValue = false
  }

  selectDay(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const dateStr = event.currentTarget.dataset.date
    if (!dateStr || event.currentTarget.dataset.disabled === "true") return

    if (this.rangeValue) {
      this.handleRangeSelection(dateStr)
    } else {
      this.selectedDateValue = dateStr
      this.updateInputs()
      this.close()
    }

    this.renderCalendars()
    this.dispatch("select", { detail: this.getSelectionDetail() })
  }

  handleRangeSelection(dateStr) {
    if (!this.selectingEndValue || !this.startDateValue) {
      // Start new selection
      this.startDateValue = dateStr
      this.endDateValue = ""
      this.selectingEndValue = true
    } else {
      // Complete selection
      const startDate = this.parseDate(this.startDateValue)
      const clickedDate = this.parseDate(dateStr)

      if (clickedDate < startDate) {
        // Clicked date is before start, swap
        this.endDateValue = this.startDateValue
        this.startDateValue = dateStr
      } else {
        this.endDateValue = dateStr
      }

      this.selectingEndValue = false
      this.updateInputs()
      this.close()
    }
  }

  prevMonth(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const date = this.parseDate(this.viewDateValue)
    date.setMonth(date.getMonth() - 1)
    this.viewDateValue = this.formatDate(date)
    this.renderCalendars()
  }

  nextMonth(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const date = this.parseDate(this.viewDateValue)
    date.setMonth(date.getMonth() + 1)
    this.viewDateValue = this.formatDate(date)
    this.renderCalendars()
  }

  showMonthPicker(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this.viewValue = "months"
    this.renderCalendars()
  }

  showYearPicker(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this.viewValue = "years"
    this.renderCalendars()
  }

  selectMonth(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const month = parseInt(event.currentTarget.dataset.month, 10)
    const date = this.parseDate(this.viewDateValue)
    date.setMonth(month)
    this.viewDateValue = this.formatDate(date)
    this.viewValue = "days"
    this.renderCalendars()
  }

  selectYear(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const year = parseInt(event.currentTarget.dataset.year, 10)
    const date = this.parseDate(this.viewDateValue)
    date.setFullYear(year)
    this.viewDateValue = this.formatDate(date)
    this.viewValue = "months"
    this.renderCalendars()
  }

  goToToday(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const today = this.formatDate(new Date())
    this.viewDateValue = today

    if (!this.rangeValue) {
      this.selectedDateValue = today
      this.updateInputs()
    }

    this.renderCalendars()
    this.dispatch("today")
  }

  clear(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this.selectedDateValue = ""
    this.startDateValue = ""
    this.endDateValue = ""
    this.selectingEndValue = false
    this.updateInputs()
    this.renderCalendars()
    this.dispatch("clear")
  }

  selectPreset(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const startDate = event.currentTarget.dataset.presetStart
    const endDate = event.currentTarget.dataset.presetEnd

    if (this.rangeValue) {
      this.startDateValue = startDate
      this.endDateValue = endDate
      this.selectingEndValue = false
    } else {
      this.selectedDateValue = startDate
    }

    this.viewDateValue = startDate
    this.updateInputs()
    this.renderCalendars()
    // Don't close - let user try different presets, close on click outside
    this.dispatch("preset", { detail: { start: startDate, end: endDate } })
  }

  handleDayHover(event) {
    if (!this.rangeValue || !this.selectingEndValue) return

    const dateStr = event.currentTarget.dataset.date
    if (dateStr && this.hoverDateValue !== dateStr) {
      this.hoverDateValue = dateStr
      this.renderCalendars()
    }
  }

  // ============================================================================
  // VALUE CHANGED CALLBACKS
  // ============================================================================

  openValueChanged() {
    if (this.openValue) {
      this.showDropdown()
    } else {
      this.hideDropdown()
    }
  }

  // ============================================================================
  // PRIVATE METHODS
  // ============================================================================

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

    this.viewValue = "days"
    this.renderCalendars()

    setTimeout(() => {
      document.addEventListener("click", this.clickOutsideHandler)
      document.addEventListener("keydown", this.keydownHandler)
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

    this.hoverDateValue = ""
    this.selectingEndValue = this.rangeValue && this.startDateValue && !this.endDateValue
    this.timeOpenValue = false // Reset time dropdown state

    document.removeEventListener("click", this.clickOutsideHandler)
    document.removeEventListener("keydown", this.keydownHandler)
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    } else if (this.timeOpenValue && this.hasTimeDropdownTarget) {
      // Close time dropdown if clicking outside of it but inside the main element
      const timeContainer = this.hasTimeContainerTarget ? this.timeContainerTarget : null
      if (timeContainer && !timeContainer.contains(event.target)) {
        this.timeOpenValue = false
        this.updateTimeDropdown()
      }
    }
  }

  handleKeydown(event) {
    switch (event.key) {
      case "Escape":
        event.preventDefault()
        this.close()
        this.triggerTarget?.focus()
        break
      case "ArrowLeft":
        if (event.altKey) {
          event.preventDefault()
          this.prevMonth()
        }
        break
      case "ArrowRight":
        if (event.altKey) {
          event.preventDefault()
          this.nextMonth()
        }
        break
    }
  }

  updateInputs() {
    if (this.rangeValue) {
      if (this.hasStartInputTarget) {
        this.startInputTarget.value = this.startDateValue
        this.startInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
      }
      if (this.hasEndInputTarget) {
        this.endInputTarget.value = this.endDateValue
        this.endInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
      }
    } else {
      if (this.hasInputTarget) {
        // For datetime, combine date + time into YYYY-MM-DDTHH:MM format
        if (this.showTimeValue) {
          const dateStr = this.selectedDateValue
          const timeStr = this.selectedTimeValue || "00:00"
          this.inputTarget.value = dateStr ? `${dateStr}T${timeStr}` : ""
        } else {
          this.inputTarget.value = this.selectedDateValue
        }
        this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
      }
    }

    this.updateTriggerDisplay()
  }

  updateTriggerDisplay() {
    if (!this.hasTriggerTarget) return

    if (this.rangeValue) {
      if (this.startDateValue && this.endDateValue) {
        this.triggerTarget.value = `${this.formatDisplayDate(this.startDateValue)} to ${this.formatDisplayDate(this.endDateValue)}`
      } else if (this.startDateValue) {
        this.triggerTarget.value = this.formatDisplayDate(this.startDateValue)
      } else {
        this.triggerTarget.value = ""
      }
    } else if (this.showTimeValue) {
      // DateTime: show date + time
      if (this.selectedDateValue) {
        const dateDisplay = this.formatDisplayDate(this.selectedDateValue)
        const timeDisplay = this.selectedTimeValue ? this.formatDisplayTime(this.selectedTimeValue) : ""
        this.triggerTarget.value = timeDisplay ? `${dateDisplay} ${timeDisplay}` : dateDisplay
      } else {
        this.triggerTarget.value = ""
      }
    } else {
      this.triggerTarget.value = this.selectedDateValue ? this.formatDisplayDate(this.selectedDateValue) : ""
    }
  }

  getSelectionDetail() {
    if (this.rangeValue) {
      return { start: this.startDateValue, end: this.endDateValue }
    }
    return { date: this.selectedDateValue }
  }

  // ============================================================================
  // RENDERING
  // ============================================================================

  renderCalendars() {
    if (!this.hasCalendarsContainerTarget) return

    switch (this.viewValue) {
      case "months":
        this.renderMonthPicker()
        break
      case "years":
        this.renderYearPicker()
        break
      default:
        this.renderDaysView()
    }
  }

  renderDaysView() {
    const viewDate = this.parseDate(this.viewDateValue)
    let html = ""

    for (let i = 0; i < this.monthsValue; i++) {
      const monthDate = new Date(viewDate.getFullYear(), viewDate.getMonth() + i, 1)
      html += this.renderMonthCalendar(monthDate, i === 0, i === this.monthsValue - 1)
    }

    // Add time picker if showTime is enabled (datetime type)
    if (this.showTimeValue && !this.rangeValue) {
      html += this.renderTimePicker()
    }

    this.calendarsContainerTarget.innerHTML = html
  }

  renderTimePicker() {
    const cls = this.constructor.classes
    const stepMinutes = Math.max(1, Math.floor(this.timeStepValue / 60))
    const options = this.generateTimeOptions(stepMinutes)

    const displayTime = this.selectedTimeValue
      ? this.formatDisplayTime(this.selectedTimeValue)
      : "Select time"

    let optionsHtml = options.map(time => {
      const isSelected = time === this.selectedTimeValue
      const optionClass = isSelected ? cls.timeOptionSelected : cls.timeOption
      return `
        <div
          class="${optionClass}"
          data-time="${time}"
          data-action="click->date-picker#selectTimeOption"
          role="option"
          ${isSelected ? 'aria-selected="true"' : ""}
        >${this.formatDisplayTime(time)}</div>
      `
    }).join("")

    return `
      <div class="${cls.timeContainer}" data-date-picker-target="timeContainer">
        <label class="${cls.timeLabel}">Time</label>
        <div class="${cls.timeDropdownWrapper}">
          <button
            type="button"
            class="${cls.timeTrigger}"
            data-action="click->date-picker#toggleTimePicker"
            data-date-picker-target="timeTrigger"
            aria-haspopup="listbox"
            aria-expanded="${this.timeOpenValue}"
          >
            ${displayTime}
          </button>
          <div
            class="${cls.timeDropdown} ${this.timeOpenValue ? "" : "hidden"}"
            data-date-picker-target="timeDropdown"
            role="listbox"
            aria-label="Choose time"
          >
            <div data-date-picker-target="timeOptionsContainer">
              ${optionsHtml}
            </div>
          </div>
        </div>
      </div>
    `
  }

  generateTimeOptions(stepMinutes) {
    const options = []
    for (let hours = 0; hours < 24; hours++) {
      for (let minutes = 0; minutes < 60; minutes += stepMinutes) {
        const h = String(hours).padStart(2, "0")
        const m = String(minutes).padStart(2, "0")
        options.push(`${h}:${m}`)
      }
    }
    return options
  }

  // Time picker actions for datetime type
  toggleTimePicker(event) {
    event?.preventDefault()
    event?.stopPropagation()
    this.timeOpenValue = !this.timeOpenValue
    this.updateTimeDropdown()
  }

  selectTimeOption(event) {
    event?.preventDefault()
    event?.stopPropagation()

    const time = event.currentTarget.dataset.time
    if (!time) return

    this.selectedTimeValue = time
    this.timeOpenValue = false
    this.updateInputs()
    this.renderCalendars() // Re-render to update time picker display
  }

  updateTimeDropdown() {
    if (!this.hasTimeDropdownTarget) return

    if (this.timeOpenValue) {
      this.timeDropdownTarget.classList.remove("hidden")
      // Scroll to selected time
      setTimeout(() => this.scrollToSelectedTime(), 0)
    } else {
      this.timeDropdownTarget.classList.add("hidden")
    }
  }

  scrollToSelectedTime() {
    if (!this.hasTimeOptionsContainerTarget || !this.selectedTimeValue) return

    const selectedOption = this.timeOptionsContainerTarget.querySelector(`[data-time="${this.selectedTimeValue}"]`)
    if (selectedOption) {
      selectedOption.scrollIntoView({ block: "center", behavior: "instant" })
    }
  }

  formatDisplayTime(time) {
    if (!time) return ""
    const [hours, minutes] = time.split(":").map(Number)
    const period = hours >= 12 ? "PM" : "AM"
    const displayHours = hours === 0 ? 12 : hours > 12 ? hours - 12 : hours
    return `${displayHours}:${String(minutes).padStart(2, "0")} ${period}`
  }

  renderMonthCalendar(date, showPrev, showNext) {
    const year = date.getFullYear()
    const month = date.getMonth()

    return `
      <div class="calendar-month">
        ${this.renderCalendarHeader(year, month, showPrev, showNext)}
        ${this.renderWeekdayHeader()}
        ${this.renderDaysGrid(year, month)}
      </div>
    `
  }

  renderCalendarHeader(year, month, showPrev, showNext) {
    const cls = this.constructor.classes
    const monthName = this.constructor.monthNames[month]

    return `
      <div class="${cls.calendarHeader}">
        ${showPrev ? `
          <button type="button" class="${cls.navButton}" data-action="click->date-picker#prevMonth" aria-label="Previous month">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
            </svg>
          </button>
        ` : '<div class="w-9"></div>'}
        <button type="button" class="${cls.monthYear}" data-action="click->date-picker#showMonthPicker">
          ${monthName} ${year}
        </button>
        ${showNext ? `
          <button type="button" class="${cls.navButton}" data-action="click->date-picker#nextMonth" aria-label="Next month">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
            </svg>
          </button>
        ` : '<div class="w-9"></div>'}
      </div>
    `
  }

  renderWeekdayHeader() {
    const cls = this.constructor.classes
    const dayNames = this.constructor.dayNames
    const reorderedDays = [...dayNames.slice(this.startDayValue), ...dayNames.slice(0, this.startDayValue)]

    return `
      <div class="${cls.weekdayHeader}">
        ${reorderedDays.map(day => `<div class="${cls.weekdayCell}">${day}</div>`).join("")}
      </div>
    `
  }

  renderDaysGrid(year, month) {
    const cls = this.constructor.classes
    const firstDay = new Date(year, month, 1)
    const lastDay = new Date(year, month + 1, 0)
    let startDayOfWeek = firstDay.getDay() - this.startDayValue
    if (startDayOfWeek < 0) startDayOfWeek += 7
    const totalDays = lastDay.getDate()
    const prevMonthLastDay = new Date(year, month, 0).getDate()

    let html = `<div class="${cls.daysGrid}">`

    // Previous month padding
    for (let i = startDayOfWeek - 1; i >= 0; i--) {
      const day = prevMonthLastDay - i
      const date = new Date(year, month - 1, day)
      html += this.renderDayCell(date, true)
    }

    // Current month days
    for (let day = 1; day <= totalDays; day++) {
      const date = new Date(year, month, day)
      html += this.renderDayCell(date, false)
    }

    // Next month padding
    const totalCells = startDayOfWeek + totalDays
    const remainingCells = (7 - (totalCells % 7)) % 7
    for (let day = 1; day <= remainingCells; day++) {
      const date = new Date(year, month + 1, day)
      html += this.renderDayCell(date, true)
    }

    html += "</div>"
    return html
  }

  renderDayCell(date, isOtherMonth) {
    const cls = this.constructor.classes
    // Use dynamic color classes from server if available, otherwise fall back to static ones
    const colorCls = (this.colorClassesValue && Object.keys(this.colorClassesValue).length > 0)
      ? this.colorClassesValue
      : (this.constructor.colorClasses[this.colorValue] || this.constructor.colorClasses.default)
    const dateStr = this.formatDate(date)
    const today = this.formatDate(new Date())
    const isToday = dateStr === today
    const isDisabled = this.isDateDisabled(date)

    // Determine selection state
    let isSelected = false
    let isRangeStart = false
    let isRangeEnd = false
    let isInRange = false

    if (this.rangeValue) {
      isRangeStart = dateStr === this.startDateValue
      isRangeEnd = dateStr === this.endDateValue

      // Check if in range
      if (this.startDateValue && (this.endDateValue || this.hoverDateValue)) {
        const start = this.parseDate(this.startDateValue)
        const end = this.endDateValue ?
          this.parseDate(this.endDateValue) :
          this.parseDate(this.hoverDateValue)

        if (end >= start) {
          const dateTime = date.getTime()
          isInRange = dateTime > start.getTime() && dateTime < end.getTime()
        }
      }
    } else {
      isSelected = dateStr === this.selectedDateValue
    }

    // Build classes - use color-specific classes for selection states
    let classes = cls.dayBase

    if (isDisabled) {
      classes += " " + cls.dayDisabled
    } else if (isRangeStart && isRangeEnd) {
      // Single day range
      classes += " " + colorCls.selected
    } else if (isRangeStart) {
      classes += " " + colorCls.rangeStart + " " + cls.dayRangeStartShape
    } else if (isRangeEnd) {
      classes += " " + colorCls.rangeEnd + " " + cls.dayRangeEndShape
    } else if (isSelected) {
      classes += " " + colorCls.selected
    } else if (isInRange) {
      classes += " " + colorCls.inRange + " " + cls.dayInRangeShape
    } else if (isOtherMonth) {
      classes += " " + cls.dayOutside
    } else if (isToday) {
      classes += " " + colorCls.today + " font-bold"
    } else {
      classes += " " + cls.dayDefault
    }

    const hoverAction = this.rangeValue ? 'mouseenter->date-picker#handleDayHover' : ''

    return `
      <button type="button"
        class="${classes}"
        data-date="${dateStr}"
        data-disabled="${isDisabled}"
        data-action="click->date-picker#selectDay ${hoverAction}"
        ${isDisabled ? "disabled" : ""}
        aria-label="${this.formatAccessibleDate(date)}"
        ${isSelected || isRangeStart || isRangeEnd ? 'aria-selected="true"' : ""}
        tabindex="${isDisabled ? -1 : 0}"
      >${date.getDate()}</button>
    `
  }

  renderMonthPicker() {
    const cls = this.constructor.classes
    const viewDate = this.parseDate(this.viewDateValue)
    const currentYear = viewDate.getFullYear()
    const currentMonth = viewDate.getMonth()
    const todayMonth = new Date().getMonth()
    const todayYear = new Date().getFullYear()

    let html = `
      <div class="calendar-month">
        <div class="${cls.calendarHeader}">
          <button type="button" class="${cls.navButton}" data-action="click->date-picker#prevYear" aria-label="Previous year">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
            </svg>
          </button>
          <button type="button" class="${cls.monthYear}" data-action="click->date-picker#showYearPicker">
            ${currentYear}
          </button>
          <button type="button" class="${cls.navButton}" data-action="click->date-picker#nextYear" aria-label="Next year">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
            </svg>
          </button>
        </div>
        <div class="${cls.monthGrid}">
    `

    this.constructor.monthNamesShort.forEach((month, index) => {
      const isCurrent = index === todayMonth && currentYear === todayYear
      const isSelected = index === currentMonth

      let cellClass = cls.monthCell
      if (isSelected) {
        cellClass += " " + cls.monthCellSelected
      } else if (isCurrent) {
        cellClass += " " + cls.monthCellCurrent
      }

      html += `
        <button type="button" class="${cellClass}" data-month="${index}" data-action="click->date-picker#selectMonth">
          ${month}
        </button>
      `
    })

    html += "</div></div>"
    this.calendarsContainerTarget.innerHTML = html
  }

  renderYearPicker() {
    const cls = this.constructor.classes
    const viewDate = this.parseDate(this.viewDateValue)
    const currentYear = viewDate.getFullYear()
    const todayYear = new Date().getFullYear()
    const startYear = Math.floor(currentYear / 12) * 12

    let html = `
      <div class="calendar-month">
        <div class="${cls.calendarHeader}">
          <button type="button" class="${cls.navButton}" data-action="click->date-picker#prevDecade" aria-label="Previous years">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
            </svg>
          </button>
          <span class="${cls.monthYear.replace('cursor-pointer', '').replace('hover:bg-zinc-100 dark:hover:bg-zinc-800', '')}">
            ${startYear} - ${startYear + 11}
          </span>
          <button type="button" class="${cls.navButton}" data-action="click->date-picker#nextDecade" aria-label="Next years">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
            </svg>
          </button>
        </div>
        <div class="${cls.yearGrid}">
    `

    for (let i = 0; i < 12; i++) {
      const year = startYear + i
      const isCurrent = year === todayYear
      const isSelected = year === currentYear

      let cellClass = cls.yearCell
      if (isSelected) {
        cellClass += " " + cls.yearCellSelected
      } else if (isCurrent) {
        cellClass += " " + cls.yearCellCurrent
      }

      html += `
        <button type="button" class="${cellClass}" data-year="${year}" data-action="click->date-picker#selectYear">
          ${year}
        </button>
      `
    }

    html += "</div></div>"
    this.calendarsContainerTarget.innerHTML = html
  }

  prevDecade(event) {
    event?.preventDefault()
    const date = this.parseDate(this.viewDateValue)
    date.setFullYear(date.getFullYear() - 12)
    this.viewDateValue = this.formatDate(date)
    this.renderCalendars()
  }

  nextDecade(event) {
    event?.preventDefault()
    const date = this.parseDate(this.viewDateValue)
    date.setFullYear(date.getFullYear() + 12)
    this.viewDateValue = this.formatDate(date)
    this.renderCalendars()
  }

  prevYear(event) {
    event?.preventDefault()
    const date = this.parseDate(this.viewDateValue)
    date.setFullYear(date.getFullYear() - 1)
    this.viewDateValue = this.formatDate(date)
    this.renderCalendars()
  }

  nextYear(event) {
    event?.preventDefault()
    const date = this.parseDate(this.viewDateValue)
    date.setFullYear(date.getFullYear() + 1)
    this.viewDateValue = this.formatDate(date)
    this.renderCalendars()
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  isDateDisabled(date) {
    const dateStr = this.formatDate(date)

    // Check unavailable dates
    if (this.unavailableValue.includes(dateStr)) return true

    // Check min/max
    if (this.minValue) {
      const minDate = this.parseDate(this.minValue)
      if (date < minDate) return true
    }
    if (this.maxValue) {
      const maxDate = this.parseDate(this.maxValue)
      if (date > maxDate) return true
    }

    return false
  }

  parseDate(dateStr) {
    if (!dateStr) return new Date()
    const [year, month, day] = dateStr.split("-").map(Number)
    return new Date(year, month - 1, day || 1)
  }

  formatDate(date) {
    const year = date.getFullYear()
    const month = String(date.getMonth() + 1).padStart(2, "0")
    const day = String(date.getDate()).padStart(2, "0")
    return `${year}-${month}-${day}`
  }

  formatDisplayDate(dateStr) {
    if (!dateStr) return ""
    const date = this.parseDate(dateStr)
    const month = String(date.getMonth() + 1).padStart(2, "0")
    const day = String(date.getDate()).padStart(2, "0")
    const year = date.getFullYear()
    return `${month}/${day}/${year}`
  }

  formatAccessibleDate(date) {
    const monthName = this.constructor.monthNames[date.getMonth()]
    const dayName = this.constructor.dayNamesFull[date.getDay()]
    return `${dayName}, ${monthName} ${date.getDate()}, ${date.getFullYear()}`
  }
}
