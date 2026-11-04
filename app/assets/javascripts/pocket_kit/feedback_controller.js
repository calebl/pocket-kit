import { Controller } from "@hotwired/stimulus"
import "pocket_kit"

// The feedback dialog for Rails apps: a thin wrapper over the browser core
// (pocket_kit.js). It opens and closes a native <dialog>, and on submit fills
// in what this browser says about the device it runs on and, when session
// replay is on, the recent page activity. Sending is an ordinary form post
// answered with a Turbo Stream; the server checks and caps every value before
// any of it is sent on.
export default class extends Controller {
  static targets = [ "dialog", "device", "replay" ]

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  describe() {
    const values = window.PocketKit.describeDevice()
    this.deviceTargets.forEach((input) => { input.value = values[input.dataset.field] ?? "" })
    if (this.hasReplayTarget) this.replayTarget.value = window.PocketKit.replayEvents() ?? ""
  }
}
