import { Controller } from "@hotwired/stimulus"

/**
 * Accordion Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles expand/collapse behavior for accordion items with keyboard navigation
 * and optional Turbo Frame lazy loading support.
 *
 * Targets:
 * - item: The accordion item wrapper
 * - button: The header button that triggers toggle
 * - content: The collapsible content wrapper
 * - icon: The chevron icon for rotation
 * - frame: Turbo Frame for lazy loading (optional)
 *
 * Values:
 * - exclusive: Boolean - Only one item can be open at a time (default: true)
 * - animate: Boolean - Enable smooth animations (default: true)
 */
export default class extends Controller {
  static targets = ["item", "button", "content", "icon", "frame"]
  static values = {
    exclusive: { type: Boolean, default: true },
    animate: { type: Boolean, default: true }
  }

  connect() {
    // Initialize expanded items based on data attributes
    this.itemTargets.forEach((item, index) => {
      const isExpanded = item.dataset.expanded === "true"
      const isCollapsible = item.dataset.collapsible !== "false"

      if (isExpanded || !isCollapsible) {
        this.expandItem(index, false)
      }
    })
  }

  // Toggle an accordion item
  toggle(event) {
    const button = event.currentTarget
    const index = this.buttonTargets.indexOf(button)

    if (index === -1) return

    const item = this.itemTargets[index]

    // Check if item is collapsible
    if (item.dataset.collapsible === "false") {
      return // Don't toggle non-collapsible items
    }

    const isExpanded = item.dataset.expanded === "true"

    if (isExpanded) {
      this.collapseItem(index)
    } else {
      // If exclusive mode, close all other items first
      if (this.exclusiveValue) {
        this.collapseAll(index)
      }
      this.expandItem(index)
    }
  }

  // Expand a specific item
  expandItem(index, animate = true) {
    const item = this.itemTargets[index]
    const button = this.buttonTargets[index]
    const content = this.contentTargets[index]
    const icon = this.iconTargets[index]

    if (!item || !content) return

    // Update state
    item.dataset.expanded = "true"
    button?.setAttribute("aria-expanded", "true")

    // Handle icon - either rotate or swap
    if (icon) {
      this.updateIcon(icon, true)
    }

    // Trigger Turbo Frame loading if present and lazy
    this.triggerFrameLoad(index)

    // Expand content
    if (this.animateValue && animate) {
      // Get the natural height
      content.style.maxHeight = content.scrollHeight + "px"

      // After animation, set to auto for dynamic content
      setTimeout(() => {
        if (item.dataset.expanded === "true") {
          content.style.maxHeight = "none"
        }
      }, 300)
    } else {
      content.style.maxHeight = "none"
    }

    // Dispatch custom event
    this.dispatch("expanded", { detail: { index, item } })
  }

  // Collapse a specific item
  collapseItem(index, animate = true) {
    const item = this.itemTargets[index]
    const button = this.buttonTargets[index]
    const content = this.contentTargets[index]
    const icon = this.iconTargets[index]

    if (!item || !content) return

    // Don't collapse non-collapsible items
    if (item.dataset.collapsible === "false") {
      return
    }

    // Update state
    item.dataset.expanded = "false"
    button?.setAttribute("aria-expanded", "false")

    // Handle icon - either rotate or swap
    if (icon) {
      this.updateIcon(icon, false)
    }

    // Collapse content
    if (this.animateValue && animate) {
      // First set explicit height for smooth transition
      content.style.maxHeight = content.scrollHeight + "px"

      // Force reflow
      content.offsetHeight

      // Then animate to 0
      content.style.maxHeight = "0"
    } else {
      content.style.maxHeight = "0"
    }

    // Dispatch custom event
    this.dispatch("collapsed", { detail: { index, item } })
  }

  // Trigger Turbo Frame loading when expanding
  triggerFrameLoad(index) {
    if (!this.hasFrameTarget) return

    const frame = this.frameTargets[index]
    if (!frame) return

    // If frame has loading="lazy" and hasn't loaded yet, trigger load
    if (frame.loading === "lazy" && !frame.src) {
      // Frame will auto-load when it becomes visible
      // But we can also manually trigger by setting src if needed
    }

    // If frame has a src but hasn't loaded, it will load automatically
    // when the content becomes visible (Turbo handles this)
  }

  // Collapse all items except the specified one
  collapseAll(exceptIndex = -1) {
    this.itemTargets.forEach((item, index) => {
      if (index !== exceptIndex && item.dataset.expanded === "true") {
        // Only collapse if item is collapsible
        if (item.dataset.collapsible !== "false") {
          this.collapseItem(index)
        }
      }
    })
  }

  // Expand all items (useful for non-exclusive mode)
  expandAll() {
    this.itemTargets.forEach((_, index) => {
      this.expandItem(index)
    })
  }

  // Open a specific item by index (programmatic API)
  open(index) {
    if (this.exclusiveValue) {
      this.collapseAll(index)
    }
    this.expandItem(index)
  }

  // Close a specific item by index (programmatic API)
  close(index) {
    this.collapseItem(index)
  }

  // Toggle a specific item by index (programmatic API)
  toggleItem(index) {
    const item = this.itemTargets[index]
    if (!item) return

    // Don't toggle non-collapsible items
    if (item.dataset.collapsible === "false") {
      return
    }

    const isExpanded = item.dataset.expanded === "true"
    if (isExpanded) {
      this.collapseItem(index)
    } else {
      if (this.exclusiveValue) {
        this.collapseAll(index)
      }
      this.expandItem(index)
    }
  }

  // Update icon state - handles both rotation and swap modes
  updateIcon(icon, expanded) {
    // Check if this is a dual-icon setup (wrapper with expand/collapse icons inside)
    const expandIcon = icon.querySelector('[data-icon-type="expand"]')
    const collapseIcon = icon.querySelector('[data-icon-type="collapse"]')

    if (expandIcon && collapseIcon) {
      // Dual icon mode - swap visibility using hidden class
      if (expanded) {
        expandIcon.classList.add("hidden")
        collapseIcon.classList.remove("hidden")
      } else {
        expandIcon.classList.remove("hidden")
        collapseIcon.classList.add("hidden")
      }
    } else {
      // Single icon mode - rotate the SVG directly
      if (expanded) {
        icon.classList.add("rotate-180")
      } else {
        icon.classList.remove("rotate-180")
      }
    }
  }
}
