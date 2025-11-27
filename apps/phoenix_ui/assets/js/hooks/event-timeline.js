export const EventTimeline = {
  mounted() {
    this.initializeTimeline();
    this.setupEventListeners();
    this.handleEvent("timeline:new_event", (payload) => {
      this.addEvent(payload.event);
    });

    this.handleEvent("timeline:jump", (payload) => {
      this.updatePosition(payload.position);
    });
  },

  initializeTimeline() {
    const container = this.el;
    const width = container.clientWidth;
    const height = container.clientHeight;
    this.svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    this.svg.setAttribute("width", "100%");
    this.svg.setAttribute("height", "100%");
    this.svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    this.svg.classList.add("event-timeline-svg");
    container.innerHTML = "";
    container.appendChild(this.svg);
    this.timelineGroup = this.createGroup("timeline-group");
    this.eventsGroup = this.createGroup("events-group");
    this.positionIndicator = this.createGroup("position-indicator");

    this.svg.appendChild(this.timelineGroup);
    this.svg.appendChild(this.eventsGroup);
    this.svg.appendChild(this.positionIndicator);
    this.drawTimelineAxis();
    this.renderEvents();
  },

  createGroup(className) {
    const g = document.createElementNS("http://www.w3.org/2000/svg", "g");
    g.classList.add(className);
    return g;
  },

  drawTimelineAxis() {
    const width = this.svg.clientWidth || this.svg.parentElement.clientWidth;
    const height = this.svg.clientHeight || this.svg.parentElement.clientHeight;
    const centerY = height / 2;
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    line.setAttribute("x1", 50);
    line.setAttribute("y1", centerY);
    line.setAttribute("x2", width - 50);
    line.setAttribute("y2", centerY);
    line.setAttribute("stroke", "currentColor");
    line.setAttribute("stroke-width", "3");
    line.setAttribute("opacity", "0.3");
    line.classList.add("timeline-axis");

    this.timelineGroup.appendChild(line);
    const startCircle = this.createCircle(50, centerY, 8, "#6366f1");
    this.timelineGroup.appendChild(startCircle);
    const endCircle = this.createCircle(width - 50, centerY, 8, "#8b5cf6");
    this.timelineGroup.appendChild(endCircle);
  },

  renderEvents() {
    const eventsData = this.getEventsData();
    
    if (!eventsData || eventsData.length === 0) {
      this.renderEmptyState();
      return;
    }

    const width = this.svg.clientWidth || this.svg.parentElement.clientWidth;
    const height = this.svg.clientHeight || this.svg.parentElement.clientHeight;
    const centerY = height / 2;
    const padding = 50;
    const timelineWidth = width - (padding * 2);

    eventsData.forEach((event, index) => {
      const x = padding + (index / Math.max(1, eventsData.length - 1)) * timelineWidth;
      const y = centerY + (index % 2 === 0 ? -40 : 40);
      const eventGroup = this.createEventNode(event, x, y, index);
      this.eventsGroup.appendChild(eventGroup);
      const connector = this.createLine(x, y + (index % 2 === 0 ? 20 : -20), x, centerY, "#e5e7eb");
      connector.setAttribute("stroke-dasharray", "2,2");
      this.eventsGroup.insertBefore(connector, eventGroup);
    });
  },

  createEventNode(event, x, y, index) {
    const group = this.createGroup("event-node");
    group.setAttribute("data-event-index", index);
    group.setAttribute("transform", `translate(${x}, ${y})`);
    group.style.cursor = "pointer";
    const color = this.getEventTypeColor(event.type || event.event_type);
    const circle = this.createCircle(0, 0, 16, color);
    circle.classList.add("event-circle");
    if (index === this.getCurrentPosition()) {
      circle.classList.add("animate-pulse");
    }

    group.appendChild(circle);
    const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
    text.setAttribute("x", 0);
    text.setAttribute("y", 5);
    text.setAttribute("text-anchor", "middle");
    text.setAttribute("fill", "white");
    text.setAttribute("font-size", "12");
    text.setAttribute("font-weight", "bold");
    text.textContent = index + 1;

    group.appendChild(text);
    group.addEventListener("mouseenter", () => {
      this.showTooltip(event, x, y);
      circle.setAttribute("r", 20);
    });

    group.addEventListener("mouseleave", () => {
      this.hideTooltip();
      circle.setAttribute("r", 16);
    });

    group.addEventListener("click", () => {
      this.pushEvent("select_event", { index: index.toString() });
    });

    return group;
  },

  createCircle(cx, cy, r, fill) {
    const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    circle.setAttribute("cx", cx);
    circle.setAttribute("cy", cy);
    circle.setAttribute("r", r);
    circle.setAttribute("fill", fill);
    circle.style.transition = "all 0.3s ease";
    return circle;
  },

  createLine(x1, y1, x2, y2, stroke) {
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    line.setAttribute("x1", x1);
    line.setAttribute("y1", y1);
    line.setAttribute("x2", x2);
    line.setAttribute("y2", y2);
    line.setAttribute("stroke", stroke);
    line.setAttribute("stroke-width", "1");
    line.setAttribute("opacity", "0.5");
    return line;
  },

  getEventTypeColor(eventType) {
    const colorMap = {
      machine_created: "#10b981",
      machine_started: "#059669",
      machine_stopped: "#ef4444",
      machine_destroyed: "#dc2626",
      migration_initiated: "#3b82f6",
      migration_completed: "#2563eb",
      state_transition_started: "#8b5cf6",
      state_transition_completed: "#7c3aed",
      health_check_failed: "#f59e0b",
      system_error: "#f97316",
      default: "#6b7280"
    };

    return colorMap[eventType] || colorMap.default;
  },

  showTooltip(event, x, y) {
    this.hideTooltip();
    const tooltip = document.createElement("div");
    tooltip.className = "event-tooltip absolute bg-white dark:bg-gray-800 rounded-lg shadow-xl p-4 border border-gray-200 dark:border-gray-700 z-50 pointer-events-none";
    tooltip.style.left = `${x + 20}px`;
    tooltip.style.top = `${y - 50}px`;
    tooltip.style.maxWidth = "300px";
    tooltip.style.animation = "fadeIn 0.2s ease";

    tooltip.innerHTML = `
      <div class="text-sm">
        <p class="font-semibold text-gray-900 dark:text-white mb-2">${event.type || event.event_type}</p>
        <p class="text-xs text-gray-500 dark:text-gray-400">Version ${event.version || event.aggregate_version}</p>
        <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">${this.formatTimestamp(event.timestamp || event.occurred_at)}</p>
      </div>
    `;

    this.el.parentElement.appendChild(tooltip);
    this.currentTooltip = tooltip;
  },

  hideTooltip() {
    if (this.currentTooltip) {
      this.currentTooltip.remove();
      this.currentTooltip = null;
    }
  },

  updatePosition(position) {
    const width = this.svg.clientWidth || this.svg.parentElement.clientWidth;
    const height = this.svg.clientHeight || this.svg.parentElement.clientHeight;
    const centerY = height / 2;
    const padding = 50;
    const timelineWidth = width - (padding * 2);
    const eventsData = this.getEventsData();

    if (eventsData && eventsData.length > 0) {
      const x = padding + (position / eventsData.length) * timelineWidth;
      this.positionIndicator.innerHTML = "";
      const line = this.createLine(x, 0, x, height, "#6366f1");
      line.setAttribute("stroke-width", "2");
      line.setAttribute("opacity", "0.7");
      line.setAttribute("stroke-dasharray", "5,5");
      line.style.animation = "fadeIn 0.3s ease";

      this.positionIndicator.appendChild(line);
      const circle = this.createCircle(x, centerY, 12, "#6366f1");
      circle.setAttribute("opacity", "0.8");
      this.positionIndicator.appendChild(circle);
    }
  },

  addEvent(event) {
    this.renderEvents();
  },

  setupEventListeners() {
    window.addEventListener("resize", () => {
      this.initializeTimeline();
    });
  },

  getEventsData() {
    try {
      const dataAttr = this.el.getAttribute("data-events");
      if (dataAttr) {
        return JSON.parse(dataAttr);
      }
    } catch (e) {
      console.warn("Failed to parse events data:", e);
    }
    
    return [];
  },

  getCurrentPosition() {
    try {
      const position = this.el.getAttribute("data-position");
      return position ? parseInt(position, 10) : 0;
    } catch (e) {
      return 0;
    }
  },

  renderEmptyState() {
    const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
    const width = this.svg.clientWidth || this.svg.parentElement.clientWidth;
    const height = this.svg.clientHeight || this.svg.parentElement.clientHeight;

    text.setAttribute("x", width / 2);
    text.setAttribute("y", height / 2);
    text.setAttribute("text-anchor", "middle");
    text.setAttribute("fill", "currentColor");
    text.setAttribute("opacity", "0.5");
    text.setAttribute("font-size", "14");
    text.textContent = "No events to display";

    this.eventsGroup.appendChild(text);
  },

  formatTimestamp(timestamp) {
    if (!timestamp) return "N/A";

    try {
      const date = new Date(timestamp);
      return date.toLocaleString();
    } catch (e) {
      return timestamp;
    }
  },

  destroyed() {
    if (this.currentTooltip) {
      this.currentTooltip.remove();
    }
  }
};

export default EventTimeline;
