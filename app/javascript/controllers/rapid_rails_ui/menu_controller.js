import { Controller } from "@hotwired/stimulus"

/**
 * Menu Controller
 * @gem rapid_rails_ui
 * @version 0.34.0
 * @updated 2026-01-29
 *
 * Core menu/dropdown functionality: open, close, positioning, and click outside.
 * Designed to be composed with shared controllers for additional behaviors.
 *
 * Features:
 * - Smart positioning with collision detection
 * - Auto-flips horizontally when near viewport edges
 * - Auto-flips vertically when near viewport bottom
 * - Turbo-compatible link navigation
 * - Keyboard navigation support
 *
 * Composition Example:
 *   <div data-controller="menu keyboard search"
 *        data-action="keyboard:escape->menu#close"
 *        data-keyboard-selector-value="[role='menuitem']">
 *
 * Targets:
 *   - trigger: Button that opens the menu
 *   - menu: The dropdown menu container
 *   - buttonText: Text span in trigger (for selection mode)
 *   - chevron: Chevron icon to rotate
 *
 * Values:
 *   - open: Current open state
 *   - trigger: "click" or "hover"
 *   - disabled: Disabled state
 *   - selectionMode: Whether selecting updates trigger text
 *   - promptText: Default text when no selection
 *   - placement: "top", "right", "bottom", "left"
 */
export default class extends Controller {
  static targets = ["trigger", "menu", "buttonText", "chevron"]

  static values = {
    open: { type: Boolean, default: false },
    trigger: { type: String, default: "click" },
    disabled: { type: Boolean, default: false },
    selectionMode: { type: Boolean, default: false },
    promptText: { type: String, default: "Select an option" },
    placement: { type: String, default: "bottom" }
  }

  // CSS classes
  static CLASSES = {
    chevronOpen: "rotate-180",
    menuHidden: "hidden"
  }

  // Timing constants
  static HOVER_OPEN_DELAY = 150
  static HOVER_CLOSE_DELAY = 200

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this._close()
    this._boundHandlers = {}
    this._hoverTimeout = null

    if (this.triggerValue === "hover") {
      this._setupHoverBehavior()
    }
  }

  disconnect() {
    this._clearHoverTimeout()
    this._cleanupHoverListeners()
  }

  openValueChanged() {
    this.openValue ? this._open() : this._close()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  toggle(event) {
    if (event) event.preventDefault()
    if (this.disabledValue) return

    this.openValue = !this.openValue
  }

  close() {
    this.openValue = false
  }

  open() {
    if (!this.disabledValue) {
      this.openValue = true
    }
  }

  clickOutside(event) {
    if (this.openValue && !this.element.contains(event.target)) {
      this.close()
    }
  }

  // ==========================================================================
  // KEYBOARD NAVIGATION
  // ==========================================================================

  /**
   * Navigate to next menu item (down arrow)
   */
  navigateDown(event) {
    event.preventDefault()
    this._navigate(1)
  }

  /**
   * Navigate to previous menu item (up arrow)
   */
  navigateUp(event) {
    event.preventDefault()
    this._navigate(-1)
  }

  /**
   * Navigate to first menu item (Home key)
   */
  navigateFirst(event) {
    event.preventDefault()
    const items = this._getNavigableItems()
    if (items.length > 0) {
      items[0].focus({ preventScroll: true })
    }
  }

  /**
   * Navigate to last menu item (End key)
   */
  navigateLast(event) {
    event.preventDefault()
    const items = this._getNavigableItems()
    if (items.length > 0) {
      items[items.length - 1].focus({ preventScroll: true })
    }
  }

  /**
   * Handle item selection
   */
  selectItem(event) {
    const item = event.currentTarget
    const isLink = item.tagName === 'A' && item.href

    // For links: allow Turbo to handle navigation
    // For buttons/selection: prevent default and stop propagation
    if (isLink && !this.selectionModeValue) {
      // Link navigation - just close menu and let event bubble to Turbo
      this.close()
      return
    }

    // Button or selection mode - prevent default behavior
    event.preventDefault()
    event.stopPropagation()

    const value = item.dataset.value
    const text = item.dataset.text || item.textContent.trim()

    if (this.selectionModeValue) {
      const hiddenInput = this.element.querySelector('input[type="hidden"]')
      if (hiddenInput) {
        hiddenInput.value = value
        this._updateButtonText(value === "" || value === null ? this.promptTextValue : text)
      }
    }

    this.close()
  }

  /**
   * Toggle checkbox without closing menu
   */
  toggleCheckbox(event) {
    event.stopPropagation()

    if (event.type === "keydown") {
      event.preventDefault()
      const checkbox = event.currentTarget.querySelector('input[type="checkbox"]')
      if (checkbox && !checkbox.disabled) {
        checkbox.checked = !checkbox.checked
        checkbox.dispatchEvent(new Event("change", { bubbles: true }))
      }
    }

    const label = event.currentTarget
    const checkbox = label.querySelector('input[type="checkbox"]')
    if (checkbox) {
      label.setAttribute("aria-checked", checkbox.checked.toString())
    }
  }

  /**
   * Toggle radio without closing menu
   */
  toggleRadio(event) {
    event.stopPropagation()

    if (event.type === "keydown") {
      event.preventDefault()
      const radio = event.currentTarget.querySelector('input[type="radio"]')
      if (radio && !radio.disabled) {
        radio.checked = true
        radio.dispatchEvent(new Event("change", { bubbles: true }))
      }
    }

    const currentRadio = event.currentTarget.querySelector('input[type="radio"]')
    if (currentRadio?.name) {
      const allRadios = this.menuTarget.querySelectorAll(`input[type="radio"][name="${currentRadio.name}"]`)
      allRadios.forEach(radio => {
        const label = radio.closest("label")
        if (label) label.setAttribute("aria-checked", radio.checked.toString())
      })
    }
  }

  // ==========================================================================
  // PRIVATE: MENU STATE
  // ==========================================================================

  _open() {
    this.menuTarget.classList.remove(this.constructor.CLASSES.menuHidden)
    this.triggerTarget.setAttribute("aria-expanded", "true")

    if (this.hasChevronTarget) {
      this.chevronTarget.classList.add(this.constructor.CLASSES.chevronOpen)
    }

    this._adjustMenuWidth()

    // Focus the menu so it can receive keyboard events
    // Use requestAnimationFrame to ensure DOM is painted first
    // Use preventScroll to avoid browser auto-scrolling to the focused element
    requestAnimationFrame(() => {
      this._adjustMenuPosition()
      this.menuTarget.focus({ preventScroll: true })
      this.dispatch("opened", { detail: {} })
    })
  }

  _close() {
    this.menuTarget.classList.add(this.constructor.CLASSES.menuHidden)
    this.triggerTarget.setAttribute("aria-expanded", "false")

    if (this.hasChevronTarget) {
      this.chevronTarget.classList.remove(this.constructor.CLASSES.chevronOpen)
    }

    // Reset positioning classes for next open
    this._resetMenuPosition()

    this.dispatch("closed", { detail: {} })
  }

  /**
   * Reset menu to original placement (remove dynamic positioning classes)
   */
  _resetMenuPosition() {
    const menu = this.menuTarget
    const placement = this.placementValue

    // Remove dynamic classes
    menu.classList.remove('left-0', 'right-0')

    // Restore original placement classes based on placement value
    const placementMap = {
      top: ['bottom-full', 'mb-2'],
      right: ['left-full', 'ml-2', 'top-0'],
      bottom: ['top-full', 'mt-2'],
      left: ['right-full', 'mr-2', 'top-0']
    }

    // Ensure original classes are present
    const originalClasses = placementMap[placement] || placementMap.bottom
    originalClasses.forEach(cls => {
      if (!menu.classList.contains(cls)) {
        menu.classList.add(cls)
      }
    })
  }

  _adjustMenuWidth() {
    const triggerWidth = this.triggerTarget.offsetWidth
    this.menuTarget.style.minWidth = `${triggerWidth}px`
  }

  /**
   * Smart positioning: adjust menu position to avoid viewport overflow
   * Flips horizontal (left/right) and vertical (top/bottom) as needed
   */
  _adjustMenuPosition() {
    const menu = this.menuTarget
    const trigger = this.triggerTarget
    const placement = this.placementValue

    // Get viewport dimensions
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    // Get menu and trigger rectangles
    const menuRect = menu.getBoundingClientRect()
    const triggerRect = trigger.getBoundingClientRect()

    // Remove any previous positioning classes
    menu.classList.remove('left-0', 'right-0', 'left-full', 'right-full', 'top-full', 'bottom-full')

    // Check horizontal overflow
    let horizontalPlacement = placement
    if (placement === 'bottom' || placement === 'top') {
      // For bottom/top placements, check if menu overflows right edge
      const overflowsRight = menuRect.right > viewportWidth - 8 // 8px buffer
      const overflowsLeft = menuRect.left < 8

      if (overflowsRight && !overflowsLeft) {
        // Menu overflows right - align right edges
        menu.classList.add('right-0')
      } else {
        // Default: align left edges
        menu.classList.add('left-0')
      }
    } else if (placement === 'right') {
      // Check if right placement would overflow
      if (menuRect.right > viewportWidth - 8) {
        // Flip to left
        menu.classList.remove('left-full', 'ml-2')
        menu.classList.add('right-full', 'mr-2')
        horizontalPlacement = 'left'
      } else {
        menu.classList.add('left-full')
      }
    } else if (placement === 'left') {
      // Check if left placement would overflow
      if (menuRect.left < 8) {
        // Flip to right
        menu.classList.remove('right-full', 'mr-2')
        menu.classList.add('left-full', 'ml-2')
        horizontalPlacement = 'right'
      } else {
        menu.classList.add('right-full')
      }
    }

    // Check vertical overflow
    if (placement === 'bottom' || placement === 'top') {
      const overflowsBottom = menuRect.bottom > viewportHeight - 8
      const hasSpaceAbove = triggerRect.top > menuRect.height + 8

      if (placement === 'bottom' && overflowsBottom && hasSpaceAbove) {
        // Flip to top
        menu.classList.remove('top-full', 'mt-2')
        menu.classList.add('bottom-full', 'mb-2')
      } else if (placement === 'top' && menuRect.top < 8) {
        // Flip to bottom
        menu.classList.remove('bottom-full', 'mb-2')
        menu.classList.add('top-full', 'mt-2')
      } else if (placement === 'bottom') {
        menu.classList.add('top-full')
      } else {
        menu.classList.add('bottom-full')
      }
    }
  }

  _updateButtonText(text) {
    if (this.hasButtonTextTarget) {
      this.buttonTextTarget.textContent = text
    }
  }

  // ==========================================================================
  // PRIVATE: KEYBOARD NAVIGATION
  // ==========================================================================
  // Note: Navigation is inline rather than using shared/keyboard_controller because
  // it has menu-specific requirements: filtering out submenu items, focus management
  // on open, and integration with selection. The 30-40 lines of navigation code
  // here are simpler than configuring the generic controller for these edge cases.

  /**
   * Navigate through menu items
   * @param {number} direction - 1 for next, -1 for previous
   */
  _navigate(direction) {
    const items = this._getNavigableItems()
    if (items.length === 0) return

    // Find currently focused item
    const currentFocused = document.activeElement
    const currentIndex = items.indexOf(currentFocused)

    let nextIndex
    if (currentIndex === -1) {
      // No item focused, start from beginning or end
      nextIndex = direction > 0 ? 0 : items.length - 1
    } else {
      // Wrap around
      nextIndex = (currentIndex + direction + items.length) % items.length
    }

    items[nextIndex].focus({ preventScroll: true })
  }

  /**
   * Get all navigable menu items (top-level items only)
   * Excludes items inside submenu panels - submenus have their own navigation
   * (Right arrow to enter submenu, Left/Escape to exit)
   * @returns {HTMLElement[]} Array of focusable menu items
   */
  _getNavigableItems() {
    const allItems = Array.from(
      this.menuTarget.querySelectorAll(
        '[role="menuitem"]:not([disabled]):not([aria-disabled="true"]):not(.hidden), ' +
        '[role="menuitemcheckbox"]:not([disabled]):not([aria-disabled="true"]):not(.hidden), ' +
        '[role="menuitemradio"]:not([disabled]):not([aria-disabled="true"]):not(.hidden), ' +
        '[role="option"]:not([disabled]):not([aria-disabled="true"]):not(.hidden), ' +
        'button:not([disabled]):not([aria-disabled="true"]):not(.hidden), ' +
        'a:not([disabled]):not([aria-disabled="true"]):not(.hidden)'
      )
    )

    // Filter out ALL items inside submenu panels
    // Submenus have their own keyboard navigation via submenu controller
    // Parent menu should only navigate through top-level items
    return allItems.filter(item => {
      const submenuPanel = item.closest('.submenu-panel, [data-submenu-target="panel"]')
      return !submenuPanel
    })
  }

  // ==========================================================================
  // PRIVATE: HOVER BEHAVIOR
  // ==========================================================================

  _setupHoverBehavior() {
    this._mouseIsOverMenu = false
    this._mouseIsOverTrigger = false

    this._boundHandlers.triggerEnter = () => {
      this._mouseIsOverTrigger = true
      this._clearHoverTimeout()
      this._hoverTimeout = setTimeout(() => this.open(), this.constructor.HOVER_OPEN_DELAY)
    }

    this._boundHandlers.triggerLeave = () => {
      this._mouseIsOverTrigger = false
      if (!this._mouseIsOverMenu) {
        this._clearHoverTimeout()
        this._hoverTimeout = setTimeout(() => this.close(), this.constructor.HOVER_CLOSE_DELAY)
      }
    }

    this._boundHandlers.menuEnter = () => {
      this._mouseIsOverMenu = true
      this._clearHoverTimeout()
    }

    this._boundHandlers.menuLeave = () => {
      this._mouseIsOverMenu = false
      if (!this._mouseIsOverTrigger) {
        this._clearHoverTimeout()
        this._hoverTimeout = setTimeout(() => this.close(), this.constructor.HOVER_CLOSE_DELAY)
      }
    }

    this.triggerTarget.addEventListener("mouseenter", this._boundHandlers.triggerEnter)
    this.triggerTarget.addEventListener("mouseleave", this._boundHandlers.triggerLeave)
    this.menuTarget.addEventListener("mouseenter", this._boundHandlers.menuEnter)
    this.menuTarget.addEventListener("mouseleave", this._boundHandlers.menuLeave)
  }

  _clearHoverTimeout() {
    if (this._hoverTimeout) {
      clearTimeout(this._hoverTimeout)
      this._hoverTimeout = null
    }
  }

  _cleanupHoverListeners() {
    if (this._boundHandlers.triggerEnter) {
      this.triggerTarget.removeEventListener("mouseenter", this._boundHandlers.triggerEnter)
      this.triggerTarget.removeEventListener("mouseleave", this._boundHandlers.triggerLeave)
      this.menuTarget.removeEventListener("mouseenter", this._boundHandlers.menuEnter)
      this.menuTarget.removeEventListener("mouseleave", this._boundHandlers.menuLeave)
    }
    this._boundHandlers = {}
  }
}
