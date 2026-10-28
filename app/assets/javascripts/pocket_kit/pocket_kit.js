// pocket-kit's browser core. One plain file with no dependencies and no build
// step: load it as a classic <script> or import it as a module. It sets
// window.PocketKit and starts on its own:
//
// - Errors: when the page has <meta name="pocket-kit-errors" content="/path">,
//   uncaught errors and unhandled promise rejections are posted as JSON to that
//   same-origin path. Accepted errors are deduplicated per page, and at most
//   MAX_ERRORS_PER_PAGE posts are attempted.
// - Feedback: every element with data-pk-feedback="/path" gets a working
//   button and dialog (see the README for the markup); the note is posted as
//   JSON to that same-origin path. Rails apps use the Stimulus controller and
//   form instead, which share describeDevice() from here.
//
// Nothing is sent anywhere but the app's own paths.
(function () {
  "use strict"

  if (globalThis.PocketKit) return

  const MAX_ERRORS_PER_PAGE = 10
  const postedErrors = new Set()
  const pendingErrors = new Set()
  let errorAttempts = 0

  // What the browser says about the device; the server checks every value.
  function describeDevice() {
    const viewport = window.visualViewport
    return {
      user_agent: navigator.userAgent,
      screen: `${screen.width}x${screen.height}`,
      viewport: `${window.innerWidth}x${window.innerHeight}`,
      visual_viewport: viewport ? `${Math.round(viewport.width)}x${Math.round(viewport.height)}` : "",
      pixel_ratio: String(window.devicePixelRatio),
      standalone: String(window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true),
      color_scheme: window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
    }
  }

  function randomId() {
    if (crypto.randomUUID) return crypto.randomUUID()
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  }

  // Posts JSON to a path on this origin only, with the page's CSRF token if it has one.
  function post(path, payload) {
    const url = new URL(path, location.href)
    if (url.origin !== location.origin) return Promise.resolve(false)

    const headers = { "Content-Type": "application/json", Accept: "application/json" }
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) headers["X-CSRF-Token"] = token
    return fetch(url, { method: "POST", credentials: "same-origin", keepalive: true, headers,
                        body: JSON.stringify(payload) })
      .then((response) => response.ok, () => false)
  }

  function errorsPath() {
    return document.querySelector('meta[name="pocket-kit-errors"]')?.content
  }

  // Posts one error. Takes an Error or any thrown value.
  function reportError(error) {
    const path = errorsPath()
    if (!path) return Promise.resolve(false)

    const isError = error instanceof Error
    const payload = {
      kind: "error",
      class: isError ? error.name || "Error" : "UnhandledRejection",
      message: String(isError ? error.message : error).slice(0, 1000),
      stack: isError && error.stack ? String(error.stack).slice(0, 5000) : "",
      page: location.pathname,
      screen: document.querySelector('meta[name="pocket-kit-screen"]')?.content || null
    }
    const key = `${payload.class}\n${payload.message}\n${payload.stack.split("\n", 2).join("\n")}`
    if (postedErrors.has(key) || pendingErrors.has(key) || errorAttempts >= MAX_ERRORS_PER_PAGE) {
      return Promise.resolve(false)
    }

    pendingErrors.add(key)
    errorAttempts += 1
    return post(path, payload).then((ok) => {
      pendingErrors.delete(key)
      if (ok) postedErrors.add(key)
      return ok
    })
  }

  function captureErrors() {
    window.addEventListener("error", (event) => {
      // Errors from other origins' scripts arrive as "Script error." with nothing in them.
      if (event.error) reportError(event.error)
      else if (event.message && event.message !== "Script error.") reportError(new Error(event.message))
    })
    window.addEventListener("unhandledrejection", (event) => reportError(event.reason))
  }

  // Wires one data-pk-feedback element: [data-pk-open] opens its <dialog>,
  // [data-pk-close] closes it, and the <form> inside posts the note.
  function feedback(root) {
    if (root.pocketKitFeedback) return
    root.pocketKitFeedback = true

    const dialog = root.querySelector("dialog")
    const form = root.querySelector("form")
    const sent = root.querySelector("[data-pk-sent]")
    const failed = root.querySelector("[data-pk-failed]")
    const show = (element, visible) => { if (element) element.hidden = !visible }
    show(sent, false)
    show(failed, false)

    root.querySelector("[data-pk-open]")?.addEventListener("click", () => {
      show(sent, false)
      dialog.showModal()
    })
    root.querySelector("[data-pk-close]")?.addEventListener("click", () => dialog.close())
    form.addEventListener("submit", (event) => {
      event.preventDefault()
      show(failed, false)
      const payload = {
        kind: "feedback",
        text: form.elements.text.value,
        screen: root.dataset.pkScreen || null,
        request_id: randomId(),
        device: describeDevice()
      }
      post(root.dataset.pkFeedback, payload).then((ok) => {
        if (ok) {
          form.reset()
          dialog.close()
        }
        show(sent, ok)
        show(failed, !ok)
      })
    })
  }

  function start() {
    document.querySelectorAll("[data-pk-feedback]").forEach(feedback)
  }

  globalThis.PocketKit = { describeDevice, reportError, feedback, start }

  captureErrors()
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start)
  else start()
  document.addEventListener("turbo:load", start)
})()
