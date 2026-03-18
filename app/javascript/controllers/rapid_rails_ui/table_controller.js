import { Controller } from "@hotwired/stimulus"

/**
 * Table Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles table interactivity including:
 * - Row selection with select-all functionality
 * - Column sorting (emits events for server-side or handles client-side)
 * - Bulk actions visibility
 * - Selected count updates
 * - Bulk action form integration
 *
 * Targets:
 * - selectAll: The header checkbox for selecting all rows
 * - rowCheckbox: Individual row checkboxes
 * - bulkActions: Container for bulk action buttons
 * - selectedCount: Element displaying the count of selected items
 * - selectedIdsField: Hidden fields to populate with selected IDs (for bulk action forms)
 * - row: Table row elements (for styling selected state)
 * - mobileCard: Mobile card view elements
 * - mobileStack: Mobile stack view elements
 *
 * Values:
 * - sortColumn: Current column being sorted
 * - sortDirection: Current sort direction ("asc" or "desc")
 * - selectedIds: Array of selected row IDs
 * - turboFrame: Optional Turbo Frame ID for AJAX sorting
 */
export default class extends Controller {
  static targets = [
    "selectAll",
    "rowCheckbox",
    "bulkActions",
    "selectedCount",
    "selectedIdsField",
    "row",
    "mobileCard",
    "mobileStack",
    "tbody",
    "sortIcon"
  ]

  static values = {
    sortColumn: { type: String, default: "" },
    sortDirection: { type: String, default: "asc" },
    selectedIds: { type: Array, default: [] },
    turboFrame: { type: String, default: "" },
    clientSort: { type: Boolean, default: true },
    sortUrl: { type: String, default: "" }
  }

  connect() {
    this.updateBulkActionsVisibility()
    this.updateSelectAllState()
  }

  // ==========================================================================
  // VISIBILITY HELPERS
  // ==========================================================================

  /**
   * Get only visible row checkboxes (excludes hidden mobile/responsive checkboxes)
   * This is critical for responsive tables that render both desktop and mobile views
   */
  get visibleRowCheckboxTargets() {
    return this.rowCheckboxTargets.filter((cb) => cb.offsetParent !== null)
  }

  // ==========================================================================
  // SELECTION HANDLING
  // ==========================================================================

  /**
   * Toggle all row checkboxes when select-all is clicked
   * Only affects visible checkboxes (excludes hidden responsive views)
   */
  toggleSelectAll(event) {
    const checked = event.target.checked
    const visibleCheckboxes = this.visibleRowCheckboxTargets

    visibleCheckboxes.forEach((checkbox) => {
      checkbox.checked = checked
      this._updateRowSelection(checkbox, checked)
    })

    // Update selected IDs array (only from visible checkboxes)
    if (checked) {
      this.selectedIdsValue = visibleCheckboxes.map((cb) => cb.value)
    } else {
      this.selectedIdsValue = []
    }

    this.updateBulkActionsVisibility()
    this._dispatchSelectionEvent()
  }

  /**
   * Toggle individual row selection
   */
  toggleRow(event) {
    const checkbox = event.target
    const checked = checkbox.checked

    this._updateRowSelection(checkbox, checked)
    this._updateSelectedIds(checkbox)
    this.updateSelectAllState()
    this.updateBulkActionsVisibility()
    this._dispatchSelectionEvent()
  }

  /**
   * Update the select-all checkbox state based on individual selections
   * CSS handles indeterminate styling via :indeterminate pseudo-class
   * Only counts visible checkboxes (excludes hidden responsive views)
   * Updates ALL selectAll targets (desktop + mobile)
   */
  updateSelectAllState() {
    if (!this.hasSelectAllTarget) return

    const visibleCheckboxes = this.visibleRowCheckboxTargets
    const total = visibleCheckboxes.length
    const checked = visibleCheckboxes.filter((cb) => cb.checked).length

    let isChecked = false
    let isIndeterminate = false

    if (total === 0) {
      isChecked = false
      isIndeterminate = false
    } else if (checked === 0) {
      isChecked = false
      isIndeterminate = false
    } else if (checked === total) {
      isChecked = true
      isIndeterminate = false
    } else {
      isChecked = false
      isIndeterminate = true
    }

    // Update ALL selectAll checkboxes (desktop + mobile)
    this.selectAllTargets.forEach((checkbox) => {
      checkbox.checked = isChecked
      checkbox.indeterminate = isIndeterminate
    })
  }

  /**
   * Update bulk actions bar visibility based on selection
   */
  updateBulkActionsVisibility() {
    if (!this.hasBulkActionsTarget) return

    const hasSelection = this.selectedIdsValue.length > 0

    if (hasSelection) {
      this.bulkActionsTarget.removeAttribute("hidden")
    } else {
      this.bulkActionsTarget.setAttribute("hidden", "")
    }

    // Update selected count
    if (this.hasSelectedCountTarget) {
      this.selectedCountTarget.textContent = this.selectedIdsValue.length
    }

    // Update hidden fields with selected IDs (for bulk action forms)
    this._updateSelectedIdsFields()
  }

  /**
   * Update all hidden fields that store selected IDs
   * These fields are used by bulk action forms (rui_bulk_action helper)
   */
  _updateSelectedIdsFields() {
    if (!this.hasSelectedIdsFieldTarget) return

    const idsValue = JSON.stringify(this.selectedIdsValue)

    this.selectedIdsFieldTargets.forEach((field) => {
      field.value = idsValue
    })
  }

  /**
   * Get currently selected row IDs
   */
  getSelectedIds() {
    return this.selectedIdsValue
  }

  /**
   * Clear all selections
   * Only affects visible checkboxes (excludes hidden responsive views)
   */
  clearSelection() {
    this.visibleRowCheckboxTargets.forEach((checkbox) => {
      checkbox.checked = false
      this._updateRowSelection(checkbox, false)
    })

    this.selectedIdsValue = []

    // Clear ALL selectAll checkboxes (desktop + mobile)
    this.selectAllTargets.forEach((checkbox) => {
      checkbox.checked = false
      checkbox.indeterminate = false
    })

    this.updateBulkActionsVisibility()
    this._dispatchSelectionEvent()
  }

  // ==========================================================================
  // SORTING
  // ==========================================================================

  /**
   * Sort by column when header is clicked
   */
  sort(event) {
    const column = event.currentTarget.dataset.column

    if (!column) return

    // Toggle direction if same column, otherwise reset to asc
    if (this.sortColumnValue === column) {
      this.sortDirectionValue =
        this.sortDirectionValue === "asc" ? "desc" : "asc"
    } else {
      this.sortColumnValue = column
      this.sortDirectionValue = "asc"
    }

    // Update sort icon visuals
    this._updateSortIcons(event.currentTarget)

    // Dispatch event for server-side sorting
    this.dispatch("sort", {
      detail: {
        column: this.sortColumnValue,
        direction: this.sortDirectionValue
      }
    })

    // If Turbo Frame or sort URL is configured, navigate
    if (this.turboFrameValue) {
      this._navigateToSortedUrl()
    } else if (this.sortUrlValue) {
      this._navigateToSortedUrl()
    } else if (this.clientSortValue) {
      // Client-side sorting
      this._sortTableClientSide(column)
    }
  }

  /**
   * Update sort icon visuals on all headers
   */
  _updateSortIcons(activeHeader) {
    // Find all sortable headers
    const headers = this.element.querySelectorAll("th[data-action*='sort']")

    headers.forEach((header) => {
      const icon = header.querySelector("[data-table-target='sortIcon']")
      if (!icon) return

      const isActive = header === activeHeader
      const column = header.dataset.column

      if (isActive && column === this.sortColumnValue) {
        // Show active icon
        icon.classList.remove("opacity-50")
        icon.classList.add("opacity-100")

        // Rotate based on direction
        if (this.sortDirectionValue === "asc") {
          icon.classList.add("rotate-180")
        } else {
          icon.classList.remove("rotate-180")
        }
      } else {
        // Reset inactive icons
        icon.classList.add("opacity-50")
        icon.classList.remove("opacity-100", "rotate-180")
      }
    })
  }

  /**
   * Sort table rows client-side
   */
  _sortTableClientSide(column) {
    const tbody = this.hasTbodyTarget
      ? this.tbodyTarget
      : this.element.querySelector("tbody")

    if (!tbody) return

    const rows = Array.from(tbody.querySelectorAll("tr"))
    const columnIndex = this._getColumnIndex(column)

    if (columnIndex === -1) return

    // Sort rows
    rows.sort((a, b) => {
      const aCell = a.cells[columnIndex]
      const bCell = b.cells[columnIndex]

      if (!aCell || !bCell) return 0

      const aValue = this._getCellSortValue(aCell)
      const bValue = this._getCellSortValue(bCell)

      let comparison = 0

      // Try numeric comparison first
      const aNum = parseFloat(aValue.replace(/[^0-9.-]/g, ""))
      const bNum = parseFloat(bValue.replace(/[^0-9.-]/g, ""))

      if (!isNaN(aNum) && !isNaN(bNum)) {
        comparison = aNum - bNum
      } else {
        // String comparison
        comparison = aValue.localeCompare(bValue, undefined, {
          numeric: true,
          sensitivity: "base"
        })
      }

      return this.sortDirectionValue === "asc" ? comparison : -comparison
    })

    // Re-append sorted rows
    rows.forEach((row) => tbody.appendChild(row))
  }

  /**
   * Get column index from column key
   */
  _getColumnIndex(columnKey) {
    const headers = this.element.querySelectorAll("thead th")
    let index = 0

    for (const header of headers) {
      if (header.dataset.column === columnKey) {
        return index
      }
      index++
    }

    return -1
  }

  /**
   * Get sortable value from cell (handles nested content)
   */
  _getCellSortValue(cell) {
    // Check for data-sort-value attribute first
    if (cell.dataset.sortValue) {
      return cell.dataset.sortValue
    }

    // Otherwise use text content
    return cell.textContent.trim().toLowerCase()
  }

  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================

  /**
   * Update row visual state when selected/deselected
   */
  _updateRowSelection(checkbox, selected) {
    // Find the row element
    const row = checkbox.closest("tr") || checkbox.closest("[data-row-id]")
    if (!row) return

    // Toggle selected class
    if (selected) {
      row.classList.add(
        "bg-blue-50",
        "dark:bg-blue-900/30"
      )
    } else {
      row.classList.remove(
        "bg-blue-50",
        "dark:bg-blue-900/30"
      )
    }
  }

  /**
   * Update the selected IDs array
   */
  _updateSelectedIds(checkbox) {
    const id = checkbox.value
    const ids = [...this.selectedIdsValue]

    if (checkbox.checked) {
      if (!ids.includes(id)) {
        ids.push(id)
      }
    } else {
      const index = ids.indexOf(id)
      if (index > -1) {
        ids.splice(index, 1)
      }
    }

    this.selectedIdsValue = ids
  }

  /**
   * Dispatch custom selection event
   */
  _dispatchSelectionEvent() {
    this.dispatch("selection", {
      detail: {
        selectedIds: this.selectedIdsValue,
        count: this.selectedIdsValue.length
      }
    })
  }

  /**
   * Navigate to URL with sort parameters (for Turbo Frame)
   */
  _navigateToSortedUrl() {
    const url = new URL(window.location.href)
    url.searchParams.set("sort", this.sortColumnValue)
    url.searchParams.set("direction", this.sortDirectionValue)

    // Use Turbo to navigate within the frame
    const frame = document.getElementById(this.turboFrameValue)
    if (frame) {
      frame.src = url.toString()
    }
  }
}
