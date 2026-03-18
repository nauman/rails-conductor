import { Controller } from "@hotwired/stimulus"

/**
 * LiveSearch Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Core search controller with debounce, form submission, modal support,
 * and keyboard shortcuts.
 *
 * Usage (basic inline):
 *   <div data-controller="live-search"
 *        data-live-search-debounce-value="300">
 *     <form data-live-search-target="form" data-turbo-frame="results">
 *       <input data-live-search-target="input"
 *              data-action="input->live-search#search">
 *     </form>
 *   </div>
 *
 * Usage (modal):
 *   <div data-controller="live-search"
 *        data-live-search-modal-value="true"
 *        data-live-search-shortcut-value="k">
 *
 * Events dispatched:
 *   - live-search:before-search - Before form submits (cancelable)
 *   - live-search:after-search - After form submitted
 *   - live-search:cleared - After input cleared
 *   - live-search:shortcut-triggered - When keyboard shortcut triggered
 *   - live-search:modal-opened - When modal dialog opened
 *   - live-search:modal-closed - When modal dialog closed
 */
export default class extends Controller {
  static targets = [
    "form",
    "input",
    "clearButton",
    "loadingIndicator",
    "searchButton",
    "shortcutHint",
    "shortcutText",
    "emptyState",
    "dialog",
    "modalTrigger",
    "resultsContainer",
    "modalEmptyState",
    "recentDropdown"
  ]

  static values = {
    debounce: { type: Number, default: 300 },
    minLength: { type: Number, default: 1 },
    disabled: { type: Boolean, default: false },
    shortcut: { type: String, default: "" },
    modal: { type: Boolean, default: false }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this.debounceTimer = null
    this.isLoading = false
    this.pendingQuery = null
    this.isMac = navigator.platform.toUpperCase().indexOf("MAC") >= 0

    this.updateClearButtonVisibility()
    this.setupShortcutHint()

    // Global keyboard shortcut (modal mode only)
    if (this.shortcutValue && this.modalValue && !this.boundHandleGlobalKeydown) {
      this.boundHandleGlobalKeydown = this.handleGlobalKeydown.bind(this)
      document.addEventListener("keydown", this.boundHandleGlobalKeydown)
    }

    // Turbo Frame load listener
    if (!this.boundHandleFrameLoad) {
      this.boundHandleFrameLoad = this.handleFrameLoad.bind(this)
      document.addEventListener("turbo:frame-load", this.boundHandleFrameLoad)
    }

    // Form submit listener
    if (this.hasFormTarget && !this.boundHandleFormSubmit) {
      this.boundHandleFormSubmit = this.handleFormSubmit.bind(this)
      this.formTarget.addEventListener("submit", this.boundHandleFormSubmit)
    }
  }

  disconnect() {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = null
    }

    if (this.boundHandleFrameLoad) {
      document.removeEventListener("turbo:frame-load", this.boundHandleFrameLoad)
      this.boundHandleFrameLoad = null
    }

    if (this.boundHandleGlobalKeydown) {
      document.removeEventListener("keydown", this.boundHandleGlobalKeydown)
      this.boundHandleGlobalKeydown = null
    }

    if (this.hasFormTarget && this.boundHandleFormSubmit) {
      this.formTarget.removeEventListener("submit", this.boundHandleFormSubmit)
      this.boundHandleFormSubmit = null
    }
  }

  // ==========================================================================
  // PUBLIC ACTIONS - SEARCH
  // ==========================================================================

  search(event) {
    if (this.disabledValue) return

    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
    }

    this.updateClearButtonVisibility()

    const query = this.inputTarget.value.trim()
    if (query.length < this.minLengthValue && query.length > 0) {
      return
    }

    this.debounceTimer = setTimeout(() => {
      this.submitSearch()
    }, this.debounceValue)
  }

  clear(event) {
    if (event) event.preventDefault()
    if (this.disabledValue) return

    this.inputTarget.value = ""
    this.updateClearButtonVisibility()
    this.submitSearch()
    this.inputTarget.focus()

    this.dispatch("cleared")
  }

  onEnterKey(event) {
    const highlightNav = this.application.getControllerForElementAndIdentifier(
      this.element,
      "css-highlight-nav"
    )

    if (highlightNav && highlightNav.hasHighlight()) {
      return
    }
  }

  onEscapeKey(event) {
    if (this.modalValue && this.hasDialogTarget && this.dialogTarget.open) {
      return
    }

    if (this.hasClearButtonTarget && this.inputTarget.value.length > 0) {
      event.preventDefault()
      this.clear()
    }
  }

  // ==========================================================================
  // PUBLIC ACTIONS - COMPOSED CONTROLLER EVENTS
  // ==========================================================================

  onRecentSelected(event) {
    const { query } = event.detail
    if (!query) return

    this.inputTarget.value = query
    this.updateClearButtonVisibility()
    this.submitSearch()
  }

  onVoiceResult(event) {
    const { transcript } = event.detail
    if (!transcript) return

    this.inputTarget.value = transcript
    this.updateClearButtonVisibility()
    this.submitSearch()
  }

  onResultSelected(event) {
    if (this.modalValue) {
      this.closeModal()
    }
  }

  // ==========================================================================
  // PUBLIC ACTIONS - MODAL
  // ==========================================================================

  openModal(event) {
    if (event) event.preventDefault()
    if (!this.hasDialogTarget) return

    this.dialogTarget.showModal()

    requestAnimationFrame(() => {
      if (this.hasInputTarget) {
        this.inputTarget.focus()
        this.inputTarget.select()
      }
      this.updateClearButtonVisibility()
    })

    this.boundHandleBackdropClick = this.handleBackdropClick.bind(this)
    this.dialogTarget.addEventListener("click", this.boundHandleBackdropClick)

    this.dispatch("modal-opened")
  }

  closeModal(event) {
    if (event) event.preventDefault()
    if (!this.hasDialogTarget) return

    this.dialogTarget.close()

    if (this.boundHandleBackdropClick) {
      this.dialogTarget.removeEventListener("click", this.boundHandleBackdropClick)
    }

    this.dispatch("modal-closed")
  }

  // ==========================================================================
  // PRIVATE - SEARCH SUBMISSION
  // ==========================================================================

  submitSearch() {
    const beforeEvent = this.dispatch("before-search", {
      cancelable: true,
      detail: { query: this.inputTarget.value }
    })

    if (beforeEvent.defaultPrevented) return

    this.pendingQuery = this.inputTarget.value
    this.showLoading()
    this.resetHighlightNav()

    if (this.hasFormTarget) {
      this.formTarget.requestSubmit()
    }
  }

  resetHighlightNav() {
    const highlightNav = this.application.getControllerForElementAndIdentifier(
      this.element,
      "css-highlight-nav"
    )
    if (highlightNav) highlightNav.reset()
  }

  // ==========================================================================
  // PRIVATE - UI UPDATES
  // ==========================================================================

  updateClearButtonVisibility() {
    const hasValue = this.hasInputTarget && this.inputTarget.value.length > 0

    if (this.hasClearButtonTarget) {
      this.clearButtonTarget.classList.toggle("hidden", !hasValue)
    }

    if (this.hasShortcutHintTarget) {
      this.shortcutHintTarget.classList.toggle("hidden", hasValue)
    }

    // Modal: toggle empty state vs results container
    if (this.modalValue) {
      if (hasValue) {
        if (this.hasModalEmptyStateTarget) {
          this.modalEmptyStateTarget.classList.add("hidden")
        }
        if (this.hasResultsContainerTarget) {
          this.resultsContainerTarget.classList.remove("hidden")
        }
      } else {
        if (this.hasResultsContainerTarget) {
          this.resultsContainerTarget.classList.add("hidden")
        }
        if (this.hasModalEmptyStateTarget) {
          this.modalEmptyStateTarget.classList.remove("hidden")
        }
      }
    }
  }

  showLoading() {
    if (!this.hasLoadingIndicatorTarget) return

    this.isLoading = true
    this.loadingIndicatorTarget.classList.remove("hidden")

    if (this.hasClearButtonTarget) {
      this.clearButtonTarget.classList.add("hidden")
    }
  }

  hideLoading() {
    if (!this.hasLoadingIndicatorTarget) return

    this.isLoading = false
    this.loadingIndicatorTarget.classList.add("hidden")
    this.updateClearButtonVisibility()
  }

  setupShortcutHint() {
    if (!this.hasShortcutTextTarget || !this.shortcutValue) return

    const key = this.shortcutValue.toUpperCase()
    const modifier = this.isMac ? "⌘" : "Ctrl+"
    this.shortcutTextTarget.textContent = `${modifier}${key}`
  }

  // ==========================================================================
  // PRIVATE - EVENT HANDLERS
  // ==========================================================================

  handleGlobalKeydown(event) {
    if (!this.shortcutValue) return

    const isModifierPressed = this.isMac ? event.metaKey : event.ctrlKey
    const isShortcutKey = event.key.toLowerCase() === this.shortcutValue.toLowerCase()

    if (isModifierPressed && isShortcutKey) {
      event.preventDefault()

      if (this.modalValue) {
        this.openModal()
      } else if (this.hasInputTarget) {
        this.inputTarget.focus()
        this.inputTarget.select()
      }

      this.dispatch("shortcut-triggered", {
        detail: { shortcut: this.shortcutValue }
      })
    }
  }

  handleFormSubmit(event) {
    this.pendingQuery = this.inputTarget.value
    this.showLoading()

    this.dispatch("before-search", {
      detail: { query: this.inputTarget.value }
    })
  }

  handleFrameLoad(event) {
    if (!this.hasFormTarget) return

    const targetFrame = this.formTarget.getAttribute("data-turbo-frame")
    if (event.target.id === targetFrame) {
      this.hideLoading()

      this.dispatch("after-search", {
        detail: { query: this.pendingQuery || "" }
      })
      this.pendingQuery = null
    }
  }

  handleBackdropClick(event) {
    if (event.target === this.dialogTarget) {
      this.closeModal()
    }
  }
}
