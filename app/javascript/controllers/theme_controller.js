/**
 * RapidRailsUI Theme Controller
 *
 * Manages theme switching with OS detection and persistence.
 * Based on rc_mood_controller.js from RapidCascade.
 *
 * @example
 * <div data-controller="theme">
 *   <input type="checkbox"
 *          data-theme-target="checkbox"
 *          data-action="change->theme#toggle">
 *   <label data-action="dblclick->theme#resetToAuto">
 *     Toggle Dark Mode
 *   </label>
 * </div>
 */

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  // Stimulus targets
  static targets = ["checkbox"]

  // Stimulus values for configuration
  static values = {
    storageKey: { type: String, default: "rui-theme" }
  }

  // Internal theme state
  theme = "light"

  connect() {
    this.loadTheme()
    this.applyTheme()
    this.startWatchingOS()
  }

  disconnect() {
    this.stopWatchingOS()
  }

  // Load theme from storage or OS preference
  loadTheme() {
    const saved = localStorage.getItem(this.storageKeyValue)

    if (saved) {
      this.theme = saved
    } else if (this.prefersDarkMode()) {
      this.theme = "dark"
    } else {
      this.theme = "light"
    }
  }

  // Check OS dark mode preference
  prefersDarkMode() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches
  }

  // Start watching for OS preference changes
  startWatchingOS() {
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.osChangeHandler = () => this.handleOSChange()
    this.mediaQuery.addEventListener("change", this.osChangeHandler)
  }

  // Stop watching OS changes
  stopWatchingOS() {
    if (this.mediaQuery && this.osChangeHandler) {
      this.mediaQuery.removeEventListener("change", this.osChangeHandler)
    }
  }

  // Handle OS preference change
  handleOSChange() {
    this.theme = this.prefersDarkMode() ? "dark" : "light"
    this.saveTheme()
    this.applyTheme()
  }

  // Action: Toggle theme
  toggle(event) {
    this.theme = event.target.checked ? "dark" : "light"
    this.saveTheme()
    this.applyTheme()
  }

  // Action: Reset to OS preference
  resetToAuto() {
    localStorage.removeItem(this.storageKeyValue)
    this.loadTheme()
    this.applyTheme()
  }

  // Save theme to localStorage
  saveTheme() {
    localStorage.setItem(this.storageKeyValue, this.theme)
  }

  // Apply theme to document
  applyTheme() {
    const root = document.documentElement
    const isDark = this.theme === "dark"

    // Set attributes for CSS
    root.setAttribute("data-theme", this.theme)
    root.style.colorScheme = this.theme

    // Update checkbox if exists
    if (this.hasCheckboxTarget) {
      this.checkboxTarget.checked = isDark
    }

    // Dispatch custom event
    this.dispatch("changed", { detail: { theme: this.theme } })
  }
}
