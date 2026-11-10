// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ssm"
import topbar from "../vendor/topbar"

// Copy-to-clipboard: <button phx-hook="CopyToClipboard" data-copy="...">.
// Sets data-copied for ~1.5s so markup can swap icon/label via CSS or :if.
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy
      if (!text) return
      navigator.clipboard.writeText(text).then(() => {
        this.el.setAttribute("data-copied", "true")
        setTimeout(() => this.el.removeAttribute("data-copied"), 1500)
      })
    })
  },
}

// Searchable select (<.input type="select" searchable>): typing in the
// field above the select hides the options that do not match and shows the
// rest as an open list; Enter or a click picks one (a normal "change" event,
// so phx-change sees it), Escape clears. Only attributes are toggled, so a
// LiveView patch simply restores the options and updated() re-applies.
const SelectSearch = {
  mounted() {
    this.input = this.el.querySelector("[data-select-search]")
    // typing here is not a form change: keep it away from phx-change
    for (const type of ["input", "change"]) {
      this.input.addEventListener(type, e => {
        e.stopPropagation()
        if (type === "input") this.apply()
      })
    }
    this.input.addEventListener("keydown", e => {
      if (e.key === "Enter") { e.preventDefault(); this.pick(this.visible()[0]) }
      if (e.key === "ArrowDown") { e.preventDefault(); this.select().focus() }
      if (e.key === "Escape" && this.input.value) { e.preventDefault(); this.clear() }
    })
    this.el.addEventListener("change", e => {
      if (e.target === this.select() && this.input.value) this.clear()
    })
  },
  updated() { this.apply() },
  select() { return this.el.querySelector("select") },
  options() { return Array.from(this.select().options).filter(o => o.value !== "") },
  visible() { return this.options().filter(o => !o.hidden) },
  apply() {
    const select = this.select()
    const q = this.input.value.trim().toLowerCase()
    for (const o of this.options()) {
      const hide = q !== "" && !o.selected && !o.textContent.toLowerCase().includes(q)
      o.hidden = hide
      o.disabled = hide
    }
    for (const g of select.querySelectorAll("optgroup")) {
      g.hidden = Array.from(g.children).every(o => o.hidden)
    }
    // while searching: an open list (daisyUI's .select styles a closed one only)
    const prompt = select.querySelector('option[value=""]')
    if (prompt) prompt.hidden = q !== ""
    select.classList.toggle("select", q === "")
    select.classList.toggle("picker-list", q !== "")
    select.size = q === "" ? 0 : Math.max(2, Math.min(8, this.visible().length))
  },
  pick(option) {
    if (!option) return
    const select = this.select()
    select.value = option.value
    this.clear()
    select.dispatchEvent(new Event("change", {bubbles: true}))
    select.dispatchEvent(new Event("input", {bubbles: true}))
  },
  clear() {
    this.input.value = ""
    this.apply()
  },
}

// Combobox (<.input type="select" searchable>, one choice): a text field that
// filters a listbox of the select's options. Arrow keys move, Enter or a click
// picks, Escape closes, Tab leaves. The value stays in the native (visually
// hidden) <select>, so forms, phx-change and server-side options work as for
// any select. The list is built from the options on open, at most MAX rows.
const COMBOBOX_MAX = 100
const Combobox = {
  mounted() {
    this.select = this.el.querySelector("select")
    this.input = this.el.querySelector("[data-combobox-input]")
    this.list = this.el.querySelector("[data-combobox-list]")
    this.index = -1
    this.typed = false
    this.sync()
    this.input.addEventListener("focus", () => { this.input.select(); this.typed = false; this.open() })
    this.input.addEventListener("click", () => { if (this.list.classList.contains("hidden")) this.open() })
    this.input.addEventListener("input", e => { e.stopPropagation(); this.typed = true; this.open() })
    this.input.addEventListener("change", e => e.stopPropagation())
    this.input.addEventListener("keydown", e => this.key(e))
    this.input.addEventListener("blur", () => { this.close(); this.sync() })
    // mousedown, not click: the input's blur would close the list first
    this.list.addEventListener("mousedown", e => {
      const row = e.target.closest("[data-value]")
      if (row) { e.preventDefault(); this.pick(row.dataset.value) }
    })
  },
  updated() { this.sync() },
  label() {
    const o = this.select.selectedOptions[0]
    return o && o.value !== "" ? o.textContent.trim() : ""
  },
  sync() {
    if (document.activeElement !== this.input) this.input.value = this.label()
  },
  rows() { return Array.from(this.list.querySelectorAll("[data-value]")) },
  open() {
    const q = this.typed ? this.input.value.trim().toLowerCase() : ""
    const matches = Array.from(this.select.options).filter(o =>
      o.value === "" ? q === "" : q === "" || o.textContent.toLowerCase().includes(q))
    this.list.replaceChildren(...matches.slice(0, COMBOBOX_MAX).map((o, i) => {
      const li = document.createElement("li")
      li.id = `${this.el.id}-opt-${i}`
      li.setAttribute("role", "option")
      li.dataset.value = o.value
      li.setAttribute("aria-selected", String(o.selected && o.value !== ""))
      const a = document.createElement("a")
      a.textContent = o.value === "" ? (this.input.placeholder || "None") : o.textContent.trim()
      if (o.value === "") a.className = "opacity-60"
      li.append(a)
      return li
    }))
    if (matches.length > COMBOBOX_MAX) {
      const more = document.createElement("li")
      more.className = "px-3 py-1 text-xs opacity-60"
      more.textContent = `${matches.length - COMBOBOX_MAX} more: keep typing to narrow down`
      this.list.append(more)
    }
    if (matches.length === 0) {
      const none = document.createElement("li")
      none.className = "px-3 py-1 text-xs opacity-60"
      none.textContent = "No match"
      this.list.append(none)
    }
    this.list.classList.remove("hidden")
    this.input.setAttribute("aria-expanded", "true")
    const rows = this.rows()
    this.setActive(this.typed ? 0 : Math.max(0, rows.findIndex(r => r.getAttribute("aria-selected") === "true")))
  },
  close() {
    this.list.classList.add("hidden")
    this.input.setAttribute("aria-expanded", "false")
    this.input.removeAttribute("aria-activedescendant")
    this.index = -1
  },
  setActive(i) {
    const rows = this.rows()
    if (rows.length === 0) return
    this.index = (i + rows.length) % rows.length
    rows.forEach((r, n) => r.firstChild.classList.toggle("menu-active", n === this.index))
    this.input.setAttribute("aria-activedescendant", rows[this.index].id)
    rows[this.index].scrollIntoView({block: "nearest"})
  },
  key(e) {
    const closed = this.list.classList.contains("hidden")
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (closed) this.open()
      else this.setActive(this.index + (e.key === "ArrowDown" ? 1 : -1))
    } else if (e.key === "Enter" && !closed) {
      e.preventDefault()
      const row = this.rows()[this.index]
      if (row) this.pick(row.dataset.value)
    } else if (e.key === "Escape" && !closed) {
      e.preventDefault()
      this.close()
      this.typed = false
      this.input.value = this.label()
    }
  },
  pick(value) {
    this.select.value = value
    this.typed = false
    this.close()
    this.input.value = this.label()
    this.select.dispatchEvent(new Event("input", {bubbles: true}))
    this.select.dispatchEvent(new Event("change", {bubbles: true}))
  },
}

// Row menus (<details data-menu>): the list is placed with position: fixed next
// to its button, so a table's scroll container cannot clip it; it flips upward
// near the bottom edge and closes on scroll or resize.
document.addEventListener("toggle", e => {
  const details = e.target
  if (!(details instanceof HTMLDetailsElement) || !details.matches("[data-menu]")) return
  const list = details.querySelector("ul")
  if (!details.open) { list.removeAttribute("style"); return }
  const r = details.querySelector("summary").getBoundingClientRect()
  list.style.position = "fixed"
  list.style.left = "auto"
  list.style.right = `${window.innerWidth - r.right}px`
  const h = list.offsetHeight
  const below = r.bottom + 4
  const flip = below + h > window.innerHeight && r.top - h - 4 > 0
  list.style.top = `${flip ? r.top - h - 4 : below}px`
}, true)
const closeMenus = () =>
  document.querySelectorAll("details[data-menu][open]").forEach(d => d.removeAttribute("open"))
window.addEventListener("scroll", closeMenus, true)
window.addEventListener("resize", closeMenus)

// data-confirm through the styled <dialog id="confirm-dialog"> (root layout)
// instead of window.confirm. A capture listener on window runs before
// phoenix_html and LiveView; on "ok" the attribute is lifted for one
// re-dispatched click. Optional: data-confirm-type="<text>" (the user must
// type it, for fleet-wide writes), data-confirm-label="<button text>".
// Danger tone for elements styled text-error/btn-error.
const openConfirm = (dialog, el) => {
  const $ = id => document.getElementById(id)
  const message = el.getAttribute("data-confirm")
  const expected = el.dataset.confirmType || ""
  const ok = $("confirm-dialog-ok")
  const input = $("confirm-dialog-input")
  const danger = el.classList.contains("text-error") || el.classList.contains("btn-error")

  $("confirm-dialog-message").textContent = message
  $("confirm-dialog-typed").classList.toggle("hidden", expected === "")
  $("confirm-dialog-typed").classList.toggle("flex", expected !== "")
  $("confirm-dialog-expected").textContent = expected
  input.value = ""
  ok.textContent = el.dataset.confirmLabel || "Confirm"
  ok.classList.toggle("btn-error", danger)
  ok.classList.toggle("btn-primary", !danger)
  ok.disabled = expected !== ""
  input.oninput = () => { ok.disabled = input.value.trim() !== expected }

  dialog.returnValue = ""
  dialog.addEventListener("close", () => {
    if (dialog.returnValue !== "ok") return
    el.removeAttribute("data-confirm")
    try { el.click() } finally { el.setAttribute("data-confirm", message) }
  }, {once: true})
  dialog.showModal()
  ;(expected === "" ? $("confirm-dialog-cancel") : input).focus()
}

window.addEventListener("click", e => {
  const el = e.target.closest?.("[data-confirm]")
  const dialog = document.getElementById("confirm-dialog")
  if (!el || !dialog?.showModal || el.disabled) return
  e.preventDefault()
  e.stopImmediatePropagation()
  openConfirm(dialog, el)
}, true)

// phoenix.js memorizes a long-poll fallback per tab in sessionStorage; after
// a proxy hiccup that would leave the tab degraded forever. Full page load =
// fresh chance for the WebSocket. (Lesson from ../dashboard 4.2.13.)
sessionStorage.removeItem("phx:fallback:LongPoll")

// Local-time rendering: the server emits <time datetime="<UTC ISO>"
// data-localtime data-fmt="…">UTC text</time>; we rewrite textContent only,
// never the datetime attribute (canonical value LiveView patches re-read).
// Locale sv-SE yields ISO-ish output; timeZoneName appends CEST/CET etc.
const TIME_FMT = {
  "datetime": {year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", timeZoneName: "short"},
  "datetime-sec": {year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", timeZoneName: "short"},
  "time-sec": {hour: "2-digit", minute: "2-digit", second: "2-digit"},
  "date": {year: "numeric", month: "2-digit", day: "2-digit"},
}
const localizeTime = el => {
  const d = new Date(el.getAttribute("datetime"))
  if (isNaN(d)) return
  el.textContent = d.toLocaleString("sv-SE", TIME_FMT[el.dataset.fmt] || TIME_FMT["datetime"])
}
const localizeTimes = (root = document) =>
  root.querySelectorAll("time[data-localtime]").forEach(localizeTime)

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // 30s default is exactly the idle timeout many proxies ship with — every
  // heartbeat would race the proxy's timer (../dashboard 4.0.8).
  heartbeatIntervalMs: 20000,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CopyToClipboard, SelectSearch, Combobox},
  // Localize timestamps in LiveView-patched DOM without flashing UTC.
  dom: {
    onNodeAdded(node) {
      if (node.nodeType === 1) {
        if (node.matches?.("time[data-localtime]")) localizeTime(node)
        localizeTimes(node)
      }
      return node
    },
    onBeforeElUpdated(_from, to) {
      if (to.matches?.("time[data-localtime]")) localizeTime(to)
      return true
    },
  },
})

localizeTimes()
window.addEventListener("phx:page-loading-stop", () => localizeTimes())

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Mark the active theme buttons from the html element's data-theme — the
// DOM attribute is the single truth (LiveViews don't carry design assigns).
const markThemeChoices = () => {
  const theme = document.documentElement.getAttribute("data-theme") || ""
  const sep = theme.lastIndexOf("-")
  const design = theme.slice(0, sep)
  const hasModeCookie = document.cookie.split("; ").some(c => c.startsWith("ssm_mode="))
  const mode = hasModeCookie ? theme.slice(sep + 1) : ""
  document.querySelectorAll("[data-theme-design]").forEach(el =>
    el.classList.toggle("btn-active", el.dataset.themeDesign === design))
  document.querySelectorAll("[data-theme-mode]").forEach(el =>
    el.classList.toggle("btn-active", el.dataset.themeMode === mode))
}
markThemeChoices()
window.addEventListener("phx:page-loading-stop", markThemeChoices)

// Native <details data-popover> stays open until its summary is re-clicked;
// close any open popover on outside click.
document.addEventListener("click", e => {
  document.querySelectorAll("details[data-popover][open]").forEach(details => {
    if (!details.contains(e.target)) details.removeAttribute("open")
  })
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// List filters live in the URL (?q=, ?type=, …). Remember them per page for
// this tab and bring them back when the page is opened again without any
// (sidebar, links): navigating away and back keeps the search. Clearing the
// filters patches to an empty query, which is remembered too.
const QUERY_KEY = path => `ssm:query:${path}`
window.addEventListener("phx:page-loading-stop", ({detail}) => {
  const key = QUERY_KEY(location.pathname)
  let saved = null
  try { saved = sessionStorage.getItem(key) } catch (_e) { return }
  if (detail.kind !== "patch" && location.search === "" && saved) {
    liveSocket.js().patch(location.pathname + saved, {replace: true})
    return
  }
  try { sessionStorage.setItem(key, location.search) } catch (_e) { /* private mode */ }
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

