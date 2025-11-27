export class ParticleSystem {
  constructor(svg) {
    this.svg = svg;
    this.particles = [];
    this.particleLayer = null;
    this.animationFrame = null;
  }

  initialize() {
    let layer = this.svg.select("g.particle-layer");
    if (layer.empty()) {
      layer = this.svg.append("g")
        .attr("class", "particle-layer")
        .style("pointer-events", "none");
    }
    this.particleLayer = layer;
  }

  createParticle(sourceNode, targetNode, latency = 50) {
    const particle = {
      id: `particle-${Date.now()}-${Math.random()}`,
      sx: sourceNode.x,
      sy: sourceNode.y,
      tx: targetNode.x,
      ty: targetNode.y,
      progress: 0,
      speed: this.calculateSpeed(latency),
      color: this.getLatencyColor(latency),
      size: 3 + Math.random() * 2,
      opacity: 0.8
    };
    this.particles.push(particle);
    return particle;
  }

  calculateSpeed(latency) {
    return Math.max(0.001, 0.03 / (latency / 10));
  }

  getLatencyColor(latency) {
    if (latency < 20) return "#10b981";
    if (latency < 50) return "#3b82f6";
    if (latency < 100) return "#f59e0b";
    return "#ef4444";
  }

  spawnParticles(sourceNode, targetNode, count = 3, latency = 50) {
    for (let i = 0; i < count; i++) {
      setTimeout(() => {
        this.createParticle(sourceNode, targetNode, latency);
      }, i * 200);
    }
  }

  update() {
    this.particles = this.particles.filter(p => p.progress < 1);

    this.particles.forEach(p => {
      p.progress += p.speed;
      p.opacity = Math.sin(p.progress * Math.PI) * 0.8;
    });

    this.render();

    if (this.particles.length > 0) {
      this.animationFrame = requestAnimationFrame(() => this.update());
    } else {
      this.animationFrame = null;
    }
  }

  render() {
    if (!this.particleLayer) return;

    const circles = this.particleLayer.selectAll("circle.particle")
      .data(this.particles, d => d.id);

    circles.enter()
      .append("circle")
      .attr("class", "particle")
      .attr("r", d => d.size)
      .attr("fill", d => d.color)
      .attr("cx", d => d.sx)
      .attr("cy", d => d.sy)
      .merge(circles)
      .attr("cx", d => d.sx + (d.tx - d.sx) * d.progress)
      .attr("cy", d => d.sy + (d.ty - d.sy) * d.progress)
      .attr("opacity", d => d.opacity)
      .attr("filter", "url(#topology-glow)");

    circles.exit().remove();
  }

  start() {
    if (!this.animationFrame) {
      this.update();
    }
  }

  stop() {
    if (this.animationFrame) {
      cancelAnimationFrame(this.animationFrame);
      this.animationFrame = null;
    }
  }

  destroy() {
    this.stop();
    if (this.particleLayer) {
      this.particleLayer.remove();
    }
    this.particles = [];
  }
}

export class HeatmapOverlay {
  constructor(svg, width, height) {
    this.svg = svg;
    this.width = width;
    this.height = height;
    this.heatmapLayer = null;
  }

  initialize() {
    let layer = this.svg.select("g.heatmap-layer");
    if (layer.empty()) {
      layer = this.svg.insert("g", ":first-child")
        .attr("class", "heatmap-layer")
        .style("opacity", 0.3)
        .style("pointer-events", "none");
    }
    this.heatmapLayer = layer;
  }

  render(regionCenters, latencyMatrix) {
    if (!this.heatmapLayer) return;

    const defs = this.svg.select("defs");
    
    regionCenters.forEach((source, i) => {
      regionCenters.forEach((target, j) => {
        if (i >= j) return;

        const latency = latencyMatrix?.[i]?.[j] || 50;
        const color = this.getLatencyGradient(latency);
        const gradientId = `heatmap-${i}-${j}`;

        let gradient = defs.select(`#${gradientId}`);
        if (gradient.empty()) {
          gradient = defs.append("radialGradient")
            .attr("id", gradientId)
            .attr("cx", "50%")
            .attr("cy", "50%")
            .attr("r", "50%");

          gradient.append("stop")
            .attr("offset", "0%")
            .attr("stop-color", color)
            .attr("stop-opacity", 0.6);

          gradient.append("stop")
            .attr("offset", "100%")
            .attr("stop-color", color)
            .attr("stop-opacity", 0);
        }

        const midX = (source.cx + target.cx) / 2;
        const midY = (source.cy + target.cy) / 2;
        const rx = Math.abs(target.cx - source.cx) / 2;
        const ry = Math.abs(target.cy - source.cy) / 2;

        this.heatmapLayer.selectAll(`ellipse.heatmap-${i}-${j}`)
          .data([{ midX, midY, rx, ry, gradientId }])
          .join("ellipse")
          .attr("class", `heatmap-${i}-${j}`)
          .attr("cx", d => d.midX)
          .attr("cy", d => d.midY)
          .attr("rx", d => d.rx)
          .attr("ry", d => d.ry)
          .attr("fill", d => `url(#${d.gradientId})`);
      });
    });
  }

  getLatencyGradient(latency) {
    if (latency < 20) return "#10b981";
    if (latency < 50) return "#3b82f6";
    if (latency < 100) return "#f59e0b";
    return "#ef4444";
  }

  hide() {
    if (this.heatmapLayer) {
      this.heatmapLayer.style("opacity", 0);
    }
  }

  show() {
    if (this.heatmapLayer) {
      this.heatmapLayer.transition().duration(300).style("opacity", 0.3);
    }
  }

  destroy() {
    if (this.heatmapLayer) {
      this.heatmapLayer.remove();
    }
  }
}

export class RichTooltip {
  constructor() {
    this.tooltip = null;
    this.createTooltip();
  }

  createTooltip() {
    let tooltip = document.querySelector('.topology-rich-tooltip');
    if (!tooltip) {
      tooltip = document.createElement('div');
      tooltip.className = 'topology-rich-tooltip';
      tooltip.style.cssText = `
        position: absolute;
        padding: 12px 16px;
        background: rgba(15, 23, 42, 0.95);
        backdrop-filter: blur(20px);
        border: 1px solid rgba(100, 116, 139, 0.3);
        border-radius: 12px;
        pointer-events: none;
        opacity: 0;
        transform: translateY(10px);
        transition: opacity 0.2s ease, transform 0.2s ease;
        z-index: 1000;
        max-width: 320px;
        box-shadow: 0 10px 40px rgba(0, 0, 0, 0.5);
      `;
      document.body.appendChild(tooltip);
    }
    this.tooltip = tooltip;
  }

  show(machine, x, y) {
    if (!this.tooltip) return;

    const html = `
      <div style="color: white;">
        <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
          <div style="width: 8px; height: 8px; border-radius: 50%; background: ${this.getStatusColor(machine.status)}; box-shadow: 0 0 10px ${this.getStatusColor(machine.status)};"></div>
          <h4 style="margin: 0; font-size: 14px; font-weight: 600;">${machine.name || machine.id}</h4>
        </div>
        <div style="font-size: 11px; color: rgba(226, 232, 240, 0.7); margin-bottom: 8px;">
          <div>Region: <span style="color: #06b6d4;">${machine.region || 'Unknown'}</span></div>
          <div>Status: <span style="color: ${this.getStatusColor(machine.status)};">${machine.status || 'Unknown'}</span></div>
        </div>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
          <div style="background: rgba(139, 92, 246, 0.1); padding: 6px; border-radius: 6px;">
            <div style="font-size: 10px; color: rgba(226, 232, 240, 0.6); margin-bottom: 2px;">CPU</div>
            <div style="font-size: 14px; font-weight: 600; color: #8b5cf6;">${Math.round(machine.cpu || 0)}%</div>
          </div>
          <div style="background: rgba(139, 92, 246, 0.1); padding: 6px; border-radius: 6px;">
            <div style="font-size: 10px; color: rgba(226, 232, 240, 0.6); margin-bottom: 2px;">Memory</div>
            <div style="font-size: 14px; font-weight: 600; color: #8b5cf6;">${machine.memory_mb || 0}MB</div>
          </div>
        </div>
        ${machine.latency ? `
          <div style="margin-top: 8px; padding-top: 8px; border-top: 1px solid rgba(100, 116, 139, 0.3);">
            <div style="font-size: 10px; color: rgba(226, 232, 240, 0.6);">Network Latency</div>
            <div style="font-size: 12px; color: #06b6d4;">${machine.latency}ms</div>
          </div>
        ` : ''}
      </div>
    `;

    this.tooltip.innerHTML = html;
    this.tooltip.style.left = `${x + 20}px`;
    this.tooltip.style.top = `${y - 20}px`;
    this.tooltip.style.opacity = '1';
    this.tooltip.style.transform = 'translateY(0)';
  }

  hide() {
    if (this.tooltip) {
      this.tooltip.style.opacity = '0';
      this.tooltip.style.transform = 'translateY(10px)';
    }
  }

  getStatusColor(status) {
    const statusMap = {
      running: '#10b981',
      stopped: '#64748b',
      migrating: '#06b6d4',
      error: '#ef4444',
      pending: '#f59e0b'
    };
    return statusMap[status?.toLowerCase()] || '#64748b';
  }

  destroy() {
    if (this.tooltip) {
      this.tooltip.remove();
    }
  }
}

export const AnimationUtils = {
  animateNode(node, targetX, targetY, duration = 600) {
    const startX = parseFloat(node.attr("cx"));
    const startY = parseFloat(node.attr("cy"));
    const startTime = Date.now();

    const animate = () => {
      const elapsed = Date.now() - startTime;
      const progress = Math.min(elapsed / duration, 1);
      const eased = this.easeInOutCubic(progress);

      const currentX = startX + (targetX - startX) * eased;
      const currentY = startY + (targetY - startY) * eased;

      node.attr("cx", currentX).attr("cy", currentY);

      if (progress < 1) {
        requestAnimationFrame(animate);
      }
    };

    animate();
  },

  easeInOutCubic(t) {
    return t < 0.5
      ? 4 * t * t * t
      : 1 - Math.pow(-2 * t + 2, 3) / 2;
  },

  pulseNode(node, count = 3) {
    let currentPulse = 0;
    const pulse = () => {
      node.transition()
        .duration(300)
        .attr("r", parseFloat(node.attr("r")) * 1.3)
        .transition()
        .duration(300)
        .attr("r", parseFloat(node.attr("r")) / 1.3)
        .on("end", () => {
          currentPulse++;
          if (currentPulse < count) {
            pulse();
          }
        });
    };
    pulse();
  },

  animateLine(line, duration = 1000) {
    const length = line.node().getTotalLength();
    line.attr("stroke-dasharray", length)
      .attr("stroke-dashoffset", length)
      .transition()
      .duration(duration)
      .ease(d3.easeLinear)
      .attr("stroke-dashoffset", 0);
  }
};
