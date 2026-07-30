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
  hooks: {...colocatedHooks, CopyToClipboard},
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

