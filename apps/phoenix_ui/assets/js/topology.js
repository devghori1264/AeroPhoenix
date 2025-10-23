import * as d3 from "d3";

const TopologyHook = {
  mounted() {
    console.log("[AeroPhoenix] TopologyHook mounted (D3 version)");
    this.el = this.el;
    const svg = d3.select(this.el).select("#topology-svg");

    if (svg.empty()) {
      console.error("TopologyHook: Could not find target SVG element #topology-svg");
      return;
    }

    const rawData = this.el.dataset.topology;
    if (!rawData) {
      console.error("TopologyHook: data-topology attribute not found on element:", this.el);
      this.renderError(svg, "Missing topology data.");
      return;
    }

    try {
      const initialData = JSON.parse(rawData);
      this.render(initialData, svg);
    } catch (e) {
      console.error("TopologyHook: Failed to parse initial topology data:", e, rawData);
      this.renderError(svg, "Invalid topology data format.");
    }

    this.handleEvent("topology:update", (payload) => {
      console.log("[TopologyHook] Received topology:update", payload);
      this.render(payload, svg);
    });
  },

  /**
   * Renders the topology graph (regions and machines) within the provided SVG element.
   * @param {object} data - The topology data ({ regions: [], machines: [] }).
   * @param {d3.Selection} svg - The D3 selection of the SVG element.
   */
  render(data, svg) {
    svg.selectAll("*").remove();

    const width = svg.node()?.clientWidth || 600;
    const height = svg.node()?.clientHeight || 500;
    const margin = { top: 20, right: 20, bottom: 80, left: 20 };

    const regions = data.regions || [];
    const machines = data.machines || [];

    console.log(`[TopologyHook] Rendering topology with ${regions.length} regions and ${machines.length} machines.`);

    const numRegions = Math.max(1, regions.length);
    const regionSpacing = (width - margin.left - margin.right) / numRegions;
    const regionX = (i) => margin.left + (regionSpacing / 2) + (i * regionSpacing);
    const regionY = height / 3;

    regions.forEach((r, i) => {
      r._x = regionX(i);
      r._y = regionY;
      r.count = machines.filter(m => m.region === r.name).length;
    });

    const regionGroup = svg.append("g").attr("class", "regions");
    const regionNodes = regionGroup.selectAll("g.region")
      .data(regions, d => d.name)
      .enter()
      .append("g")
      .attr("class", "region")
      .attr("transform", (d) => `translate(${d._x}, ${d._y})`);

    regionNodes.append("circle")
      .attr("r", 45)
      .attr("fill", "#e5e7eb")
      .attr("stroke", "#9ca3af")
      .attr("stroke-width", 1.5);

    regionNodes.append("text")
      .attr("y", 0)
      .attr("text-anchor", "middle")
      .attr("dominant-baseline", "middle")
      .attr("font-size", 13)
      .attr("font-weight", 500)
      .attr("fill", "#1f2937")
      .text(d => d.name);

    regionNodes.append("text")
      .attr("y", 20)
      .attr("text-anchor", "middle")
      .attr("dominant-baseline", "middle")
      .attr("font-size", 10)
      .attr("fill", "#6b7280")
      .text(d => `${d.count || 0} machines`);

    const regionMap = {};
    regions.forEach(r => regionMap[r.name] = r);
    const machinesPlacedInRegion = {};

    machines.forEach((m) => {
      const regionData = regionMap[m.region];
      const regionBaseX = regionData?._x || width / 2;
      const regionBaseY = regionData?._y || height / 2 + 50;
      const regionNameKey = m.region || "_orphan_";

      const indexInRegion = machinesPlacedInRegion[regionNameKey] || 0;
      machinesPlacedInRegion[regionNameKey] = indexInRegion + 1;

      const machinesPerRow = 6;
      const xOffset = ((indexInRegion % machinesPerRow) - Math.floor(machinesPerRow / 2) + 0.5) * 25;
      const yOffset = 70 + Math.floor(indexInRegion / machinesPerRow) * 25;

      m._x = regionBaseX + xOffset;
      m._y = regionBaseY + yOffset;
    });

    const machineGroup = svg.append("g").attr("class", "machines");
    const machineNodes = machineGroup.selectAll("g.machine")
      .data(machines, d => d.id)
      .enter()
      .append("g")
      .attr("class", "machine")
      .attr("transform", d => `translate(${d._x || 0}, ${d._y || 0})`)
      .style("cursor", "pointer")
      .on("click", (event, d) => {
        const machineId = d.id;
        console.log("[TopologyHook] Machine clicked:", machineId);
        this.pushEvent("select-machine", { id: machineId });
      });

    machineNodes.append("rect")
      .attr("width", 18)
      .attr("height", 18)
      .attr("x", -9)
      .attr("y", -9)
      .attr("rx", 3)
      .attr("fill", d => {
        switch (d.status) {
          case 'running': return '#10b981';
          case 'stopped': return '#ef4444';
          case 'pending':
          case 'migrating': return '#f59e0b';
          default: return '#6b7280';
        }
      })
      .attr("stroke", "#4b5563")
      .attr("stroke-width", 1);

    machineNodes.append("text")
      .attr("x", 14)
      .attr("y", 0)
      .attr("dominant-baseline", "middle")
      .text(d => d.name)
      .attr("font-size", 9)
      .attr("fill", "#374151");
  },

  /**
   * Renders an error message centered in the SVG.
   * @param {d3.Selection} svg - The D3 selection of the SVG element.
   * @param {string} message - The error message to display.
   */
  renderError(svg, message) {
    svg.selectAll("*").remove();
    const width = svg.node()?.clientWidth || 600;
    const height = svg.node()?.clientHeight || 500;

    svg.append("text")
      .attr("x", width / 2)
      .attr("y", height / 2)
      .attr("text-anchor", "middle")
      .attr("dominant-baseline", "middle")
      .attr("fill", "#ef4444")
      .attr("font-size", 14)
      .text(`Error: ${message}`);
  },

  destroyed() {
    console.log("[AeroPhoenix] TopologyHook destroyed");
  }
};

export default TopologyHook;