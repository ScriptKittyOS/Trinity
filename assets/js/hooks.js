/* SPDX-FileCopyrightText: Sudo Apt Holdings LLC */
/* SPDX-License-Identifier: Apache-2.0 */
// The chat's four hooks (slice 013). Each is a few lines and does one thing the server
// cannot: read a key with its modifiers, keep the message list pinned to the bottom, show a
// time in the viewer's zone, or tell Enter from Shift+Enter.

// Enter sends, Shift+Enter breaks the line; the server clears the box after a send.
export const Composer = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        this.el.form.requestSubmit()
      }
    })
    this.el.addEventListener("input", () => this.grow())
    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.grow()
      this.el.focus()
    })
    this.el.focus()
  },
  updated() {
    if (!this.el.disabled) this.el.focus()
  },
  grow() {
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, 192) + "px"
  },
}

// Ctrl/Cmd+K opens a new session, Esc cancels the turn. Nothing else reaches the server.
export const Shortcuts = {
  mounted() {
    this.onKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        this.pushEvent("new_session", {})
      } else if (e.key === "Escape") {
        this.pushEvent("cancel", {})
      }
    }
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },
}

// The message list follows new content unless the reader has scrolled up to read.
export const ScrollToBottom = {
  mounted() {
    // A compaction card's "view the original" dispatches trinity:scroll-to with a seq (slice 023).
    window.addEventListener("trinity:scroll-to", (e) => {
      const target = this.el.querySelector(`[data-seq="${e.detail.seq}"]`)
      if (target) { this.pinned = false; target.scrollIntoView({behavior: "smooth", block: "center"}) }
    })
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinned = gap < 48
    })
    this.scroll()
    this.observer = new MutationObserver(() => this.scroll())
    this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
  },
  updated() {
    this.scroll()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scroll() {
    if (this.pinned) this.el.scrollTop = this.el.scrollHeight
  },
}

// A <time datetime="..."> rendered as UTC by the server, rewritten in the viewer's zone.
export const LocalTime = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    const at = new Date(this.el.getAttribute("datetime"))
    if (isNaN(at)) return
    const time = {hour: "2-digit", minute: "2-digit"}
    this.el.textContent = this.el.dataset.format === "datetime"
      ? at.toLocaleDateString([], {year: "numeric", month: "short", day: "numeric"}) + " " + at.toLocaleTimeString([], time)
      : at.toLocaleTimeString([], time)
  },
}
