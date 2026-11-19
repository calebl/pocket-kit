// pocket-kit's pinned viewport. One plain file with no dependencies and no
// build step: load it as a classic <script> or import it as a module. It sets
// window.PocketKitViewport and starts on its own.
//
// iPhone Safari shrinks the visible area when the on-screen keyboard opens
// without shrinking the page, so a sticky header can scroll out of view and a
// bottom composer can end up under the keyboard. With
// <body data-pk-viewport> (and viewport.css), the body is fixed to exactly the
// visible area: this file keeps --pk-visible-top and --pk-visible-height on
// <html> in step with window.visualViewport, so the header stays at the top and
// a bottom composer sits just above the keyboard. Content scrolls inside an
// element marked data-pk-scroll.
//
// It also stops iOS WebKit from panning the whole page when an empty text field
// is tapped or the page is dragged outside a scroller, which would slide even a
// fixed header off screen.
//
// Without visualViewport, or without the data-pk-viewport attribute, it does
// nothing and the CSS falls back to the full layout viewport.
(function () {
  "use strict"

  if (globalThis.PocketKitViewport) return

  const TEXT_INPUT_TYPES = new Set([ "", "text", "search", "email", "url", "tel", "password", "number" ])
  let cleanup = null

  // The top and height, in CSS pixels, the pinned body should take: the visible
  // area. offsetTop is normally 0; it is only non-zero if Safari panned the
  // page anyway, and following it keeps the header in sight. Returns null when
  // there is nothing usable to go by.
  function visibleBox(viewport) {
    if (!viewport) return null

    const height = Number(viewport.height)
    if (!Number.isFinite(height) || height <= 0) return null

    const top = Number(viewport.offsetTop)
    return { top: Number.isFinite(top) && top > 0 ? top : 0, height }
  }

  // Whether a tap on a text field should be taken over (focus without
  // scrolling) instead of left to WebKit. Only the first tap into an empty
  // field is: once it is focused or has text, native handling places the caret
  // where the user tapped.
  function shouldInterceptTap({ textField, focused, hasValue }) {
    return Boolean(textField) && !focused && !hasValue
  }

  // Whether a one-finger drag should be cancelled so it cannot pan the page.
  // Drags inside a scroller, over a text field that scrolls, or while text is
  // selected (moving selection handles) are left alone, as are pinches.
  function shouldBlockTouchMove({ touches, inScroller, selectionCollapsed, scrollableField }) {
    if (touches > 1) return false
    if (inScroller) return false
    if (!selectionCollapsed) return false
    if (scrollableField) return false
    return true
  }

  function isTextField(element) {
    if (!element || element.disabled || element.readOnly) return false
    if (element.tagName === "TEXTAREA") return true
    if (element.tagName === "INPUT") return TEXT_INPUT_TYPES.has((element.getAttribute("type") || "").toLowerCase())
    return false
  }

  function pinned() {
    return Boolean(document.body && document.body.hasAttribute("data-pk-viewport"))
  }

  function fit() {
    const box = visibleBox(window.visualViewport)
    if (!box || !pinned()) return

    const root = document.documentElement.style
    root.setProperty("--pk-visible-top", `${box.top}px`)
    root.setProperty("--pk-visible-height", `${box.height}px`)
  }

  function onTouchEnd(event) {
    if (!pinned()) return

    const field = event.target
    if (!shouldInterceptTap({
      textField: isTextField(field),
      focused: document.activeElement === field,
      hasValue: Boolean(field && field.value)
    })) return

    event.preventDefault()
    field.focus({ preventScroll: true })
  }

  function onTouchMove(event) {
    if (!pinned()) return

    const target = event.target
    const selection = document.getSelection()
    if (shouldBlockTouchMove({
      touches: event.touches ? event.touches.length : 1,
      inScroller: Boolean(target && target.closest && target.closest("[data-pk-scroll]")),
      selectionCollapsed: !selection || selection.isCollapsed,
      scrollableField: isTextField(target) && target.scrollHeight > target.clientHeight
    })) event.preventDefault()
  }

  // Starts following the visible area. Safe to call again (for example after a
  // Turbo visit replaces <body>); returns stop().
  function start() {
    if (cleanup) {
      fit()
      return stop
    }
    const viewport = window.visualViewport
    if (!viewport) return stop

    const active = { passive: false }
    window.addEventListener("resize", fit)
    viewport.addEventListener("resize", fit)
    viewport.addEventListener("scroll", fit)
    document.addEventListener("touchend", onTouchEnd, active)
    document.addEventListener("touchmove", onTouchMove, active)
    cleanup = () => {
      window.removeEventListener("resize", fit)
      viewport.removeEventListener("resize", fit)
      viewport.removeEventListener("scroll", fit)
      document.removeEventListener("touchend", onTouchEnd, active)
      document.removeEventListener("touchmove", onTouchMove, active)
    }
    fit()
    return stop
  }

  // Removes every listener and the custom properties, so the CSS falls back.
  function stop() {
    if (!cleanup) return
    cleanup()
    cleanup = null
    const root = document.documentElement.style
    root.removeProperty("--pk-visible-top")
    root.removeProperty("--pk-visible-height")
  }

  globalThis.PocketKitViewport = { visibleBox, shouldInterceptTap, shouldBlockTouchMove, start, stop }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start)
  else start()
  document.addEventListener("turbo:load", start)
})()
