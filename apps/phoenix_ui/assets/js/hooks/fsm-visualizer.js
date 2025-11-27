import * as d3 from "d3";

const FsmVisualizerHook = {
  mounted() {
    console.log('[FsmVisualizer] Initializing interactive FSM visualization...');
    
    this.svg = d3.select(this.el);
    this.width = this.el.clientWidth;
    this.height = this.el.clientHeight;
    this.reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    
    this.nodes = [];
    this.links = [];
    this.transitionHistory = [];
    this.currentStateIndex = -1;
    this.isPlaying = false;
    
    this.initializeGraph();
    this.parseInitialData();
    this.render();
    
    this.setupPlaybackControls();
    
    this.handleEvent("fsm:state_change", (data) => {
      console.log('[FsmVisualizer] State change:', data);
      this.handleStateChange(data);
    });
    
    this.handleEvent("fsm:transition", (data) => {
      console.log('[FsmVisualizer] Transition:', data);
      this.handleTransition(data);
    });
    
    console.log('[FsmVisualizer] Initialized successfully');
  },
  
  destroyed() {
    console.log('[FsmVisualizer] Cleaning up...');
    if (this.simulation) {
      this.simulation.stop();
    }
    if (this.playbackTimer) {
      clearInterval(this.playbackTimer);
    }
  },
  
  parseInitialData() {
    const dataElement = document.querySelector('[data-fsm-states]');
    if (!dataElement) return;
    
    try {
      const states = JSON.parse(dataElement.dataset.fsmStates || '[]');
      const transitions = JSON.parse(dataElement.dataset.fsmTransitions || '[]');
      
      this.nodes = states.map(state => ({
        id: state.name,
        name: state.name,
        count: state.count || 0,
        active: state.active || false,
        color: this.getStateColor(state.name),
        icon: this.getStateIcon(state.name)
      }));
      
      this.links = transitions.map(t => ({
        source: t.from,
        target: t.to,
        active: t.active || false,
        count: t.count || 0
      }));
      
      console.log('[FsmVisualizer] Parsed data:', { nodes: this.nodes.length, links: this.links.length });
    } catch (e) {
      console.warn('[FsmVisualizer] Error parsing data:', e);
    }
  },
  
  initializeGraph() {
    this.svg.selectAll('*').remove();
    
    this.linkGroup = this.svg.append('g').attr('class', 'fsm-links');
    this.particleGroup = this.svg.append('g').attr('class', 'fsm-particles');
    this.nodeGroup = this.svg.append('g').attr('class', 'fsm-nodes');
    
    this.simulation = d3.forceSimulation()
      .force('link', d3.forceLink().id(d => d.id).distance(150))
      .force('charge', d3.forceManyBody().strength(-500))
      .force('center', d3.forceCenter(this.width / 2, this.height / 2))
      .force('collision', d3.forceCollide().radius(50))
      .on('tick', () => this.ticked());
    
    const zoom = d3.zoom()
      .scaleExtent([0.5, 3])
      .on('zoom', (event) => {
        this.linkGroup.attr('transform', event.transform);
        this.particleGroup.attr('transform', event.transform);
        this.nodeGroup.attr('transform', event.transform);
      });
    
    this.svg.call(zoom);
  },
  
  render() {
    this.simulation
      .nodes(this.nodes)
      .force('link').links(this.links);
    
    this.renderLinks();
    
    this.renderNodes();
    
    this.simulation.alpha(1).restart();
  },
  
  renderLinks() {
    const self = this;
    
    const link = this.linkGroup
      .selectAll('g.fsm-link')
      .data(this.links, d => `${d.source.id || d.source}-${d.target.id || d.target}`)
      .join(
        enter => {
          const g = enter.append('g').attr('class', 'fsm-link');
          
          g.append('path')
            .attr('class', 'link-shadow')
            .attr('fill', 'none')
            .attr('stroke', '#1e293b')
            .attr('stroke-width', 8)
            .attr('opacity', 0.3);
          
          g.append('path')
            .attr('class', 'link-path')
            .attr('fill', 'none')
            .attr('stroke', d => d.active ? '#8b5cf6' : '#334155')
            .attr('stroke-width', d => d.active ? 3 : 1.5)
            .attr('stroke-dasharray', d => d.active ? 'none' : '5,5')
            .attr('opacity', d => d.active ? 1 : 0.3)
            .attr('marker-end', d => d.active ? 'url(#arrow-active)' : 'url(#arrow-inactive)');
          
          g.append('text')
            .attr('class', 'link-label')
            .attr('text-anchor', 'middle')
            .attr('font-size', '10px')
            .attr('fill', '#64748b')
            .attr('dy', -5)
            .text(d => d.count > 0 ? d.count : '');
          
          return g;
        },
        update => {
          update.select('.link-path')
            .transition()
            .duration(300)
            .attr('stroke', d => d.active ? '#8b5cf6' : '#334155')
            .attr('stroke-width', d => d.active ? 3 : 1.5)
            .attr('opacity', d => d.active ? 1 : 0.3);
          
          update.select('.link-label')
            .text(d => d.count > 0 ? d.count : '');
          
          return update;
        }
      );
    
    const defs = this.svg.select('defs').empty() ? this.svg.append('defs') : this.svg.select('defs');
    
    if (defs.select('#arrow-active').empty()) {
      defs.append('marker')
        .attr('id', 'arrow-active')
        .attr('viewBox', '0 -5 10 10')
        .attr('refX', 25)
        .attr('refY', 0)
        .attr('markerWidth', 6)
        .attr('markerHeight', 6)
        .attr('orient', 'auto')
        .append('path')
        .attr('d', 'M0,-5L10,0L0,5')
        .attr('fill', '#8b5cf6');
    }
    
    if (defs.select('#arrow-inactive').empty()) {
      defs.append('marker')
        .attr('id', 'arrow-inactive')
        .attr('viewBox', '0 -5 10 10')
        .attr('refX', 25)
        .attr('refY', 0)
        .attr('markerWidth', 6)
        .attr('markerHeight', 6)
        .attr('orient', 'auto')
        .append('path')
        .attr('d', 'M0,-5L10,0L0,5')
        .attr('fill', '#334155');
    }
  },
  
  renderNodes() {
    const self = this;
    
    const node = this.nodeGroup
      .selectAll('g.fsm-node')
      .data(this.nodes, d => d.id)
      .join(
        enter => {
          const g = enter.append('g')
            .attr('class', 'fsm-node')
            .style('cursor', 'pointer')
            .call(this.drag());
          
          g.append('circle')
            .attr('class', 'pulse-ring')
            .attr('r', 35)
            .attr('fill', 'none')
            .attr('stroke', d => d.color)
            .attr('stroke-width', 2)
            .attr('opacity', 0)
            .each(function(d) {
              if (d.active && !self.reducedMotion) {
                d3.select(this)
                  .transition()
                  .duration(1500)
                  .ease(d3.easeLinear)
                  .attr('r', 50)
                  .attr('opacity', 0)
                  .on('end', function repeat() {
                    d3.select(this)
                      .attr('r', 35)
                      .attr('opacity', 0.8)
                      .transition()
                      .duration(1500)
                      .ease(d3.easeLinear)
                      .attr('r', 50)
                      .attr('opacity', 0)
                      .on('end', repeat);
                  });
              }
            });
          
          g.append('circle')
            .attr('class', 'node-circle')
            .attr('r', 30)
            .attr('fill', '#0f172a')
            .attr('stroke', d => d.color)
            .attr('stroke-width', 3)
            .attr('filter', 'url(#node-glow)');
          
          g.append('text')
            .attr('class', 'node-icon')
            .attr('text-anchor', 'middle')
            .attr('dy', 5)
            .attr('font-size', '20px')
            .text(d => d.icon);
          
          g.append('text')
            .attr('class', 'node-label')
            .attr('text-anchor', 'middle')
            .attr('dy', 50)
            .attr('font-size', '12px')
            .attr('font-weight', 'bold')
            .attr('fill', '#94a3b8')
            .attr('text-transform', 'uppercase')
            .attr('letter-spacing', '1px')
            .text(d => d.name);
          
          const badge = g.append('g')
            .attr('class', 'count-badge')
            .attr('transform', 'translate(20, -20)');
          
          badge.append('circle')
            .attr('r', 12)
            .attr('fill', '#1e293b')
            .attr('stroke', '#334155')
            .attr('stroke-width', 1.5);
          
          badge.append('text')
            .attr('text-anchor', 'middle')
            .attr('dy', 4)
            .attr('font-size', '10px')
            .attr('font-weight', 'bold')
            .attr('fill', 'white')
            .text(d => d.count);
          
          g.on('click', function(event, d) {
            event.stopPropagation();
            self.handleNodeClick(d);
          });
          
          g.on('mouseenter', function(event, d) {
            self.showNodeTooltip(d, event);
            d3.select(this).select('.node-circle')
              .transition()
              .duration(200)
              .attr('r', 35)
              .attr('filter', 'url(#node-glow-strong)');
          });
          
          g.on('mouseleave', function() {
            self.hideNodeTooltip();
            d3.select(this).select('.node-circle')
              .transition()
              .duration(200)
              .attr('r', 30)
              .attr('filter', 'url(#node-glow)');
          });
          
          return g;
        },
        update => {
          update.select('.node-circle')
            .transition()
            .duration(300)
            .attr('stroke', d => d.color);
          
          update.select('.count-badge text')
            .text(d => d.count);
          
          update.select('.pulse-ring')
            .attr('stroke', d => d.color)
            .attr('opacity', d => d.active ? 0.8 : 0);
          
          return update;
        }
      );
    
    const defs = this.svg.select('defs').empty() ? this.svg.append('defs') : this.svg.select('defs');
    
    if (defs.select('#node-glow').empty()) {
      const glow = defs.append('filter')
        .attr('id', 'node-glow')
        .attr('x', '-50%')
        .attr('y', '-50%')
        .attr('width', '200%')
        .attr('height', '200%');
      
      glow.append('feGaussianBlur')
        .attr('in', 'SourceGraphic')
        .attr('stdDeviation', 3);
      
      const glowMerge = glow.append('feMerge');
      glowMerge.append('feMergeNode');
      glowMerge.append('feMergeNode').attr('in', 'SourceGraphic');
    }
    
    if (defs.select('#node-glow-strong').empty()) {
      const glowStrong = defs.append('filter')
        .attr('id', 'node-glow-strong')
        .attr('x', '-50%')
        .attr('y', '-50%')
        .attr('width', '200%')
        .attr('height', '200%');
      
      glowStrong.append('feGaussianBlur')
        .attr('in', 'SourceGraphic')
        .attr('stdDeviation', 5);
      
      const glowMerge = glowStrong.append('feMerge');
      glowMerge.append('feMergeNode');
      glowMerge.append('feMergeNode').attr('in', 'SourceGraphic');
    }
  },
  
  ticked() {
    this.linkGroup.selectAll('g.fsm-link').each(function(d) {
      const g = d3.select(this);
      const path = `M${d.source.x},${d.source.y} L${d.target.x},${d.target.y}`;
      
      g.select('.link-shadow').attr('d', path);
      g.select('.link-path').attr('d', path);
      
      const midX = (d.source.x + d.target.x) / 2;
      const midY = (d.source.y + d.target.y) / 2;
      g.select('.link-label')
        .attr('x', midX)
        .attr('y', midY);
    });
    
    this.nodeGroup.selectAll('g.fsm-node')
      .attr('transform', d => `translate(${d.x},${d.y})`);
  },
  
  drag() {
    const simulation = this.simulation;
    
    function dragstarted(event, d) {
      if (!event.active) simulation.alphaTarget(0.3).restart();
      d.fx = d.x;
      d.fy = d.y;
    }
    
    function dragged(event, d) {
      d.fx = event.x;
      d.fy = event.y;
    }
    
    function dragended(event, d) {
      if (!event.active) simulation.alphaTarget(0);
      d.fx = null;
      d.fy = null;
    }
    
    return d3.drag()
      .on('start', dragstarted)
      .on('drag', dragged)
      .on('end', dragended);
  },
  
  handleStateChange(data) {
    const node = this.nodes.find(n => n.id === data.state);
    if (node) {
      this.nodes.forEach(n => n.active = false);
      
      node.active = true;
      node.count = (node.count || 0) + 1;
      
      this.renderNodes();
    }
  },
  
  handleTransition(data) {
    const { from, to, machine_id, success } = data;
    
    const link = this.links.find(l => 
      (l.source.id === from || l.source === from) && 
      (l.target.id === to || l.target === to)
    );
    
    if (link) {
      link.active = true;
      link.count = (link.count || 0) + 1;
      
      if (!this.reducedMotion) {
        this.spawnParticleTrail(link, success);
      }
      
      this.renderLinks();
      
      setTimeout(() => {
        link.active = false;
        this.renderLinks();
      }, 2000);
    }
    
    this.transitionHistory.push({
      from,
      to,
      machine_id,
      success,
      timestamp: Date.now()
    });
    
    this.updateTimeline();
  },
  
  spawnParticleTrail(link, success) {
    const sourceX = link.source.x;
    const sourceY = link.source.y;
    const targetX = link.target.x;
    const targetY = link.target.y;
    
    for (let i = 0; i < 5; i++) {
      const particle = this.particleGroup
        .append('circle')
        .attr('class', 'transition-particle')
        .attr('r', 4)
        .attr('fill', success ? '#10b981' : '#f43f5e')
        .attr('opacity', 0.8)
        .attr('filter', 'drop-shadow(0 0 4px currentColor)');
      
      particle
        .attr('cx', sourceX)
        .attr('cy', sourceY)
        .transition()
        .delay(i * 100)
        .duration(1000)
        .ease(d3.easeCubicInOut)
        .attr('cx', targetX)
        .attr('cy', targetY)
        .attr('opacity', 0)
        .remove();
    }
  },
  
  handleNodeClick(node) {
    console.log('[FsmVisualizer] Node clicked:', node);
    
    this.showInspectionPanel(node);
    
    this.links.forEach(link => {
      if (link.source.id === node.id || link.target.id === node.id) {
        link.highlighted = true;
      } else {
        link.highlighted = false;
      }
    });
    
    this.renderLinks();
  },
  
  showNodeTooltip(node, event) {
    let tooltip = document.querySelector('.fsm-tooltip');
    if (!tooltip) {
      tooltip = document.createElement('div');
      tooltip.className = 'fsm-tooltip rich-tooltip';
      document.body.appendChild(tooltip);
    }
    
    tooltip.innerHTML = `
      <div class="rich-tooltip-header">
        <div class="rich-tooltip-status" style="background: ${node.color}"></div>
        <div class="rich-tooltip-title">${node.name}</div>
      </div>
      <div class="rich-tooltip-row">
        <span class="rich-tooltip-label">Active Instances:</span>
        <span class="rich-tooltip-value">${node.count}</span>
      </div>
      <div class="rich-tooltip-row">
        <span class="rich-tooltip-label">Color:</span>
        <span class="rich-tooltip-value" style="color: ${node.color}">${node.color}</span>
      </div>
    `;
    
    tooltip.classList.add('visible');
    
    const tooltipWidth = 280;
    const padding = 10;
    const left = Math.min(event.pageX + padding, window.innerWidth - tooltipWidth - padding);
    const top = event.pageY + padding;
    
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;
  },
  
  hideNodeTooltip() {
    const tooltip = document.querySelector('.fsm-tooltip');
    if (tooltip) {
      tooltip.classList.remove('visible');
    }
  },
  
  showInspectionPanel(node) {
    let panel = document.querySelector('.fsm-inspection-panel');
    if (!panel) {
      panel = document.createElement('div');
      panel.className = 'fsm-inspection-panel glass-dark';
      this.el.parentElement.appendChild(panel);
    }
    
    const incomingLinks = this.links.filter(l => l.target.id === node.id);
    const outgoingLinks = this.links.filter(l => l.source.id === node.id);
    
    panel.innerHTML = `
      <div class="inspection-header">
        <h4>${node.icon} ${node.name}</h4>
        <button class="close-btn" onclick="this.parentElement.parentElement.remove()">✕</button>
      </div>
      <div class="inspection-content">
        <div class="inspection-stat">
          <div class="stat-label">Active Instances</div>
          <div class="stat-value">${node.count}</div>
        </div>
        <div class="inspection-section">
          <div class="section-title">Incoming Transitions (${incomingLinks.length})</div>
          ${incomingLinks.map(l => `
            <div class="transition-item">
              <span>${l.source.name || l.source} → ${node.name}</span>
              <span class="transition-count">${l.count || 0}</span>
            </div>
          `).join('')}
        </div>
        <div class="inspection-section">
          <div class="section-title">Outgoing Transitions (${outgoingLinks.length})</div>
          ${outgoingLinks.map(l => `
            <div class="transition-item">
              <span>${node.name} → ${l.target.name || l.target}</span>
              <span class="transition-count">${l.count || 0}</span>
            </div>
          `).join('')}
        </div>
      </div>
    `;
    
    panel.style.display = 'block';
  },
  
  setupPlaybackControls() {
    let controls = document.querySelector('.fsm-playback-controls');
    if (!controls) return;
    
    const playBtn = controls.querySelector('[data-action="play"]');
    const pauseBtn = controls.querySelector('[data-action="pause"]');
    const stepBtn = controls.querySelector('[data-action="step"]');
    const resetBtn = controls.querySelector('[data-action="reset"]');
    
    if (playBtn) {
      playBtn.addEventListener('click', () => this.play());
    }
    if (pauseBtn) {
      pauseBtn.addEventListener('click', () => this.pause());
    }
    if (stepBtn) {
      stepBtn.addEventListener('click', () => this.step());
    }
    if (resetBtn) {
      resetBtn.addEventListener('click', () => this.reset());
    }
  },
  
  play() {
    if (this.isPlaying) return;
    
    this.isPlaying = true;
    this.playbackTimer = setInterval(() => {
      this.step();
      
      if (this.currentStateIndex >= this.transitionHistory.length - 1) {
        this.pause();
      }
    }, 1000);
  },
  
  pause() {
    this.isPlaying = false;
    if (this.playbackTimer) {
      clearInterval(this.playbackTimer);
      this.playbackTimer = null;
    }
  },
  
  step() {
    if (this.currentStateIndex < this.transitionHistory.length - 1) {
      this.currentStateIndex++;
      const transition = this.transitionHistory[this.currentStateIndex];
      this.handleTransition(transition);
    }
  },
  
  reset() {
    this.pause();
    this.currentStateIndex = -1;
    
    this.nodes.forEach(n => n.active = false);
    this.links.forEach(l => l.active = false);
    
    this.render();
  },
  
  updateTimeline() {
    const timeline = document.querySelector('.fsm-timeline');
    if (!timeline) return;
    
    const latest = this.transitionHistory[this.transitionHistory.length - 1];
    if (!latest) return;
    
    const item = document.createElement('div');
    item.className = `timeline-item ${latest.success ? 'success' : 'failed'}`;
    item.innerHTML = `
      <div class="timeline-dot"></div>
      <div class="timeline-content">
        <div class="timeline-states">${latest.from} → ${latest.to}</div>
        <div class="timeline-machine">${latest.machine_id}</div>
      </div>
    `;
    
    timeline.insertBefore(item, timeline.firstChild);
    
    while (timeline.children.length > 10) {
      timeline.removeChild(timeline.lastChild);
    }
  },
  
  getStateColor(stateName) {
    const colors = {
      created: '#8b5cf6',
      running: '#10b981',
      migrating: '#06b6d4',
      stopped: '#64748b',
      error: '#f43f5e'
    };
    return colors[stateName.toLowerCase()] || '#94a3b8';
  },
  
  getStateIcon(stateName) {
    const icons = {
      created: '✨',
      running: '⚡',
      migrating: '🚀',
      stopped: '🛑',
      error: '🔥'
    };
    return icons[stateName.toLowerCase()] || '❓';
  }
};

export default FsmVisualizerHook;
