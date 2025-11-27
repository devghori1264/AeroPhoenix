import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { initTheme } from "./theme";

import TopologyHook from "./hooks/topology";
import LogsHook from "./hooks/logs_hook";
import ClipboardHook from "./hooks/clipboard_hook";
import MetricsChartHook from "./hooks/metrics_chart_hook";
import ChaosOverlayHook from "./hooks/chaos_overlay_hook";
import ToastHook from "./hooks/toast_hook";
import MigrationStudioHook from "./hooks/migration-studio";
import FsmVisualizerHook from "./hooks/fsm-visualizer";
import DebuggerEnhancementsHook from "./hooks/debugger-enhancements";
import MetricsDashboardHook from "./hooks/metrics-dashboard";
import LogStreamHook from "./hooks/log-stream";
import OptimizerDashboardHook from "./hooks/optimizer-dashboard";
import ScalingVisualizerHook from "./hooks/scaling-visualizer";
import FeatureFlagsHook from "./hooks/feature-flags";
import MicroInteractionsHook from "./hooks/micro-interactions";
import ThemeSystemHook from "./hooks/theme-system";
import EventTimelineHook from "./hooks/event-timeline";

initTheme();

console.groupCollapsed("[AeroPhoenix] UI Runtime Initialization");
console.info("Initializing Phoenix LiveView runtime...");

const Hooks = {
  TopologyHook,
  LogsHook,
  ClipboardHook,
  MetricsChartHook,
  ChaosOverlayHook,
  ToastHook,
  MigrationStudio: MigrationStudioHook,
  FsmGraphHook: FsmVisualizerHook,
  DebuggerEnhancements: DebuggerEnhancementsHook,
  MetricsDashboard: MetricsDashboardHook,
  LogStream: LogStreamHook,
  OptimizerDashboard: OptimizerDashboardHook,
  ScalingVisualizer: ScalingVisualizerHook,
  FeatureFlags: FeatureFlagsHook,
  MicroInteractions: MicroInteractionsHook,
  ThemeSystem: ThemeSystemHook,
  EventTimeline: EventTimelineHook,
};

Hooks.ChaosPulse = {
  mounted() {
    console.log("[ChaosPulse] Hook mounted");
    this.updatePulse();
  },
  updated() {
    this.updatePulse();
  },
  updatePulse() {
    const activeChaos = parseInt(this.el.dataset.activeChaos || "0");
    if (activeChaos > 0) {
      this.el.classList.add("chaos-pulse-active");

      if (!this.el.querySelector('.chaos-ripple')) {
        const ripple = document.createElement('div');
        ripple.className = 'chaos-ripple';
        this.el.appendChild(ripple);
      }
    } else {
      this.el.classList.remove("chaos-pulse-active");
      const ripple = this.el.querySelector('.chaos-ripple');
      if (ripple) ripple.remove();
    }
  }
};

Hooks.AnimatedCounter = {
  mounted() {
    console.log("[AnimatedCounter] Hook mounted");
    this.currentValue = parseFloat(this.el.textContent) || 0;
  },
  updated() {
    const newValue = parseFloat(this.el.dataset.value || this.el.textContent) || 0;

    if (newValue !== this.currentValue) {
      this.animateValue(this.currentValue, newValue, 800);
      this.currentValue = newValue;
    }
  },
  animateValue(start, end, duration) {
    const range = end - start;
    const increment = range / (duration / 16);
    let current = start;
    const timer = setInterval(() => {
      current += increment;
      if ((increment > 0 && current >= end) || (increment < 0 && current <= end)) {
        current = end;
        clearInterval(timer);
      }

      const suffix = this.el.dataset.suffix || "";
      const decimals = parseInt(this.el.dataset.decimals || "0");
      this.el.textContent = current.toFixed(decimals) + suffix;
    }, 16);
  }
};

Hooks.MachineFormCost = {
  mounted() {
    console.log("[MachineFormCost] Hook mounted.");

    const calculateCost = () => {
      const cpuSelect = document.getElementById('cpu-select');
      const memorySelect = document.getElementById('memory-select');

      if (!cpuSelect || !memorySelect) return;

      const cpu = cpuSelect.value;
      const memory = parseInt(memorySelect.value);

      let cpuCost = 0;
      switch(cpu) {
        case 'shared-cpu-1x': cpuCost = 0.0025; break;
        case 'shared-cpu-2x': cpuCost = 0.0045; break;
        case 'dedicated-cpu-1x': cpuCost = 0.006; break;
        case 'dedicated-cpu-2x': cpuCost = 0.012; break;
        case 'dedicated-cpu-4x': cpuCost = 0.024; break;
        case 'dedicated-cpu-8x': cpuCost = 0.048; break;
      }

      const memoryCost = (memory / 1024) * 0.002;

      const hourly = cpuCost + memoryCost;
      const monthly = hourly * 730;

      const hourlyEl = document.getElementById('cost-hourly');
      const monthlyEl = document.getElementById('cost-monthly');
      if (hourlyEl) hourlyEl.textContent = '$' + hourly.toFixed(4);
      if (monthlyEl) monthlyEl.textContent = '~$' + monthly.toFixed(2);
    };

    const cpuSelect = document.getElementById('cpu-select');
    const memorySelect = document.getElementById('memory-select');
    if (cpuSelect) cpuSelect.addEventListener('change', calculateCost);
    if (memorySelect) memorySelect.addEventListener('change', calculateCost);

    setTimeout(calculateCost, 100);
  },
  destroyed() {
    console.log("[MachineFormCost] Hook destroyed.");
  },
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

Hooks.EventReplayDownload = {
  mounted() {
    console.log("[EventReplayDownload] Hook mounted");
    
    this.handleEvent("download-events", ({ events, format, filename }) => {
      console.log(`[EventReplayDownload] Downloading ${events.length} events as ${format}`);
      
      try {
        let content, mimeType;
        
        if (format === "json") {
          content = JSON.stringify(events, null, 2);
          mimeType = "application/json";
        } else if (format === "csv") {
          const headers = ["ID", "Type", "Aggregate ID", "Version", "Timestamp", "Correlation ID", "User ID"];
          const rows = events.map(event => [
            event.id || "",
            event.event_type || "",
            event.aggregate_id || "",
            event.aggregate_version || "",
            event.timestamp || "",
            event.correlation_id || "",
            event.metadata?.user_id || ""
          ]);
          
          const csvContent = [
            headers.join(","),
            ...rows.map(row => row.map(cell => `"${cell}"`).join(","))
          ].join("\n");
          
          content = csvContent;
          mimeType = "text/csv";
        } else {
          console.error("[EventReplayDownload] Unknown format:", format);
          return;
        }
        const blob = new Blob([content], { type: mimeType });
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = filename;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
        
        console.info("[EventReplayDownload] Download initiated successfully");
      } catch (error) {
        console.error("[EventReplayDownload] Download failed:", error);
        alert("Failed to download events. See console for details.");
      }
    });
  },
  destroyed() {
    console.log("[EventReplayDownload] Hook destroyed");
  }
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
  onError: (error) => {
    console.error("[AeroPhoenix] LiveSocket error:", error);
  },
  onReconnect: () => {
    console.info("[AeroPhoenix] LiveSocket reconnected");
  }
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

window.addEventListener("phx:confirm-delete", (e) => {
  const { id } = e.detail;
  const btn = document.getElementById(`delete-btn-${id}`);
  const textSpan = document.getElementById(`delete-text-${id}`);
  if (btn && textSpan) {
    textSpan.textContent = "Are you sure?";
    btn.classList.remove("hover:bg-red-500/10");
    btn.classList.add("bg-red-500/20", "border-red-500", "text-red-600");

    btn.setAttribute("phx-click", "delete-machine");

    setTimeout(() => {
      if (textSpan.textContent === "Are you sure?") {
        textSpan.textContent = "Delete Machine";
        btn.classList.remove("bg-red-500/20", "border-red-500", "text-red-600");
        btn.classList.add("hover:bg-red-500/10");
        btn.setAttribute("phx-click", "delete-machine-confirm");
      }
    }, 3000);
  }
});

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
window.addEventListener('error', (event) => {
  console.error('[AeroPhoenix] Global error caught:', event.error);
});

window.addEventListener('unhandledrejection', (event) => {
  console.error('[AeroPhoenix] Unhandled promise rejection:', event.reason);
});