import { Controller } from "@hotwired/stimulus"

/**
 * Combobox Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * A slim controller for combobox-specific functionality. Designed to be composed
 * with menu, keyboard, and search controllers for full functionality.
 *
 * Composition:
 *   <div data-controller="menu keyboard search combobox"
 *        data-action="keyboard:escape->menu#close search:filter->combobox#onFilter"
 *        data-menu-selection-mode-value="true"
 *        data-keyboard-selector-value="[role='option']:not(.hidden)"
 *        data-search-selector-value="[role='option']"
 *        data-search-attribute-value="data-text">
 *
 * This controller handles:
 *   - Multi-select hidden input management
 *   - Trigger text updates ("X items selected")
 *   - Max selections enforcement
 *   - Option selection with checkbox/radio visual updates
 *
 * For single-select without multi-select features, use menu controller directly.
 *
 * Targets:
 *   - triggerText: Span to show selected text/count
 *   - option: All option elements
 *   - hiddenInput: Hidden form inputs
 *   - checkbox: Checkbox inputs (multi-select)
 *   - radio: Radio inputs (single-select)
 *   - emptyInput: Empty input for array submission
 *   - noResults: "No results" message element
 *
 * Values:
 *   - multiple: Boolean - Allow multiple selection
 *   - maxSelections: Number - Limit selections (multi-select only)
 *   - closeOnSelect: Boolean - Close after selection
 *   - placeholder: String - Default placeholder text
 */
export default class extends Controller {
  static targets = [
    "triggerText",
    "option",
    "hiddenInput",
    "checkbox",
    "radio",
    "emptyInput",
    "noResults",
    "checkmark"
  ]

  static values = {
    multiple: { type: Boolean, default: false },
    maxSelections: { type: Number, default: 0 },
    closeOnSelect: { type: Boolean, default: true },
    placeholder: { type: String, default: "Select an option" }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this.selectedValues = this._getInitialSelected()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Handle option selection (called via click action on options)
   */
  select(event) {
    const option = event.currentTarget
    const value = option.dataset.value
    const text = option.dataset.text
    const isDisabled = option.getAttribute("aria-disabled") === "true"

    if (isDisabled) return

    event.preventDefault()
    event.stopPropagation()

    if (this.multipleValue) {
      this._toggleMultipleSelection(value, text, option)
    } else {
      this._setSingleSelection(value, text, option)
    }

    // Dispatch change event
    this._dispatchChangeEvent()

    // Close menu if configured (dispatch to menu controller)
    if (this.closeOnSelectValue && !this.multipleValue) {
      this.dispatch("requestClose", { bubbles: true })
    }
  }

  /**
   * Handle search filter results (listens to search:filter event)
   */
  onFilter(event) {
    const { visibleCount } = event.detail

    // Show/hide "no results" message
    if (this.hasNoResultsTarget) {
      this.noResultsTarget.classList.toggle("hidden", visibleCount > 0)
    }
  }

  /**
   * Select the currently focused option (triggered by Enter key)
   */
  selectFocused(event) {
    const focused = document.activeElement
    const isOption = focused?.getAttribute("role") === "option"

    if (isOption && this.optionTargets.includes(focused)) {
      event.preventDefault()
      // Trigger click on the focused option
      focused.click()
    }
  }

  /**
   * Clear all selections
   */
  clearAll() {
    if (this.multipleValue) {
      // Remove all hidden inputs except empty one
      this.hiddenInputTargets.forEach(input => {
        if (input !== this.emptyInputTarget) {
          input.remove()
        }
      })

      // Reset all options
      this.optionTargets.forEach(option => {
        option.setAttribute("aria-selected", "false")
        const checkbox = option.querySelector('[data-combobox-target="checkbox"]')
        if (checkbox) checkbox.checked = false
      })

      this.selectedValues = []
      this._updateTriggerText()
      this._updateMaxSelectionsState()
    }

    this._dispatchChangeEvent()
  }

  // ==========================================================================
  // PRIVATE: SINGLE SELECTION
  // ==========================================================================

  _setSingleSelection(value, text, optionElement) {
    // Unselect all options
    this.optionTargets.forEach(opt => {
      opt.setAttribute("aria-selected", "false")
      opt.classList.remove("bg-zinc-50", "dark:bg-zinc-700/50")
      const radio = opt.querySelector('[data-combobox-target="radio"]')
      if (radio) radio.checked = false
    })

    // Select this option
    optionElement.setAttribute("aria-selected", "true")
    optionElement.classList.add("bg-zinc-50", "dark:bg-zinc-700/50")
    const radio = optionElement.querySelector('[data-combobox-target="radio"]')
    if (radio) radio.checked = true

    // Update hidden input
    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = value
    }

    this.selectedValues = [value]
    this._updateTriggerText(text)
  }

  // ==========================================================================
  // PRIVATE: MULTIPLE SELECTION
  // ==========================================================================

  _toggleMultipleSelection(value, text, optionElement) {
    const isSelected = this.selectedValues.includes(value)

    if (isSelected) {
      this._removeSelection(value, optionElement)
    } else {
      // Check max limit
      if (this.maxSelectionsValue > 0 && this.selectedValues.length >= this.maxSelectionsValue) {
        return
      }
      this._addSelection(value, text, optionElement)
    }
  }

  _addSelection(value, text, optionElement) {
    this.selectedValues.push(value)

    // Update option UI
    optionElement.setAttribute("aria-selected", "true")
    const checkbox = optionElement.querySelector('[data-combobox-target="checkbox"]')
    if (checkbox) checkbox.checked = true

    // Show checkmark
    const checkmark = optionElement.querySelector('[data-combobox-target="checkmark"]')
    if (checkmark) checkmark.classList.remove("invisible")

    // Add hidden input
    this._addHiddenInput(value)
    this._updateTriggerText()
    this._updateMaxSelectionsState()
  }

  _removeSelection(value, optionElement) {
    this.selectedValues = this.selectedValues.filter(v => v !== value)

    // Update option UI
    optionElement.setAttribute("aria-selected", "false")
    const checkbox = optionElement.querySelector('[data-combobox-target="checkbox"]')
    if (checkbox) checkbox.checked = false

    // Hide checkmark
    const checkmark = optionElement.querySelector('[data-combobox-target="checkmark"]')
    if (checkmark) checkmark.classList.add("invisible")

    // Remove hidden input
    this._removeHiddenInput(value)
    this._updateTriggerText()
    this._updateMaxSelectionsState()
  }

  _addHiddenInput(value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = this._getInputName()
    input.value = value
    input.dataset.comboboxTarget = "hiddenInput"

    if (this.hasEmptyInputTarget) {
      this.emptyInputTarget.parentNode.insertBefore(input, this.emptyInputTarget.nextSibling)
    } else {
      this.element.appendChild(input)
    }
  }

  _removeHiddenInput(value) {
    const input = this.hiddenInputTargets.find(i => i.value === value)
    if (input && input !== this.emptyInputTarget) {
      input.remove()
    }
  }

  _getInputName() {
    if (this.hasHiddenInputTarget) {
      return this.hiddenInputTarget.name
    }
    if (this.hasEmptyInputTarget) {
      return this.emptyInputTarget.name
    }
    return "selection[]"
  }

  // ==========================================================================
  // PRIVATE: UI UPDATES
  // ==========================================================================

  _updateTriggerText(text = null) {
    if (!this.hasTriggerTextTarget) return

    if (this.multipleValue) {
      const count = this.selectedValues.length
      if (count > 0) {
        this.triggerTextTarget.textContent = `${count} ${count === 1 ? 'item' : 'items'} selected`
        this.triggerTextTarget.classList.remove("text-zinc-400", "dark:text-zinc-500")
      } else {
        this.triggerTextTarget.textContent = this.placeholderValue
        this.triggerTextTarget.classList.add("text-zinc-400", "dark:text-zinc-500")
      }
    } else if (text) {
      this.triggerTextTarget.textContent = text
      this.triggerTextTarget.classList.remove("text-zinc-400", "dark:text-zinc-500")
    }
  }

  _updateMaxSelectionsState() {
    if (this.maxSelectionsValue <= 0) return

    const maxReached = this.selectedValues.length >= this.maxSelectionsValue

    this.optionTargets.forEach(option => {
      const value = option.dataset.value
      const isSelected = this.selectedValues.includes(value)

      if (maxReached && !isSelected) {
        option.setAttribute("aria-disabled", "true")
        option.classList.add("opacity-50", "cursor-not-allowed")
      } else {
        option.setAttribute("aria-disabled", "false")
        option.classList.remove("opacity-50", "cursor-not-allowed")
      }
    })
  }

  // ==========================================================================
  // PRIVATE: HELPERS
  // ==========================================================================

  _getInitialSelected() {
    if (!this.hasHiddenInputTarget) return []

    if (this.multipleValue) {
      return this.hiddenInputTargets
        .filter(input => input !== this.emptyInputTarget)
        .map(input => input.value)
        .filter(val => val && val !== "")
    } else {
      const value = this.hiddenInputTarget.value
      return value ? [value] : []
    }
  }

  _dispatchChangeEvent() {
    this.dispatch("change", {
      detail: { values: this.selectedValues },
      bubbles: true
    })
  }
}
