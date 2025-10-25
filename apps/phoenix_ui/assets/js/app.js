import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

import TopologyHook from "./hooks/topology";
import LogsHook from "./hooks/logs_hook";
import ClipboardHook from "./hooks/clipboard_hook";
import MetricsChartHook from "./hooks/metrics_chart_hook";

console.groupCollapsed("[AeroPhoenix] UI Runtime Initialization");
console.info("Initializing Phoenix LiveView runtime...");

const Hooks = {
  TopologyHook,
  LogsHook,
  ClipboardHook,
  MetricsChartHook,
};

Hooks.CopyCli = {
  mounted() {
    console.log("[CopyCli] Hook mounted.");

    this.handleEvent("copy-cli", (payload) => {
      const cmd = payload?.cmd;
      if (!cmd) {
        console.warn("[CopyCli] Missing or invalid payload:", payload);
        return;
      }

      console.log(`[CopyCli] Copying CLI command: ${cmd}`);
      if (navigator?.clipboard?.writeText) {
        navigator.clipboard
          .writeText(cmd)
          .then(() => {
            console.info("[CopyCli] Command copied successfully.");
            alert("CLI command copied to clipboard!");
          })
          .catch((err) => {
            console.error("[CopyCli] Clipboard write failed:", err);
            alert("Failed to copy command. See console for details.");
          });
      } else {
        console.warn("[CopyCli] Clipboard API not available.");
        alert("Clipboard API not supported in this browser.");
      }
    });
  },
  destroyed() {
    console.log("[CopyCli] Hook destroyed.");
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

if (!csrfToken) {
  console.warn(
    "[AeroPhoenix] Warning: CSRF token not found. LiveView may not function correctly."
  );
}

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
});

topbar.config({
  barColors: { 0: "#29d" },
  shadowColor: "rgba(0, 0, 0, 0.3)",
});

let topBarTimer = undefined;

window.addEventListener("phx:page-loading-start", () => {
  clearTimeout(topBarTimer);
  topBarTimer = setTimeout(() => topbar.show(300), 150);
});

window.addEventListener("phx:page-loading-stop", () => {
  clearTimeout(topBarTimer);
  topbar.hide();
});

liveSocket.connect();
window.liveSocket = liveSocket;

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs();

    let activeKey = null;
    window.addEventListener("keydown", (e) => (activeKey = e.key));
    window.addEventListener("keyup", () => (activeKey = null));

    window.addEventListener(
      "click",
      (e) => {
        if (activeKey === "c") {
          e.preventDefault();
          reloader.openEditorAtCaller(e.target);
        } else if (activeKey === "d") {
          e.preventDefault();
          reloader.openEditorAtDef(e.target);
        }
      },
      true
    );

    console.log("[AeroPhoenix] Developer live reloader attached.");
    window.liveReloader = reloader;
  });
}

console.info("[AeroPhoenix] LiveSocket connected successfully.");
console.groupEnd();