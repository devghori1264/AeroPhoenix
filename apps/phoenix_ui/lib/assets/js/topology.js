import * as d3 from "d3";

let TopologyHook = {
  mounted() {
    const el = this.el;
    const svg = d3.select("#topology-svg");
    const raw = el.dataset.topology;
    this.render(JSON.parse(raw), svg);

    this.handleEvent("topology:update", ({payload}) => {
      this.render(payload, svg);
    });
  },

  render(data, svg) {
    svg.selectAll("*").remove();
    const width = svg.node().clientWidth;
    const height = svg.node().clientHeight;

    const regions = data.regions || [];
    const machines = data.machines || [];

    const xScale = d3.scaleLinear().domain([0, Math.max(1, regions.length - 1)]).range([40, width - 40]);
    regions.forEach((r, i) => r._x = xScale(i), r._y = height / 2);

    const group = svg.append("g");
    group.selectAll("g.region")
      .data(regions)
      .enter()
      .append("g")
      .attr("class", "region")
      .attr("transform", (d) => `translate(${d._x}, ${d._y})`)
      .call((g) => {
        g.append("circle").attr("r", 40).attr("fill", "#f3f4f6");
        g.append("text").attr("y", 6).attr("text-anchor", "middle").attr("font-size", 12).text(d => d.name);
        g.append("text").attr("y", 22).attr("text-anchor", "middle").attr("font-size", 10).attr("fill", "#6b7280").text(d => `${d.count || 0} machines`);
      });

    const regionMap = {};
    regions.forEach((r)=> regionMap[r.name] = r);
    machines.forEach((m, idx) => {
      const r = regionMap[m.region] || regions[0];
      const offset = (idx % 6) - 3;
      m._x = (r._x || 60) + offset * 12;
      m._y = (r._y || height/2) + 55 + Math.floor(idx / 6) * 18;
    });

    const mgroup = svg.append("g");
    const nodes = mgroup.selectAll("g.machine").data(machines);
    const enter = nodes.enter().append("g")
      .attr("class", "machine")
      .attr("transform", d => `translate(${d._x}, ${d._y})`)
      .style("cursor", "pointer")
      .on("click", (event, d) => {
        const id = d.id;
        window.liveSocket && window.liveSocket.execJS && window.liveSocket.execJS(this.el, ["phx-click-machine", id]);
        const ev = new CustomEvent("topology:machine:click", {detail: {id}});
        window.dispatchEvent(ev);
      });

    enter.append("rect").attr("width", 12).attr("height", 12).attr("x", -6).attr("y", -6)
      .attr("rx", 2)
      .attr("fill", d => d.status === 'running' ? '#10b981' : d.status === 'stopped' ? '#ef4444' : '#f59e0b');

    enter.append("text").attr("x", 14).attr("y", 4).text(d => d.name).attr("font-size", 10);
  }
}

export default TopologyHook;
