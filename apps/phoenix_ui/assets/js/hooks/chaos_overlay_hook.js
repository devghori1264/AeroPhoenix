const ChaosOverlayHook = {
    mounted() {
        this.svg = d3.select(this.el).select("svg")
        this.incidents = []
        this.handleEvent("chaos:update", ({ incidents }) => {
            this.incidents = incidents
            this.render()
        })
    },

    render() {
        const svg = this.svg
        svg.selectAll(".chaos-layer").remove()
        const layer = svg.append("g").attr("class", "chaos-layer")
        this.incidents.forEach(inc => {
            if (inc.kind === "latency_spike") {
                const regionEl = svg.selectAll("text").filter(d => d && d.id === inc.target)
                if (!regionEl.empty()) {
                    const bbox = regionEl.node().getBBox()
                    layer.append("circle")
                    .attr("cx", bbox.x + bbox.width/2)
                    .attr("cy", bbox.y - 6)
                    .attr("r", 0)
                    .attr("fill", "rgba(239,68,68,0.25)")
                    .transition().duration(800).attr("r", 50).style("opacity", 0.7).transition().duration(1000).style("opacity", 0.0).remove()
                }
            } else if (inc.kind === "partition" && inc.payload && inc.payload.link) {
                const src = inc.payload.link.source
                const dst = inc.payload.link.target
                const srcEl = svg.selectAll("text").filter(d => d && d.id === src)
                const dstEl = svg.selectAll("text").filter(d => d && d.id === dst)
                if (!srcEl.empty() && !dstEl.empty()) {
                    const sBox = srcEl.node().getBBox()
                    const dBox = dstEl.node().getBBox()
                    layer.append("line")
                    .attr("x1", sBox.x + sBox.width/2).attr("y1", sBox.y)
                    .attr("x2", dBox.x + dBox.width/2).attr("y2", dBox.y)
                    .attr("stroke", "#ef4444").attr("stroke-width", 2).attr("stroke-dasharray", "6 4")
                    .transition().duration(10000).style("opacity", 0.0).remove()
                }
            }
        })
    }
}

export default ChaosOverlayHook