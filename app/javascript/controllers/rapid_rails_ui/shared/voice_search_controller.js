import { Controller } from "@hotwired/stimulus"

/**
 * Voice Search Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Reusable controller for voice input using the Web Speech API.
 * Provides start/stop/toggle actions and visual feedback.
 *
 * Usage:
 *   <div data-controller="voice-search"
 *        data-voice-search-lang-value="en-US">
 *     <button data-voice-search-target="button"
 *             data-action="click->voice-search#toggle">
 *       <svg>...</svg>
 *     </button>
 *   </div>
 *
 * Can be composed with other controllers:
 *   <div data-controller="live-search voice-search"
 *        data-action="voice-search:result->live-search#onVoiceResult">
 *
 * Events dispatched:
 *   - voice-search:start - when listening starts
 *   - voice-search:end - when listening ends
 *   - voice-search:result - { transcript } when speech recognized
 *   - voice-search:error - { error } on error
 *   - voice-search:unsupported - when browser doesn't support Speech API
 */
export default class extends Controller {
  static targets = ["button"]

  static values = {
    lang: { type: String, default: "" }
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  connect() {
    this.recognition = null
    this.isListening = false
  }

  disconnect() {
    this.stop()
  }

  // ==========================================================================
  // PUBLIC ACTIONS
  // ==========================================================================

  /**
   * Start voice recognition
   */
  async start(event) {
    if (event) event.preventDefault()

    // Check browser support
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SpeechRecognition) {
      this.dispatch("unsupported")
      console.warn("[VoiceSearch] Speech recognition not supported in this browser")
      return
    }

    // If already listening, ignore
    if (this.recognition && this.isListening) {
      return
    }

    // Check microphone permission first
    try {
      const permissionStatus = await navigator.permissions.query({ name: "microphone" })
      if (permissionStatus.state === "denied") {
        console.warn("[VoiceSearch] Microphone permission denied")
        this.dispatch("error", { detail: { error: "not-allowed" } })
        return
      }
    } catch (e) {
      // permissions.query may not be supported, continue anyway
    }

    // Create recognition instance
    this.recognition = new SpeechRecognition()
    this.recognition.continuous = false
    this.recognition.interimResults = false
    this.recognition.lang = this.langValue || document.documentElement.lang || "en-US"

    // Track if we got a result (to avoid double-stop from onend)
    this.gotResult = false

    // Handle result
    this.recognition.onresult = (event) => {
      const transcript = event.results[0][0].transcript
      console.log("[VoiceSearch] Result:", transcript)
      this.gotResult = true
      this.dispatch("result", { detail: { transcript } })
      this.stop()
    }

    // Handle errors
    this.recognition.onerror = (event) => {
      console.warn("[VoiceSearch] Error:", event.error)
      this.dispatch("error", { detail: { error: event.error } })
      // Don't call stop() here - onend will fire and handle cleanup
    }

    // Handle end (fires after result, error, or timeout)
    this.recognition.onend = () => {
      console.log("[VoiceSearch] Recognition ended, gotResult:", this.gotResult)
      this.stop()
    }

    // Handle audio start (confirms mic is working)
    this.recognition.onaudiostart = () => {
      console.log("[VoiceSearch] Audio capture started - mic is active")
    }

    // Start listening UI immediately
    this.isListening = true
    this.setListeningState(true)
    this.dispatch("start")

    // Start recognition
    try {
      console.log("[VoiceSearch] Starting recognition...")
      this.recognition.start()
    } catch (e) {
      console.error("[VoiceSearch] Failed to start:", e)
      this.stop()
    }
  }

  /**
   * Stop voice recognition
   */
  stop(event) {
    if (event) event.preventDefault()

    if (this.recognition) {
      try {
        this.recognition.stop()
      } catch (e) {
        // Ignore - may already be stopped
      }
      this.recognition = null
    }

    if (this.isListening) {
      this.isListening = false
      this.setListeningState(false)
      this.dispatch("end")
    }
  }

  /**
   * Toggle voice recognition on/off
   */
  toggle(event) {
    if (event) event.preventDefault()

    if (this.isListening) {
      this.stop()
    } else {
      this.start()
    }
  }

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  /**
   * Check if currently listening
   * @returns {boolean}
   */
  isActive() {
    return this.isListening
  }

  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================

  /**
   * Update button visual state
   * @param {boolean} listening
   */
  setListeningState(listening) {
    if (!this.hasButtonTarget) return

    if (listening) {
      // Active state - red pulsing
      this.buttonTarget.classList.add("text-red-500", "dark:text-red-400", "animate-pulse")
      this.buttonTarget.classList.remove("text-zinc-400", "dark:text-zinc-500")
    } else {
      // Inactive state - gray
      this.buttonTarget.classList.remove("text-red-500", "dark:text-red-400", "animate-pulse")
      this.buttonTarget.classList.add("text-zinc-400", "dark:text-zinc-500")
    }
  }
}
