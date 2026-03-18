import { Controller } from "@hotwired/stimulus"

/**
 * Upload Controller
 * @gem rapid_rails_ui
 * @version 0.31.0
 * @updated 2026-01-17
 *
 * Handles file upload functionality with drag & drop support, preview, and validation.
 *
 * Targets:
 * - input: File input element
 * - dropzone: Dropzone container (optional, only in dropzone mode)
 * - preview: Preview container
 * - summary: Summary display (file count + total size)
 * - error: Error message element
 *
 * Values:
 * - multiple (Boolean): Allow multiple file selection
 * - maxFiles (Number): Maximum number of files allowed
 * - maxFileSize (Number): Maximum file size in bytes
 * - accept (String): Accepted MIME types (comma-separated)
 */
export default class extends Controller {
  static targets = ["input", "dropzone", "preview", "summary", "error"]
  static values = {
    multiple: { type: Boolean, default: false },
    maxFiles: { type: Number, default: 10 },
    maxFileSize: { type: Number, default: 10485760 }, // 10 MB
    accept: { type: String, default: "" }
  }

  connect() {
    this.files = []
  }

  disconnect() {
    this.files = []
  }

  // Trigger file input when dropzone is clicked
  triggerFileInput(event) {
    event.preventDefault()
    this.inputTarget.click()
  }

  // Handle file selection from input
  selectFiles(event) {
    const selectedFiles = Array.from(event.target.files || [])
    this.#processFiles(selectedFiles)
  }

  // Handle drag over (show visual feedback)
  handleDragOver(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.add("border-blue-500", "dark:border-blue-400", "bg-blue-50", "dark:bg-blue-900/20")
    }
  }

  // Handle drag leave (remove visual feedback)
  handleDragLeave(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.remove("border-blue-500", "dark:border-blue-400", "bg-blue-50", "dark:bg-blue-900/20")
    }
  }

  // Handle file drop
  handleDrop(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.remove("border-blue-500", "dark:border-blue-400", "bg-blue-50", "dark:bg-blue-900/20")
    }

    const droppedFiles = Array.from(event.dataTransfer?.files || [])
    this.#processFiles(droppedFiles)
  }

  // Remove file from preview
  removeFile(event) {
    event.preventDefault()
    const button = event.currentTarget
    const fileName = button.dataset.fileName
    const fileItem = this.previewTarget.querySelector(`[data-file-name="${fileName}"]`)

    if (fileItem) {
      fileItem.remove()
      this.files = this.files.filter(f => f.name !== fileName)
      this.#updateSummary()
      this.#togglePreviewVisibility()
    }
  }

  // Private methods

  #processFiles(fileList) {
    this.#clearError()

    // Validate file count
    if (fileList.length > this.maxFilesValue) {
      this.#showError(`Maximum ${this.maxFilesValue} files allowed. You selected ${fileList.length} files.`)
      this.inputTarget.value = ""
      return
    }

    // Clear preview if not multiple
    if (!this.multipleValue) {
      this.files = []
      this.previewTarget.innerHTML = ""
    }

    // Validate and add files
    fileList.forEach(file => {
      if (this.#validateFile(file)) {
        this.files.push(file)
        this.#displayPreview(file)
      }
    })

    this.#updateSummary()
    this.#togglePreviewVisibility()
  }

  #validateFile(file) {
    // Check file size
    if (file.size > this.maxFileSizeValue) {
      this.#showError(`${file.name} exceeds maximum size of ${this.#formatSize(this.maxFileSizeValue)}`)
      return false
    }

    // Check file type
    if (this.acceptValue && !this.#isValidType(file)) {
      this.#showError(`${file.name} is not an accepted file type`)
      return false
    }

    return true
  }

  #isValidType(file) {
    if (!this.acceptValue) return true
    const accepted = this.acceptValue.split(",").map(t => t.trim())
    return accepted.some(type => type.includes("/*")
      ? file.type.startsWith(type.split("/")[0])
      : file.type === type)
  }

  #displayPreview(file) {
    const isImage = file.type.startsWith("image/")

    if (isImage) {
      const reader = new FileReader()
      reader.onload = (e) => {
        const item = this.#createPreviewElement(file, e.target.result)
        this.previewTarget.appendChild(item)
      }
      reader.readAsDataURL(file)
    } else {
      const item = this.#createPreviewElement(file, null)
      this.previewTarget.appendChild(item)
    }
  }

  #createPreviewElement(file, imageSrc) {
    // Create container
    const container = document.createElement("div")
    container.className = "relative group border border-zinc-200 dark:border-zinc-700 rounded-lg p-3 bg-white dark:bg-zinc-800"
    container.dataset.fileName = file.name

    // Create preview (image or file icon)
    if (imageSrc) {
      const img = document.createElement("img")
      img.src = imageSrc
      img.className = "w-full h-24 object-cover rounded-lg mb-2"
      img.alt = file.name
      container.appendChild(img)
    } else {
      const iconDiv = document.createElement("div")
      iconDiv.className = "w-full h-24 flex items-center justify-center bg-zinc-100 dark:bg-zinc-700 rounded-lg mb-2"
      const ext = document.createElement("span")
      ext.className = "text-2xl font-bold text-zinc-400 dark:text-zinc-500"
      ext.textContent = `.${file.name.split(".").pop()}`
      iconDiv.appendChild(ext)
      container.appendChild(iconDiv)
    }

    // File name
    const nameP = document.createElement("p")
    nameP.className = "text-xs font-medium text-zinc-700 dark:text-zinc-300 truncate"
    nameP.title = file.name
    nameP.textContent = file.name
    container.appendChild(nameP)

    // File size
    const sizeP = document.createElement("p")
    sizeP.className = "text-xs text-zinc-500 dark:text-zinc-400"
    sizeP.textContent = this.#formatSize(file.size)
    container.appendChild(sizeP)

    // Remove button
    const button = document.createElement("button")
    button.type = "button"
    button.className = "absolute top-1 right-1 bg-red-500 hover:bg-red-600 text-white rounded-full p-1 opacity-0 group-hover:opacity-100 transition-opacity"
    button.dataset.action = "click->upload#removeFile"
    button.dataset.fileName = file.name

    // X icon SVG
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("class", "w-4 h-4")
    svg.setAttribute("viewBox", "0 0 20 20")
    svg.setAttribute("fill", "currentColor")
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("fill-rule", "evenodd")
    path.setAttribute("d", "M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z")
    path.setAttribute("clip-rule", "evenodd")
    svg.appendChild(path)
    button.appendChild(svg)
    container.appendChild(button)

    return container
  }

  #updateSummary() {
    if (!this.hasSummaryTarget) return
    const totalSize = this.files.reduce((sum, f) => sum + f.size, 0)
    this.summaryTarget.textContent = `${this.files.length} file(s), ${this.#formatSize(totalSize)}`
  }

  #togglePreviewVisibility() {
    const isEmpty = this.files.length === 0
    this.previewTarget.classList.toggle("hidden", isEmpty)
    if (this.hasSummaryTarget) {
      this.summaryTarget.classList.toggle("hidden", isEmpty)
    }
  }

  #formatSize(bytes) {
    if (bytes === 0) return "0 B"
    const units = ["B", "KB", "MB", "GB"]
    const i = Math.floor(Math.log(bytes) / Math.log(1024))
    return `${(bytes / Math.pow(1024, i)).toFixed(1)} ${units[i]}`
  }

  #showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message
    }
  }

  #clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = ""
    }
  }
}
