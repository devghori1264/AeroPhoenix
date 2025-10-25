import * as d3 from "d3";

const TopologyHook = {
  mounted() {
    this.svg = d3.select(this.el).select("svg");
    const raw = this.el.dataset.topology;
    try {
      this.data = JSON.parse(raw || "{}");
    } catch {
      this.data = { regions: [], machines: [], links: [] };
    }
    this.render(this.data);

    this.handleEvent("topology:update", ({ data }) => {
      this.data = data;
      this.render(this.data);
    });
  },

  render(data) {
    const svg = this.svg;
    svg.selectAll("*").remove();

    const width = svg.node().clientWidth || 800;
    const height = svg.node().clientHeight || 400;

    const regions = data.regions.map(r => ({
      id: r.name,
      type: "region",
      count: r.count || 0
    }));
    const machines = data.machines.map(m => ({
      id: m.id,
      type: "machine",
      name: m.name,
      region: m.region,
      status: m.status
    }));
    const nodes = [...regions, ...machines];

    const regionNodes = regions;
    const angleStep = (2 * Math.PI) / Math.max(1, regionNodes.length);
    regionNodes.forEach((r, i) => {
      r.x = width / 2 + Math.cos(i * angleStep) * Math.min(300, width / 3);
      r.y = height / 2 + Math.sin(i * angleStep) * Math.min(150, height / 3);
    });

    const grouped = d3.group(machines, d => d.region);
    grouped.forEach((ms, region) => {
      const base = regionNodes.find(r => r.id === region);
      if (!base) return;
      ms.forEach((m, idx) => {
        const angle = (idx % 8) * (Math.PI / 4);
        const radius = 45 + 12 * Math.floor(idx / 8);
        m.x = base.x + Math.cos(angle) * radius;
        m.y = base.y + Math.sin(angle) * radius;
      });
    });

    const regionG = svg.append("g")
      .selectAll("g")
      .data(regionNodes)
      .enter()
      .append("g")
      .attr("transform", d => `translate(${d.x},${d.y})`);

    regionG.append("circle")
      .attr("r", 28)
      .attr("fill", "#0f172a")
      .attr("stroke", "#334155")
      .attr("stroke-width", 1.2);

    regionG.append("text")
      .attr("y", 4)
      .attr("text-anchor", "middle")
      .attr("fill", "#e5e7eb")
      .attr("font-size", 12)
      .text(d => `${d.id} (${d.count})`);

    const mG = svg.append("g")
      .selectAll("g")
      .data(machines)
      .enter()
      .append("g")
      .attr("transform", d => `translate(${d.x},${d.y})`)
      .style("cursor", "pointer")
      .on("click", (_, d) => this.pushEvent("select_machine", { id: d.id }));

    mG.append("circle")
      .attr("r", 6)
      .attr("fill", d => (d.status === "running" ? "#10B981" : "#F97316"))
      .attr("stroke", "#fff")
      .attr("stroke-width", 0.8);

    mG.append("text")
      .attr("x", 10)
      .attr("y", 4)
      .attr("font-size", 10)
      .attr("fill", "#e5e7eb")
      .text(d => d.name);
  }
};

export default TopologyHook;