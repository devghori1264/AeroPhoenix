import * as d3 from "d3";
import { ParticleSystem, HeatmapOverlay, RichTooltip, AnimationUtils } from './topology-enhancements.js';

const TopologyHook = {
  mounted() {
    console.log('[TopologyHook] Mounting enhanced topology visualization...');

    this.svg = d3.select(this.el).select("svg");
    this.nodeMap = new Map();
    this.tooltip = null;
    this.selectedNodeId = null;
    this.isDragging = false;
    this.regionPositions = new Map();

    this.particleSystem = null;
    this.heatmapOverlay = null;
    this.richTooltip = null;

    const raw = this.el.dataset.topology;
    try {
      this.data = JSON.parse(raw || "{}");
      this.activeChaos = this.data.active_chaos || [];
      console.log('[TopologyHook] Parsed data:', {
        regions: this.data.regions?.length || 0,
        machines: this.data.machines?.length || 0,
        activeChaos: this.activeChaos.length
      });
    } catch (e) {
      console.warn('[TopologyHook] Failed to parse topology data:', e);
      this.data = { regions: [], machines: [], active_chaos: [] };
      this.activeChaos = [];
    }

    this.reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.setupTooltip();
    this.setupDefs();
    this.initializeEnhancements();
    this.render(this.data);

    this.handleEvent("topology:update", (payload) => {
      console.log('[TopologyHook] Received topology update:', payload);
      console.log('[TopologyHook] Payload regions:', payload.regions?.length, 'machines:', payload.machines?.length, 'chaos:', payload.active_chaos?.length);

      const newRegions = (payload.regions && payload.regions.length > 0) ? payload.regions : this.data.regions;
      const newMachines = (payload.machines && payload.machines.length > 0) ? payload.machines : this.data.machines;
      const newChaos = payload.active_chaos !== undefined ? payload.active_chaos : this.data.active_chaos;

      console.log('[TopologyHook] Using regions:', newRegions?.length, 'machines:', newMachines?.length, 'chaos:', newChaos?.length);

      this.data = {
        regions: newRegions || [],
        machines: newMachines || [],
        active_chaos: newChaos || []
      };
      this.activeChaos = this.data.active_chaos;
      console.log('[TopologyHook] Updated activeChaos:', this.activeChaos.length, 'incidents');
      this.render(this.data);
    });

    this.resizeHandler = () => this.render(this.data);
    window.addEventListener('resize', this.resizeHandler);

    console.log('[TopologyHook] Topology visualization mounted successfully');
  },

  updated() {
    console.log('[TopologyHook] Component updated, re-reading data-topology attribute');
    const raw = this.el.dataset.topology;
    try {
      const newData = JSON.parse(raw || "{}");
      console.log('[TopologyHook] Updated data:', {
        regions: newData.regions?.length || 0,
        machines: newData.machines?.length || 0,
        activeChaos: newData.active_chaos?.length || 0
      });

      if (newData.machines && newData.machines.length > 0) {
        this.data = {
          regions: newData.regions || this.data.regions || [],
          machines: newData.machines || this.data.machines || [],
          active_chaos: newData.active_chaos || []
        };
        this.activeChaos = this.data.active_chaos;
        this.render(this.data);
      }
    } catch (e) {
      console.warn('[TopologyHook] Failed to parse updated topology data:', e);
    }
  },

  destroyed() {
    console.log('[TopologyHook] Cleaning up topology visualization...');

    if (this.particleSystem) {
      this.particleSystem.stop();
    }
    if (this.heatmapOverlay) {
      this.heatmapOverlay.hide();
    }
    if (this.richTooltip) {
      this.richTooltip.hide();
    }

    if (this.tooltip) {
      this.tooltip.remove();
    }
    if (this.resizeHandler) {
      window.removeEventListener('resize', this.resizeHandler);
    }
  },

  setupTooltip() {
    let tooltip = document.querySelector('.topology-tooltip');
    if (!tooltip) {
      tooltip = document.createElement('div');
      tooltip.className = 'topology-tooltip';
      document.body.appendChild(tooltip);
    }
    this.tooltip = tooltip;
  },

  initializeEnhancements() {
    console.log('[TopologyHook] Initializing enhancement systems...');

    this.particleSystem = new ParticleSystem(this.svg);

    this.heatmapOverlay = new HeatmapOverlay(this.svg);
    this.heatmapOverlay.initialize();

    this.richTooltip = new RichTooltip();

    this.initializeZoomPan();

    console.log('[TopologyHook] Enhancement systems initialized');
  },

  initializeZoomPan() {
    let zoomGroup = this.svg.select('g.zoom-container');
    if (zoomGroup.empty()) {
      zoomGroup = this.svg.append('g').attr('class', 'zoom-container');
    }
    this.zoomGroup = zoomGroup;

    const zoom = d3.zoom()
      .scaleExtent([0.3, 3])
      .on('zoom', (event) => {
        if (!this.isDragging) {
          this.zoomGroup.attr('transform', event.transform);
        }
      });

    this.svg.call(zoom);

    this.addZoomControls(zoom);

    this.zoomBehavior = zoom;

    console.log('[TopologyHook] Zoom/pan controls initialized');
  },

  addZoomControls(zoom) {

    const existingControls = this.el.querySelector('.topology-zoom-controls');
    if (existingControls) {
      existingControls.remove();
    }

    const controls = document.createElement('div');
    controls.className = 'topology-zoom-controls';
    controls.innerHTML = `
      <button class="zoom-btn" data-action="zoom-in" title="Zoom In">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path d="M7 2v10M2 7h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
        </svg>
      </button>
      <button class="zoom-btn" data-action="zoom-out" title="Zoom Out">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path d="M2 7h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
        </svg>
      </button>
      <span class="zoom-divider"></span>
      <button class="zoom-btn" data-action="zoom-reset" title="Reset View">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <rect x="2" y="2" width="10" height="10" rx="1" stroke="currentColor" stroke-width="1.5" fill="none"/>
          <circle cx="7" cy="7" r="2" stroke="currentColor" stroke-width="1.5" fill="none"/>
        </svg>
      </button>
    `;

    this.el.appendChild(controls);

    controls.querySelector('[data-action="zoom-in"]').addEventListener('click', (e) => {
      e.stopPropagation();
      this.svg.transition().duration(300).call(zoom.scaleBy, 1.3);
    });

    controls.querySelector('[data-action="zoom-out"]').addEventListener('click', (e) => {
      e.stopPropagation();
      this.svg.transition().duration(300).call(zoom.scaleBy, 0.7);
    });

    controls.querySelector('[data-action="zoom-reset"]').addEventListener('click', (e) => {
      e.stopPropagation();
      this.svg.transition().duration(500).call(
        zoom.transform,
        d3.zoomIdentity
      );
    });
  },

  setupDefs() {

    this.svg.selectAll("defs").remove();

    const defs = this.svg.append("defs");

    const glowFilter = defs.append("filter")
      .attr("id", "topology-glow")
      .attr("x", "-100%")
      .attr("y", "-100%")
      .attr("width", "300%")
      .attr("height", "300%");

    glowFilter.append("feGaussianBlur")
      .attr("in", "SourceGraphic")
      .attr("stdDeviation", 4)
      .attr("result", "blur");

    const glowMerge = glowFilter.append("feMerge");
    glowMerge.append("feMergeNode").attr("in", "blur");
    glowMerge.append("feMergeNode").attr("in", "blur");
    glowMerge.append("feMergeNode").attr("in", "SourceGraphic");

    const shadowFilter = defs.append("filter")
      .attr("id", "topology-shadow")
      .attr("x", "-50%")
      .attr("y", "-50%")
      .attr("width", "200%")
      .attr("height", "200%");

    shadowFilter.append("feGaussianBlur")
      .attr("in", "SourceAlpha")
      .attr("stdDeviation", 2.5);

    shadowFilter.append("feOffset")
      .attr("dx", 0)
      .attr("dy", 2)
      .attr("result", "offsetblur");

    const shadowMerge = shadowFilter.append("feMerge");
    shadowMerge.append("feMergeNode");
    shadowMerge.append("feMergeNode").attr("in", "SourceGraphic");

    const regionGradient = defs.append("radialGradient")
      .attr("id", "region-gradient")
      .attr("cx", "50%")
      .attr("cy", "50%")
      .attr("r", "50%");

    regionGradient.append("stop")
      .attr("offset", "0%")
      .attr("style", "stop-color:#8b5cf6;stop-opacity:1");

    regionGradient.append("stop")
      .attr("offset", "100%")
      .attr("style", "stop-color:#6366f1;stop-opacity:1");

    const lineGradient = defs.append("linearGradient")
      .attr("id", "connection-gradient")
      .attr("x1", "0%")
      .attr("y1", "0%")
      .attr("x2", "100%")
      .attr("y2", "0%");

    lineGradient.append("stop")
      .attr("offset", "0%")
      .attr("style", "stop-color:#8b5cf6;stop-opacity:0.3");

    lineGradient.append("stop")
      .attr("offset", "100%")
      .attr("style", "stop-color:#8b5cf6;stop-opacity:0.05");
  },

  render(data) {
    const machines = data.machines || [];
    const regions = data.regions || [];

    console.log(`[TopologyHook] Rendering ${machines.length} machines across ${regions.length} regions`);

    if (machines.length === 0) {
      console.warn('[TopologyHook] No machines to render!');
      return;
    }

    if (regions.length === 0) {
      console.warn('[TopologyHook] No regions to render!');
      return;
    }
    
    const svgNode = this.svg.node();
    const parentNode = this.el;
    const width = svgNode?.clientWidth || parentNode?.clientWidth || 1200;
    const height = svgNode?.clientHeight || parentNode?.clientHeight || 600;
    
    console.log(`[TopologyHook] Container dimensions: ${width}x${height}`);

    const layout = this.computeLayout(machines, regions, width, height);

    let regionLayer = this.zoomGroup.select("g.region-layer");
    if (regionLayer.empty()) {
      regionLayer = this.zoomGroup.append("g").attr("class", "topology-layer region-layer");
    }

    let connectionLayer = this.zoomGroup.select("g.connection-layer");
    if (connectionLayer.empty()) {
      connectionLayer = this.zoomGroup.append("g").attr("class", "topology-layer connection-layer");
    }

    let machineLayer = this.zoomGroup.select("g.machine-layer");
    if (machineLayer.empty()) {
      machineLayer = this.zoomGroup.append("g").attr("class", "topology-layer machine-layer");
    }
    this.drawRegions(regionLayer, layout.regionCenters);
    this.drawMachines(machineLayer, layout.machines);

    if (this.heatmapOverlay && layout.regionCenters.length > 1) {
      this.heatmapOverlay.render(layout.regionCenters);
      this.heatmapOverlay.show();
    }

    if (this.particleSystem && !this.reducedMotion) {
      this.startParticleFlow(layout.machines, layout.regionCenters);
    }

    console.log('[TopologyHook] Render complete with enhancements');
  },

  computeLayout(machines, regions, width, height) {
    const regionCount = regions.length || 1;
    const padding = 120;
    const usableWidth = width - 2 * padding;
    const usableHeight = height - 2 * padding;
    const regionCenters = [];

    if (regionCount === 1) {
      const regionKey = regions[0].name || regions[0].code || 'unknown';
      const savedPos = this.regionPositions.get(regionKey);
      regionCenters.push({
        ...regions[0],
        cx: savedPos ? savedPos.cx : width / 2,
        cy: savedPos ? savedPos.cy : height / 2
      });
    } else if (regionCount === 2) {
      regions.forEach((r, i) => {
        const regionKey = r.name || r.code || 'unknown';
        const savedPos = this.regionPositions.get(regionKey);
        if (savedPos) {
          regionCenters.push({ ...r, cx: savedPos.cx, cy: savedPos.cy });
        } else {
          regionCenters.push({
            ...r,
            cx: padding + (i * usableWidth * 0.8),
            cy: height / 2
          });
        }
      });
    } else {
      const radius = Math.min(usableWidth, usableHeight) / 2.2;
      const angleStep = (2 * Math.PI) / regionCount;

      regions.forEach((r, i) => {
        const regionKey = r.name || r.code || 'unknown';
        const savedPos = this.regionPositions.get(regionKey);
        if (savedPos) {
          regionCenters.push({ ...r, cx: savedPos.cx, cy: savedPos.cy });
        } else {
          const angle = i * angleStep - Math.PI / 2;
          regionCenters.push({
            ...r,
            cx: width / 2 + Math.cos(angle) * radius,
            cy: height / 2 + Math.sin(angle) * radius
          });
        }
      });
    }

    const machinePositions = [];
    const groupedByRegion = d3.group(machines, m => m.region || 'unknown');
    regionCenters.forEach(regionCenter => {
      const regionMachines = groupedByRegion.get(regionCenter.name || regionCenter.code) || [];
      const machineCount = regionMachines.length;

      if (machineCount === 0) return;

      const baseOrbitRadius = 85;
      const orbitSpacing = 70;
      let machinesPlaced = 0;
      let orbitIndex = 0;
      while (machinesPlaced < machineCount) {
        const machinesInThisOrbit = 6 * (orbitIndex + 1);
        const machinesForThisOrbit = Math.min(machinesInThisOrbit, machineCount - machinesPlaced);
        const orbitRadius = baseOrbitRadius + (orbitIndex * orbitSpacing);

        for (let i = 0; i < machinesForThisOrbit; i++) {
          const machineIdx = machinesPlaced + i;

          const angleStep = (2 * Math.PI) / machinesForThisOrbit;
          const angle = i * angleStep - Math.PI / 2;

          const absoluteX = regionCenter.cx + Math.cos(angle) * orbitRadius;
          const absoluteY = regionCenter.cy + Math.sin(angle) * orbitRadius;
          machinePositions.push({
            ...regionMachines[machineIdx],
            cx: absoluteX,
            cy: absoluteY,
            regionCenter: regionCenter,
            orbitRadius: orbitRadius,
            orbitIndex: orbitIndex,
            relativeAngle: angle,
            relativeDistance: orbitRadius
          });
        }
        machinesPlaced += machinesForThisOrbit;
        orbitIndex++;
      }
    });

    return {
      regionCenters,
      machines: machinePositions
    };
  },

  drawRegions(layer, regionCenters) {
    const self = this;

    const machinesByRegion = d3.group(this.data.machines || [], m => m.region || 'unknown');
    const regions = layer.selectAll("g.region-node")
      .data(regionCenters, d => d.name || d.code)
      .join(
        enter => {
          const g = enter.append("g")
            .attr("class", "region-node")
            .attr("transform", d => `translate(${d.cx}, ${d.cy})`)
            .attr("opacity", 0)
            .style("cursor", "move");

          g.each(function (d) {
            const regionKey = d.name || d.code || 'unknown';
            const regionMachines = machinesByRegion.get(regionKey) || [];
            const machineCount = regionMachines.length;
            const baseOrbitRadius = 85;
            const orbitSpacing = 70;

            const orbitsGroup = d3.select(this).append("g").attr("class", "orbits-group");
            let machinesPlaced = 0;
            let orbitIndex = 0;

            while (machinesPlaced < machineCount) {
              const machinesInThisOrbit = 6 * (orbitIndex + 1);
              const orbitRadius = baseOrbitRadius + (orbitIndex * orbitSpacing);

              orbitsGroup.append("circle")
                .attr("class", "orbit-circle")
                .attr("r", orbitRadius)
                .attr("fill", "none")
                .attr("stroke", "rgba(139, 92, 246, 0.25)")
                .attr("stroke-width", 1.5)
                .attr("stroke-dasharray", "5,5");

              machinesPlaced += Math.min(machinesInThisOrbit, machineCount - machinesPlaced);
              orbitIndex++;
            }
          });

          g.append("circle")
            .attr("class", "region-glow")
            .attr("r", 55)
            .attr("fill", "none")
            .attr("stroke", "url(#region-gradient)")
            .attr("stroke-width", 2)
            .attr("stroke-opacity", 0.15)
            .attr("stroke-dasharray", "5,5");

          g.append("circle")
            .attr("class", "region-main")
            .attr("r", 42)
            .attr("fill", "url(#region-gradient)")
            .attr("stroke", "rgba(255, 255, 255, 0.3)")
            .attr("stroke-width", 2.5)
            .attr("filter", "url(#topology-shadow)");

          g.append("circle")
            .attr("r", 38)
            .attr("fill", "none")
            .attr("stroke", "rgba(255, 255, 255, 0.15)")
            .attr("stroke-width", 1);

          g.append("text")
            .attr("y", -8)
            .attr("text-anchor", "middle")
            .attr("fill", "white")
            .attr("font-size", 20)
            .attr("opacity", 0.9)
            .style("pointer-events", "none")
            .text(d => self.getRegionEmoji(d.name || d.code));

          g.append("text")
            .attr("y", 10)
            .attr("text-anchor", "middle")
            .attr("fill", "white")
            .attr("font-size", 11)
            .attr("font-weight", 700)
            .attr("letter-spacing", "0.5px")
            .style("pointer-events", "none")
            .text(d => (d.name || d.code || 'unknown').toUpperCase().substring(0, 10));

          const badge = g.append("g")
            .attr("transform", "translate(0, 25)")
            .style("pointer-events", "none");

          badge.append("rect")
            .attr("x", -25)
            .attr("y", -8)
            .attr("width", 50)
            .attr("height", 16)
            .attr("rx", 8)
            .attr("fill", "rgba(255, 255, 255, 0.25)")
            .attr("stroke", "rgba(255, 255, 255, 0.3)")
            .attr("stroke-width", 1);
          badge.append("text")
            .attr("y", 4)
            .attr("text-anchor", "middle")
            .attr("fill", "white")
            .attr("font-size", 10)
            .attr("font-weight", 600)
            .text(d => `${d.count || 0} nodes`);

          const drag = d3.drag()
            .on("start", function (event, d) {
              self.isDragging = true;
              d3.select(this).raise();
              d3.select(this).style("cursor", "grabbing");
            })
            .on("drag", function (event, d) {
              const newX = event.x;
              const newY = event.y;

              const deltaX = newX - d.cx;
              const deltaY = newY - d.cy;

              d.cx = newX;
              d.cy = newY;

              const regionKey = d.name || d.code || 'unknown';
              self.regionPositions.set(regionKey, { cx: newX, cy: newY });

              d3.select(this).attr("transform", `translate(${newX}, ${newY})`);

              const regionMachines = self.svg.selectAll(".machine-node")
                .filter(m => (m.region || 'unknown') === regionKey);

              regionMachines.each(function (m) {
                m.cx += deltaX;
                m.cy += deltaY;
                m.regionCenter.cx = newX;
                m.regionCenter.cy = newY;
                d3.select(this).attr("transform", `translate(${m.cx}, ${m.cy})`);

                const dx = newX - m.cx;
                const dy = newY - m.cy;

                d3.select(this).select(".connection-line")
                  .attr("x2", dx)
                  .attr("y2", dy);

                const dr = Math.sqrt(dx * dx + dy * dy);
                const controlX = dx * 0.5 + dy * 0.1;
                const controlY = dy * 0.5 - dx * 0.1;
                d3.select(this).select(".connection-curve")
                  .attr("d", `M 0,0 Q ${controlX},${controlY} ${dx},${dy}`);
              });
            })
            .on("end", function () {
              self.isDragging = false;
              d3.select(this).style("cursor", "move");
            });
          g.call(drag);

          if (!this.reducedMotion) {
            g.attr("transform", d => `translate(${d.cx}, ${d.cy}) scale(0.3)`)
              .transition()
              .duration(500)
              .attr("transform", d => `translate(${d.cx}, ${d.cy}) scale(1)`)
              .attr("opacity", 1);

            g.select(".region-glow")
              .transition()
              .duration(2000)
              .attr("r", 60)
              .attr("stroke-opacity", 0.05)
              .transition()
              .duration(2000)
              .attr("r", 55)
              .attr("stroke-opacity", 0.15)
              .on("end", function repeat() {
                d3.select(this)
                  .transition()
                  .duration(2000)
                  .attr("r", 60)
                  .attr("stroke-opacity", 0.05)
                  .transition()
                  .duration(2000)
                  .attr("r", 55)
                  .attr("stroke-opacity", 0.15)
                  .on("end", repeat);
              });
          } else {
            g.attr("opacity", 1);
          }

          return g;
        },
        update => {
          update.each(function (d) {
            const regionKey = d.name || d.code || 'unknown';
            const regionMachines = machinesByRegion.get(regionKey) || [];
            const machineCount = regionMachines.length;
            const baseOrbitRadius = 85;
            const orbitSpacing = 70;
            const orbitsGroup = d3.select(this).select(".orbits-group");
            orbitsGroup.selectAll(".orbit-circle").remove();

            let machinesPlaced = 0;
            let orbitIndex = 0;
            while (machinesPlaced < machineCount) {
              const machinesInThisOrbit = 6 * (orbitIndex + 1);
              const orbitRadius = baseOrbitRadius + (orbitIndex * orbitSpacing);

              orbitsGroup.append("circle")
                .attr("class", "orbit-circle")
                .attr("r", orbitRadius)
                .attr("fill", "none")
                .attr("stroke", "rgba(139, 92, 246, 0.25)")
                .attr("stroke-width", 1.5)
                .attr("stroke-dasharray", "5,5");

              machinesPlaced += Math.min(machinesInThisOrbit, machineCount - machinesPlaced);
              orbitIndex++;
            }
          });

          update.select("text:last-child")
            .text(d => `${d.count || 0} nodes`);
          return update;
        }
      );
  },

  getRegionEmoji(region) {
    const regionStr = String(region).toLowerCase();
    if (regionStr.includes('us-east') || regionStr.includes('useast')) return '🇺🇸';
    if (regionStr.includes('us-west') || regionStr.includes('uswest')) return '🌉';
    if (regionStr.includes('eu-west') || regionStr.includes('euwest')) return '🇪🇺';
    if (regionStr.includes('ap-south') || regionStr.includes('apsouth')) return '🇮🇳';
    if (regionStr.includes('ap-east') || regionStr.includes('apeast')) return '🇯🇵';
    return '🌐';
  },

  drawMachines(layer, machines) {
    const self = this;

    const machineNodes = layer.selectAll("g.machine-node")
      .data(machines, d => d.id)
      .join(
        enter => {
          const g = enter.append("g")
            .attr("class", "topology-node machine-node")
            .attr("data-node-id", d => d.id)
            .attr("tabindex", 0)
            .attr("role", "button")
            .attr("aria-label", d => `Machine ${d.name} in ${d.region}, status: ${d.status}`)
            .attr("transform", d => `translate(${d.cx}, ${d.cy})`)
            .attr("opacity", 0)
            .style("cursor", "pointer");

          g.each(function (d) {
            const node = d3.select(this);

            node.append("line")
              .attr("class", "connection-line")
              .attr("x1", 0)
              .attr("y1", 0)
              .attr("x2", d => d.regionCenter.cx - d.cx)
              .attr("y2", d => d.regionCenter.cy - d.cy)
              .attr("stroke", "url(#connection-gradient)")
              .attr("stroke-width", 1)
              .attr("stroke-dasharray", "3,3")
              .attr("opacity", 0.4);

            node.append("path")
              .attr("class", "connection-curve")
              .attr("d", d => {
                const dx = d.regionCenter.cx - d.cx;
                const dy = d.regionCenter.cy - d.cy;
                const controlX = dx * 0.5 + dy * 0.1;
                const controlY = dy * 0.5 - dx * 0.1;
                return `M 0,0 Q ${controlX},${controlY} ${dx},${dy}`;
              })
              .attr("fill", "none")
              .attr("stroke", "rgba(139, 92, 246, 0.15)")
              .attr("stroke-width", 2)
              .attr("opacity", 0);

            node.append("circle")
              .attr("class", "machine-select-ring")
              .attr("r", 14)
              .attr("fill", "none")
              .attr("stroke", d => self.getStatusColor(d.status))
              .attr("stroke-width", 2)
              .attr("opacity", 0);

            node.append("circle")
              .attr("class", "machine-main")
              .attr("r", 10)
              .attr("fill", d => self.getStatusColor(d.status))
              .attr("stroke", "white")
              .attr("stroke-width", 2.5)
              .attr("filter", "url(#topology-shadow)");

            node.append("circle")
              .attr("class", "status-pulse")
              .attr("r", 3)
              .attr("fill", "white")
              .attr("opacity", 0.9);

            const labelGroup = node.append("g")
              .attr("class", "machine-label")
              .attr("transform", "translate(0, 22)");

            const labelText = labelGroup.append("text")
              .attr("text-anchor", "middle")
              .attr("font-size", 10)
              .attr("font-weight", 600)
              .attr("fill", "var(--text)")
              .text(d => (d.name || d.id).substring(0, 12));

            try {
              const bbox = labelText.node().getBBox();
              labelGroup.insert("rect", "text")
                .attr("x", bbox.x - 3)
                .attr("y", bbox.y - 1)
                .attr("width", bbox.width + 6)
                .attr("height", bbox.height + 2)
                .attr("rx", 3)
                .attr("fill", "var(--surface)")
                .attr("opacity", 0.9);
            } catch (e) {
              console.warn('[TopologyHook] Failed to calculate BBox for label:', e);
            }
          });

          g.each(function (d) {
            try {
              const hasChaos = self.isMachineUnderChaos(d);
              console.log(`[TopologyHook] Machine ${d.id}: hasChaos=${hasChaos}, activeChaos.length=${self.activeChaos?.length || 0}`);
              if (hasChaos) {
                console.log(`[TopologyHook] Adding chaos effects to machine ${d.id}`);
                const machineGroup = d3.select(this);

                machineGroup.append("circle")
                  .attr("class", "chaos-ring")
                  .attr("r", 16)
                  .attr("fill", "none")
                  .attr("stroke", "#f43f5e")
                  .attr("stroke-width", 3)
                  .attr("opacity", 0.8)
                  .transition()
                  .duration(800)
                  .attr("r", 20)
                  .attr("opacity", 0)
                  .on("end", function repeat() {
                    d3.select(this)
                      .attr("r", 16)
                      .attr("opacity", 0.8)
                      .transition()
                      .duration(800)
                      .attr("r", 20)
                      .attr("opacity", 0)
                      .on("end", repeat);
                  });

                machineGroup.append("text")
                  .attr("class", "chaos-icon")
                  .attr("x", 14)
                  .attr("y", -10)
                  .attr("text-anchor", "middle")
                  .attr("font-size", 16)
                  .text("🔥")
                  .transition()
                  .duration(500)
                  .attr("font-size", 18)
                  .transition()
                  .duration(500)
                  .attr("font-size", 16)
                  .on("end", function repeat() {
                    d3.select(this)
                      .transition()
                      .duration(500)
                      .attr("font-size", 18)
                      .transition()
                      .duration(500)
                      .attr("font-size", 16)
                      .on("end", repeat);
                  });

                machineGroup.select(".machine-main")
                  .attr("fill", "#f43f5e")
                  .attr("filter", "url(#topology-glow)");
              }
            } catch (e) {
              console.warn('[TopologyHook] Error adding chaos visualization:', e);
            }
          });

          if (!this.reducedMotion) {
            g.attr("transform", d => `translate(${d.cx}, ${d.cy}) scale(0)`)
              .transition()
              .duration(400)
              .delay((d, i) => i * 25)
              .attr("transform", d => `translate(${d.cx}, ${d.cy}) scale(1)`)
              .attr("opacity", 1);

            g.select(".status-pulse")
              .transition()
              .duration(1000)
              .attr("r", 4)
              .attr("opacity", 0.3)
              .transition()
              .duration(1000)
              .attr("r", 3)
              .attr("opacity", 0.9)
              .on("end", function repeat() {
                d3.select(this)
                  .transition()
                  .duration(1000)
                  .attr("r", 4)
                  .attr("opacity", 0.3)
                  .transition()
                  .duration(1000)
                  .attr("r", 3)
                  .attr("opacity", 0.9)
                  .on("end", repeat);
              });
          } else {
            g.attr("opacity", 1);
          }

          g.on("click", function (event, d) {
            event.stopPropagation();
            self.handleMachineClick(d, this);
          });

          g.on("mouseenter", function (event, d) {
            if (self.richTooltip) {
              self.richTooltip.show(d, event.pageX, event.pageY);
            } else {
              self.showTooltip(d, event);
            }

            if (!self.reducedMotion) {
              d3.select(this).select(".machine-main")
                .transition()
                .duration(200)
                .attr("r", 12)
                .attr("filter", "url(#topology-glow)");

              d3.select(this).select(".connection-line")
                .transition()
                .duration(200)
                .attr("opacity", 0.8)
                .attr("stroke-width", 2);

              d3.select(this).select(".connection-curve")
                .transition()
                .duration(300)
                .attr("opacity", 0.6);
            }
          });

          g.on("mouseleave", function (event, d) {
            if (self.richTooltip) {
              self.richTooltip.hide();
            }
            self.hideTooltip();

            if (!self.reducedMotion) {
              d3.select(this).select(".machine-main")
                .transition()
                .duration(200)
                .attr("r", 10)
                .attr("filter", "url(#topology-shadow)");
              d3.select(this).select(".connection-line")
                .transition()
                .duration(200)
                .attr("opacity", 0.4)
                .attr("stroke-width", 1);

              d3.select(this).select(".connection-curve")
                .transition()
                .duration(200)
                .attr("opacity", 0);
            }
          });
          g.on("keydown", function (event, d) {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              self.handleMachineClick(d, this);
            }
          });
          return g;
        },
        update => {
          update.select(".machine-main")
            .transition()
            .duration(300)
            .attr("fill", d => self.getStatusColor(d.status));
          update.select(".machine-select-ring")
            .attr("stroke", d => self.getStatusColor(d.status));
          update.select(".connection-line")
            .transition()
            .duration(400)
            .attr("x2", d => d.regionCenter.cx - d.cx)
            .attr("y2", d => d.regionCenter.cy - d.cy);
          if (!this.reducedMotion) {
            update.transition()
              .duration(500)
              .attr("transform", d => `translate(${d.cx}, ${d.cy})`);
          } else {
            update.attr("transform", d => `translate(${d.cx}, ${d.cy})`);
          }
          return update;
        },
        exit => {
          if (!this.reducedMotion) {
            exit.transition()
              .duration(200)
              .attr("opacity", 0)
              .remove();
          } else {
            exit.remove();
          }
        }
      );
  },

  getStatusColor(status) {
    const statusStr = String(status).toLowerCase();
    const colors = {
      running: 'var(--c-emerald-500)',
      stopped: 'var(--c-sky-500)',
      migrating: 'var(--c-indigo-500)',
      pending: 'var(--c-amber-500)',
      terminated: 'var(--c-rose-500)',
      error: 'var(--c-rose-500)',
      unknown: 'var(--c-primary-600)'
    };
    return colors[statusStr] || colors.unknown;
  },

  isMachineUnderChaos(machine) {
    try {
      if (!this.activeChaos || !Array.isArray(this.activeChaos) || this.activeChaos.length === 0) {
        return false;
      }

      return this.activeChaos.some(chaos => {
        const target = chaos.target || chaos['target'];
        const machineId = machine.id || '';
        const machineName = machine.name || '';
        if (target === null || target === undefined || target === '' || target === 'unknown') {
          return true;
        }

        return target === machineId || target === machineName;
      });
    } catch (e) {
      console.warn('[TopologyHook] Error checking chaos status:', e);
      return false;
    }
  },

  handleMachineClick(machine, element) {
    console.log('[TopologyHook] Machine clicked:', machine.id);

    this.svg.selectAll(".machine-node").classed("selected", false);
    this.svg.selectAll(".machine-select-ring")
      .transition()
      .duration(200)
      .attr("opacity", 0);

    d3.select(element).classed("selected", true);
    d3.select(element).select(".machine-select-ring")
      .transition()
      .duration(300)
      .attr("opacity", 1)
      .attr("r", 16);
    this.selectedNodeId = machine.id;

    this.pushEvent("select_machine", { id: machine.id });
  },

  showTooltip(machine, event) {
    if (!this.tooltip) return;

    const html = `
      <div class="topology-tooltip-title">${machine.name || machine.id}</div>
      <div class="topology-tooltip-row">
        <span class="topology-tooltip-label">Region:</span>
        <span class="topology-tooltip-value">${machine.region || 'unknown'}</span>
      </div>
      <div class="topology-tooltip-row">
        <span class="topology-tooltip-label">Status:</span>
        <span class="topology-tooltip-value" style="color: ${this.getStatusColor(machine.status)}">${machine.status || 'unknown'}</span>
      </div>
      <div class="topology-tooltip-row">
        <span class="topology-tooltip-label">CPU:</span>
        <span class="topology-tooltip-value">${Math.round(machine.cpu || 0)}%</span>
      </div>
      <div class="topology-tooltip-row">
        <span class="topology-tooltip-label">Memory:</span>
        <span class="topology-tooltip-value">${machine.memory_mb || 0} MB</span>
      </div>
      <div class="topology-tooltip-row">
        <span class="topology-tooltip-label">Latency:</span>
        <span class="topology-tooltip-value">${machine.latency || 0} ms</span>
      </div>
    `;

    this.tooltip.innerHTML = html;
    this.tooltip.classList.add('visible');

    const tooltipWidth = 220;
    const tooltipHeight = 160;
    const padding = 10;

    let left = event.pageX + padding;
    let top = event.pageY + padding;

    if (left + tooltipWidth > window.innerWidth) {
      left = event.pageX - tooltipWidth - padding;
    }
    if (top + tooltipHeight > window.innerHeight) {
      top = event.pageY - tooltipHeight - padding;
    }

    this.tooltip.style.left = `${left}px`;
    this.tooltip.style.top = `${top}px`;
  },

  hideTooltip() {
    if (this.tooltip) {
      this.tooltip.classList.remove('visible');
    }
  },

  startParticleFlow(machines, regionCenters) {
    if (!this.particleSystem) return;

    this.particleSystem.start();

    machines.forEach((machine, index) => {
      const regionCenter = machine.regionCenter;
      if (!regionCenter) return;

      setTimeout(() => {
        this.particleSystem.spawnParticles(machine, regionCenter, 3, machine.latency || 50);
      }, index * 100);
    });

    if (this.particleInterval) {
      clearInterval(this.particleInterval);
    }

    this.particleInterval = setInterval(() => {
      const randomMachine = machines[Math.floor(Math.random() * machines.length)];
      if (randomMachine && randomMachine.regionCenter) {
        this.particleSystem.spawnParticles(
          randomMachine,
          randomMachine.regionCenter,
          1,
          randomMachine.latency || 50
        );
      }
    }, 2000);
  }
};

export default TopologyHook;