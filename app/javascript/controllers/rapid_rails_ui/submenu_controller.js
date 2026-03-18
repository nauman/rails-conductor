import { Controller } from "@hotwired/stimulus"

/**
 * Submenu Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles nested submenu behavior within dropdowns.
 * Manages hover-triggered opening, keyboard navigation, and positioning.
 *
 * Usage:
 *   <div class="submenu-wrapper" data-controller="submenu">
 *     <button data-submenu-target="trigger" data-action="keydown.right->submenu#open">
 *       More Options
 *     </button>
 *     <div data-submenu-target="panel" class="submenu-panel">
 *       <a role="menuitem">Option 1</a>
 *       <a role="menuitem">Option 2</a>
 *     </div>
 *   </div>
 */
export default class extends Controller {
  static targets = ["trigger", "panel"]

  static values = {
    openDelay: { type: Number, default: 150 },
    closeDelay: { type: Number, default: 200 }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this._hideTimeout = null
    this._setupHoverBehavior()
  }

  disconnect() {
    this._clearHideTimeout()
    this._cleanupListeners()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  open(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    this._showPanel()

    // Focus first item if opened via keyboard
    if (event?.type === "keydown") {
      setTimeout(() => {
        const items = this._getItems()
        if (items.length > 0) items[0].focus()
      }, 10)
    }
  }

  close(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    this._hidePanel()

    // Return focus to trigger if closed via keyboard
    if (event?.type === "keydown" && this.hasTriggerTarget) {
      this.triggerTarget.focus()
    }
  }

  /**
   * Navigate within submenu
   */
  navigateDown(event) {
    event.preventDefault()
    event.stopPropagation()
    this._navigate(1)
  }

  navigateUp(event) {
    event.preventDefault()
    event.stopPropagation()
    this._navigate(-1)
  }

  /**
   * Handle item click - close submenu and parent menu
   */
  handleItemClick(event) {
    const clickedItem = event.target.closest('[role="menuitem"]')
    if (clickedItem && !clickedItem.disabled) {
      this._hidePanel()
      // Dispatch event for parent menu to close
      this.dispatch("itemSelected", { detail: { item: clickedItem } })
    }
  }

  // ==========================================================================
  // PRIVATE: PANEL VISIBILITY
  // ==========================================================================

  _showPanel() {
    if (!this.hasPanelTarget || !this.hasTriggerTarget) return

    const triggerRect = this.triggerTarget.getBoundingClientRect()
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    const panel = this.panelTarget
    let left = triggerRect.right - 4
    let top = triggerRect.top - 4

    // Check horizontal overflow
    const panelWidth = panel.offsetWidth || 192
    if (left + panelWidth > viewportWidth) {
      left = triggerRect.left - panelWidth + 4
    }

    // Check vertical overflow
    const panelHeight = panel.offsetHeight || 150
    if (top + panelHeight > viewportHeight) {
      top = viewportHeight - panelHeight - 8
    }

    panel.style.position = "fixed"
    panel.style.left = `${left}px`
    panel.style.top = `${top}px`
    panel.style.visibility = "visible"
    panel.style.opacity = "1"
    panel.style.zIndex = "9999"
  }

  _hidePanel() {
    if (this.hasPanelTarget) {
      this.panelTarget.style.visibility = "hidden"
      this.panelTarget.style.opacity = "0"
    }
  }

  // ==========================================================================
  // PRIVATE: HOVER BEHAVIOR
  // ==========================================================================

  _setupHoverBehavior() {
    this._boundHandlers = {
      wrapperEnter: () => {
        this._clearHideTimeout()
        this._showPanel()
      },
      wrapperLeave: () => {
        this._scheduleHide()
      },
      panelEnter: () => {
        this._clearHideTimeout()
      },
      panelLeave: () => {
        this._scheduleHide()
      }
    }

    this.element.addEventListener("mouseenter", this._boundHandlers.wrapperEnter)
    this.element.addEventListener("mouseleave", this._boundHandlers.wrapperLeave)

    if (this.hasPanelTarget) {
      this.panelTarget.addEventListener("mouseenter", this._boundHandlers.panelEnter)
      this.panelTarget.addEventListener("mouseleave", this._boundHandlers.panelLeave)
    }
  }

  _scheduleHide() {
    this._clearHideTimeout()
    this._hideTimeout = setTimeout(() => this._hidePanel(), this.closeDelayValue)
  }

  _clearHideTimeout() {
    if (this._hideTimeout) {
      clearTimeout(this._hideTimeout)
      this._hideTimeout = null
    }
  }

  _cleanupListeners() {
    if (this._boundHandlers) {
      this.element.removeEventListener("mouseenter", this._boundHandlers.wrapperEnter)
      this.element.removeEventListener("mouseleave", this._boundHandlers.wrapperLeave)

      if (this.hasPanelTarget) {
        this.panelTarget.removeEventListener("mouseenter", this._boundHandlers.panelEnter)
        this.panelTarget.removeEventListener("mouseleave", this._boundHandlers.panelLeave)
      }
    }
    this._boundHandlers = {}
  }

  // ==========================================================================
  // PRIVATE: NAVIGATION
  // ==========================================================================

  _navigate(direction) {
    const items = this._getItems()
    if (items.length === 0) return

    const currentIndex = items.indexOf(document.activeElement)
    let nextIndex

    if (direction > 0) {
      nextIndex = currentIndex === -1 ? 0 : (currentIndex + 1) % items.length
    } else {
      nextIndex = currentIndex === -1 ? items.length - 1 : (currentIndex - 1 + items.length) % items.length
    }

    items[nextIndex].focus()
  }

  _getItems() {
    if (!this.hasPanelTarget) return []
    return Array.from(
      this.panelTarget.querySelectorAll('a[role="menuitem"], button[role="menuitem"]')
    ).filter(item => !item.disabled && !item.hasAttribute("disabled"))
  }
}
