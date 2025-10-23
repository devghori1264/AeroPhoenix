import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import TopologyHook from "./topology";

let Hooks = {};

Hooks.TopologyHook = TopologyHook;

Hooks.CopyCli = {
  mounted() {
    console.log("[AeroPhoenix] CopyCli hook mounted.");
    this.handleEvent("copy-cli", (payload) => {
      if (payload && payload.cmd) {
        console.log("Received copy-cli event:", payload.cmd);
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(payload.cmd)
            .then(() => {
              alert("CLI command copied to clipboard!");
              console.info("CLI command copied successfully.");
            })
            .catch((err) => {
              console.error("Failed to copy CLI command:", err);
              alert("Failed to copy command. See console for details.");
            });
        } else {
          console.warn("Clipboard API not available. Cannot copy command.");
          alert("Clipboard API not available in this browser.");
        }
      } else {
        console.warn("Received copy-cli event with invalid payload:", payload);
      }
    });
  },
  destroyed() {
    console.log("[AeroPhoenix] CopyCli hook destroyed.");
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
if (!csrfToken) {
  console.warn("CSRF token meta tag not found. LiveView sessions may fail.");
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
let topBarScheduled = undefined;

window.addEventListener("phx:page-loading-start", (_info) => {
  clearTimeout(topBarScheduled);
  topBarScheduled = setTimeout(() => topbar.show(300), 120);
});
window.addEventListener("phx:page-loading-stop", (_info) => {
  clearTimeout(topBarScheduled);
  topbar.hide();
});

liveSocket.connect();

window.liveSocket = liveSocket;

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs();

    let keyDown = null;
    window.addEventListener("keydown", (e) => (keyDown = e.key));
    window.addEventListener("keyup", () => (keyDown = null));
    window.addEventListener(
      "click",
      (e) => {
        if (keyDown === "c") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtCaller(e.target);
        }
        else if (keyDown === "d") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtDef(e.target);
        }
      },
      true
    );

    window.liveReloader = reloader;
  });
}

console.log("[AeroPhoenix] UI initialized successfully.");