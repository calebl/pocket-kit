// Plays a session replay saved by pocket-kit (a JSON file of rrweb events)
// with the vendored rrweb player, which must load first. Used by the engine's
// replay pages and by viewer/replay.html. Nothing is fetched from anywhere but
// the page's own origin, and a picked file never leaves the browser.
//
// Markup: an element with data-pk-replay-viewer holding [data-pk-replay-stage]
// for the player, [data-pk-replay-status] for messages, and optionally
// <input type="file" data-pk-replay-file>. A data-pk-replay-src="/path" on the
// root plays that replay at once.
(function () {
  "use strict"

  function viewer(root) {
    const stage = root.querySelector("[data-pk-replay-stage]")
    const status = root.querySelector("[data-pk-replay-status]")
    const say = (text) => { if (status) status.textContent = text }

    function play(events) {
      if (!Array.isArray(events) || !events.some((event) => event && event.type === 2)) {
        say("This file is not a pocket-kit replay.")
        return
      }
      const Player = globalThis.rrwebPlayer.default || globalThis.rrwebPlayer
      stage.replaceChildren()
      new Player({ target: stage, props: { events, width: Math.min(stage.clientWidth || 800, 1024), autoPlay: true } })
      root.dataset.pkReplayLoaded = String(events.length)
      say(`${events.length} events, ${Math.round((events.at(-1).timestamp - events[0].timestamp) / 1000)} seconds.`)
    }

    function load(text) {
      try {
        play(JSON.parse(text))
      } catch {
        say("This file is not a pocket-kit replay.")
      }
    }

    root.querySelector("[data-pk-replay-file]")?.addEventListener("change", (event) => {
      const file = event.target.files[0]
      if (file) file.text().then(load)
    })

    const src = root.dataset.pkReplaySrc
    if (src) {
      const url = new URL(src, location.href)
      if (url.origin !== location.origin) return say("Replays load only from this app.")
      fetch(url, { credentials: "same-origin", headers: { Accept: "application/json" } })
        .then((response) => (response.ok ? response.text() : Promise.reject(new Error(String(response.status)))))
        .then(load, () => say("Couldn't load this replay."))
    }
  }

  function start() {
    document.querySelectorAll("[data-pk-replay-viewer]").forEach(viewer)
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start)
  else start()
})()
