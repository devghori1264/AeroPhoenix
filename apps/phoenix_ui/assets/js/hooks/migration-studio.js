import * as d3 from "d3";

const MigrationStudioHook = {
  mounted() {
    console.log('[MigrationStudio] Initializing cinematic migration visualization...');
    
    this.migrations = new Map();
    this.bandwidthChart = null;
    this.checkpointTimeline = null;
    this.reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    
    this.initializeMigrations();
    
    this.handleEvent("migration:update", (migration) => {
      console.log('[MigrationStudio] Migration update:', migration);
      this.updateMigration(migration);
    });
    
    this.handleEvent("migration:complete", (migration) => {
      console.log('[MigrationStudio] Migration complete:', migration);
      this.celebrateCompletion(migration);
    });
    
    console.log('[MigrationStudio] Initialized successfully');
  },
  
  destroyed() {
    console.log('[MigrationStudio] Cleaning up...');
    this.migrations.clear();
  },
  
  initializeMigrations() {
    const cards = this.el.querySelectorAll('[data-migration-id]');
    
    cards.forEach(card => {
      const migrationId = card.dataset.migrationId;
      const progress = parseInt(card.dataset.migrationProgress || 0);
      const status = card.dataset.migrationStatus || 'initializing';
      
      console.log(`[MigrationStudio] Initializing migration ${migrationId}`);
      
      this.createCinematicProgress(card, migrationId, progress);
      
      this.createBandwidthGraph(card, migrationId);
      
      this.createCheckpointTimeline(card, migrationId, progress);
      
      if (progress >= 75 && status !== 'completed') {
        this.startCutoverCountdown(card, migrationId);
      }
      
      this.migrations.set(migrationId, {
        card,
        progress,
        status,
        startTime: Date.now(),
        bandwidthData: []
      });
    });
  },
  
  createCinematicProgress(card, migrationId, initialProgress) {
    const progressContainer = card.querySelector('.migration-cinematic-progress');
    if (!progressContainer) {
      console.warn('[MigrationStudio] No progress container found');
      return;
    }
    
    const width = progressContainer.clientWidth;
    const height = 80;
    
    const svg = d3.select(progressContainer)
      .html('')
      .append('svg')
      .attr('width', width)
      .attr('height', height)
      .attr('class', 'migration-progress-svg');
    
    const defs = svg.append('defs');
    
    const progressGradient = defs.append('linearGradient')
      .attr('id', `progress-gradient-${migrationId}`)
      .attr('x1', '0%')
      .attr('y1', '0%')
      .attr('x2', '100%')
      .attr('y2', '0%');
    
    progressGradient.append('stop')
      .attr('offset', '0%')
      .attr('style', 'stop-color:#06b6d4;stop-opacity:1');
    
    progressGradient.append('stop')
      .attr('offset', '50%')
      .attr('style', 'stop-color:#8b5cf6;stop-opacity:1');
    
    progressGradient.append('stop')
      .attr('offset', '100%')
      .attr('style', 'stop-color:#ec4899;stop-opacity:1');
    
    svg.append('rect')
      .attr('x', 0)
      .attr('y', 30)
      .attr('width', width)
      .attr('height', 20)
      .attr('rx', 10)
      .attr('fill', 'rgba(15, 23, 42, 0.8)')
      .attr('stroke', 'rgba(139, 92, 246, 0.3)')
      .attr('stroke-width', 1);
    
    const checkpoints = [
      { position: 0.25, label: 'Init', phase: 'initialize' },
      { position: 0.50, label: 'Sync', phase: 'sync' },
      { position: 0.75, label: 'Cutover', phase: 'cutover' },
      { position: 1.00, label: 'Done', phase: 'finalize' }
    ];
    
    checkpoints.forEach(checkpoint => {
      const x = checkpoint.position * width;
      
      svg.append('line')
        .attr('x1', x)
        .attr('y1', 28)
        .attr('x2', x)
        .attr('y2', 52)
        .attr('stroke', 'rgba(71, 85, 105, 0.5)')
        .attr('stroke-width', 2)
        .attr('stroke-dasharray', '3,3');
      
      svg.append('circle')
        .attr('cx', x)
        .attr('cy', 40)
        .attr('r', 4)
        .attr('fill', 'rgba(100, 116, 139, 0.5)')
        .attr('class', `checkpoint-${checkpoint.phase}`);
      
      svg.append('text')
        .attr('x', x)
        .attr('y', 15)
        .attr('text-anchor', 'middle')
        .attr('fill', 'rgba(148, 163, 184, 0.8)')
        .attr('font-size', '11px')
        .attr('font-weight', '600')
        .text(checkpoint.label);
    });
    
    const progressBar = svg.append('rect')
      .attr('x', 0)
      .attr('y', 30)
      .attr('width', 0)
      .attr('height', 20)
      .attr('rx', 10)
      .attr('fill', `url(#progress-gradient-${migrationId})`)
      .attr('class', 'migration-progress-bar');
    
    const shimmer = svg.append('rect')
      .attr('x', -100)
      .attr('y', 30)
      .attr('width', 100)
      .attr('height', 20)
      .attr('rx', 10)
      .attr('fill', 'rgba(255, 255, 255, 0.3)')
      .attr('class', 'progress-shimmer');
    
    if (!this.reducedMotion) {
      const animateShimmer = () => {
        shimmer
          .transition()
          .duration(1500)
          .ease(d3.easeLinear)
          .attr('x', width)
          .on('end', () => {
            shimmer.attr('x', -100);
            animateShimmer();
          });
      };
      animateShimmer();
    }
    
    if (!this.reducedMotion) {
      progressBar
        .transition()
        .duration(1000)
        .ease(d3.easeCubicOut)
        .attr('width', (initialProgress / 100) * width);
    } else {
      progressBar.attr('width', (initialProgress / 100) * width);
    }
    
    checkpoints.forEach(checkpoint => {
      if (initialProgress >= checkpoint.position * 100) {
        svg.select(`.checkpoint-${checkpoint.phase}`)
          .attr('fill', '#10b981')
          .attr('r', 6)
          .attr('filter', 'drop-shadow(0 0 8px #10b981)');
      }
    });
    
    this.migrations.set(migrationId, {
      ...this.migrations.get(migrationId),
      progressBar,
      checkpoints,
      svg
    });
  },
  
  createBandwidthGraph(card, migrationId) {
    const graphContainer = card.querySelector('.migration-bandwidth-graph');
    if (!graphContainer) return;
    
    const width = graphContainer.clientWidth;
    const height = 120;
    const margin = { top: 10, right: 10, bottom: 20, left: 40 };
    
    const svg = d3.select(graphContainer)
      .html('')
      .append('svg')
      .attr('width', width)
      .attr('height', height);
    
    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);
    
    const xScale = d3.scaleLinear()
      .domain([0, 60])
      .range([0, width - margin.left - margin.right]);
    
    const yScale = d3.scaleLinear()
      .domain([0, 100])
      .range([height - margin.top - margin.bottom, 0]);
    
    g.append('g')
      .attr('class', 'grid')
      .attr('opacity', 0.1)
      .call(d3.axisLeft(yScale)
        .tickSize(-(width - margin.left - margin.right))
        .tickFormat(''));
    
    g.append('g')
      .attr('transform', `translate(0,${height - margin.top - margin.bottom})`)
      .call(d3.axisBottom(xScale).ticks(6))
      .attr('color', '#64748b')
      .attr('font-size', '10px');
    
    g.append('g')
      .call(d3.axisLeft(yScale).ticks(5))
      .attr('color', '#64748b')
      .attr('font-size', '10px');
    
    const area = d3.area()
      .x(d => xScale(d.time))
      .y0(height - margin.top - margin.bottom)
      .y1(d => yScale(d.bandwidth))
      .curve(d3.curveBasis);
    
    const areaPath = g.append('path')
      .attr('class', 'bandwidth-area')
      .attr('fill', 'url(#bandwidth-gradient)')
      .attr('opacity', 0.3);
    
    const line = d3.line()
      .x(d => xScale(d.time))
      .y(d => yScale(d.bandwidth))
      .curve(d3.curveBasis);
    
    const linePath = g.append('path')
      .attr('class', 'bandwidth-line')
      .attr('fill', 'none')
      .attr('stroke', '#06b6d4')
      .attr('stroke-width', 2);
    
    const gradient = svg.append('defs')
      .append('linearGradient')
      .attr('id', 'bandwidth-gradient')
      .attr('x1', '0%')
      .attr('y1', '0%')
      .attr('x2', '0%')
      .attr('y2', '100%');
    
    gradient.append('stop')
      .attr('offset', '0%')
      .attr('style', 'stop-color:#06b6d4;stop-opacity:0.8');
    
    gradient.append('stop')
      .attr('offset', '100%')
      .attr('style', 'stop-color:#06b6d4;stop-opacity:0.1');
    
    const migration = this.migrations.get(migrationId) || {};
    this.migrations.set(migrationId, {
      ...migration,
      bandwidthChart: { svg, areaPath, linePath, xScale, yScale, area, line },
      bandwidthData: []
    });
  },
  
  createCheckpointTimeline(card, migrationId, progress) {
    const timelineContainer = card.querySelector('.migration-checkpoint-timeline');
    if (!timelineContainer) return;
    
    const checkpoints = [
      { name: 'Started', time: '0:00', complete: true },
      { name: 'Base Sync', time: '0:45', complete: progress >= 25 },
      { name: 'Delta Sync', time: '1:30', complete: progress >= 50 },
      { name: 'Cutover', time: '2:15', complete: progress >= 75 },
      { name: 'Finalized', time: '2:20', complete: progress >= 100 }
    ];
    
    const html = `
      <div class="checkpoint-timeline-container">
        ${checkpoints.map((cp, i) => `
          <div class="checkpoint-item ${cp.complete ? 'complete' : 'pending'}" data-checkpoint="${i}">
            <div class="checkpoint-dot ${cp.complete ? 'animate-pulse-glow' : ''}"></div>
            ${i < checkpoints.length - 1 ? '<div class="checkpoint-connector"></div>' : ''}
            <div class="checkpoint-info">
              <div class="checkpoint-name">${cp.name}</div>
              <div class="checkpoint-time">${cp.time}</div>
            </div>
          </div>
        `).join('')}
      </div>
    `;
    
    timelineContainer.innerHTML = html;
  },
  
  startCutoverCountdown(card, migrationId) {
    const countdownContainer = card.querySelector('.migration-countdown');
    if (!countdownContainer) return;
    
    let countdown = 10;
    
    countdownContainer.innerHTML = `
      <div class="cutover-countdown glass-dark">
        <div class="countdown-label">CUTOVER IN</div>
        <div class="countdown-value" data-countdown="${countdown}">${countdown}s</div>
        <div class="countdown-pulse"></div>
      </div>
    `;
    
    const countdownValue = countdownContainer.querySelector('.countdown-value');
    const countdownPulse = countdownContainer.querySelector('.countdown-pulse');
    
    const timer = setInterval(() => {
      countdown--;
      countdownValue.textContent = `${countdown}s`;
      countdownValue.setAttribute('data-countdown', countdown);
      
      if (countdown <= 3) {
        countdownValue.style.color = '#ef4444';
        countdownValue.style.fontSize = '3rem';
        countdownPulse.style.animation = 'pulse-glow 0.5s ease-in-out infinite';
      }
      
      if (countdown <= 0) {
        clearInterval(timer);
        this.executeCutover(card, migrationId);
      }
    }, 1000);
    
    const migration = this.migrations.get(migrationId) || {};
    this.migrations.set(migrationId, { ...migration, countdownTimer: timer });
  },
  
  executeCutover(card, migrationId) {
    console.log(`[MigrationStudio] Executing cutover for ${migrationId}`);
    
    const countdownContainer = card.querySelector('.migration-countdown');
    if (countdownContainer) {
      countdownContainer.innerHTML = `
        <div class="cutover-executing glass-dark animate-pulse-glow">
          <div class="text-2xl font-bold text-emerald-400">CUTOVER EXECUTING</div>
          <div class="text-sm text-slate-400">Switching traffic...</div>
        </div>
      `;
    }
    
    setTimeout(() => {
      this.updateMigration({ id: migrationId, progress: 100, status: 'completed' });
    }, 2000);
  },
  
  updateMigration(migration) {
    const stored = this.migrations.get(migration.id);
    if (!stored) return;
    
    const { progressBar, svg, checkpoints, bandwidthChart, bandwidthData } = stored;
    
    if (progressBar) {
      const width = svg.attr('width');
      progressBar
        .transition()
        .duration(500)
        .ease(d3.easeCubicOut)
        .attr('width', (migration.progress / 100) * width);
      
      checkpoints.forEach(checkpoint => {
        if (migration.progress >= checkpoint.position * 100) {
          svg.select(`.checkpoint-${checkpoint.phase}`)
            .transition()
            .duration(300)
            .attr('fill', '#10b981')
            .attr('r', 6)
            .attr('filter', 'drop-shadow(0 0 8px #10b981)');
        }
      });
    }
    
    if (bandwidthChart && migration.network_speed) {
      const now = (Date.now() - stored.startTime) / 1000;
      bandwidthData.push({ time: now, bandwidth: migration.network_speed });
      
      while (bandwidthData.length > 0 && bandwidthData[0].time < now - 60) {
        bandwidthData.shift();
      }
      
      bandwidthChart.areaPath
        .datum(bandwidthData)
        .transition()
        .duration(100)
        .attr('d', bandwidthChart.area);
      
      bandwidthChart.linePath
        .datum(bandwidthData)
        .transition()
        .duration(100)
        .attr('d', bandwidthChart.line);
    }
    
    this.migrations.set(migration.id, {
      ...stored,
      progress: migration.progress,
      status: migration.status,
      bandwidthData
    });
  },
  
  celebrateCompletion(migration) {
    console.log(`[MigrationStudio] Celebrating completion of ${migration.id}!`);
    
    const stored = this.migrations.get(migration.id);
    if (!stored || !stored.card) return;
    
    const overlay = document.createElement('div');
    overlay.className = 'migration-success-overlay';
    overlay.innerHTML = `
      <div class="success-content glass animate-scale-in">
        <div class="success-icon">✨</div>
        <div class="success-title">Migration Complete!</div>
        <div class="success-stats">
          <div class="stat">
            <div class="stat-value">${migration.duration || '2m 20s'}</div>
            <div class="stat-label">Duration</div>
          </div>
          <div class="stat">
            <div class="stat-value">${migration.cutover_time || '45ms'}</div>
            <div class="stat-label">Cutover</div>
          </div>
          <div class="stat">
            <div class="stat-value">${migration.total_bytes || '1.2GB'}</div>
            <div class="stat-label">Transferred</div>
          </div>
        </div>
      </div>
    `;
    
    stored.card.style.position = 'relative';
    stored.card.appendChild(overlay);
    
    if (!this.reducedMotion) {
      this.createConfetti(stored.card);
    }
    
    setTimeout(() => {
      overlay.style.opacity = '0';
      setTimeout(() => overlay.remove(), 500);
    }, 5000);
  },
  
  createConfetti(container) {
    const confettiCount = 50;
    const colors = ['#06b6d4', '#8b5cf6', '#ec4899', '#10b981', '#f59e0b'];
    
    for (let i = 0; i < confettiCount; i++) {
      const confetti = document.createElement('div');
      confetti.className = 'confetti-particle';
      confetti.style.left = `${Math.random() * 100}%`;
      confetti.style.backgroundColor = colors[Math.floor(Math.random() * colors.length)];
      confetti.style.animationDelay = `${Math.random() * 0.5}s`;
      confetti.style.animationDuration = `${2 + Math.random() * 2}s`;
      container.appendChild(confetti);
      
      setTimeout(() => confetti.remove(), 4000);
    }
  }
};

export default MigrationStudioHook;
