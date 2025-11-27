import * as d3 from 'd3';

export const OptimizerDashboardHook = {
  mounted() {
    console.log('[OptimizerDashboard] Mounted');
    
    this.recommendations = [];
    this.history = [];
    this.stats = {
      totalSavings: 0,
      acceptedCount: 0,
      rejectedCount: 0,
      pendingCount: 0
    };
    
    this.initializeCards();
    this.initializeTimeline();
    this.setupEventHandlers();
    this.startAnimations();
  },
  
  initializeCards() {
    this.cardsContainer = this.el.querySelector('#recommendations-container');
    if (!this.cardsContainer) return;
    
    this.renderCards();
  },
  
  renderCards(recommendations = this.recommendations) {
    if (!this.cardsContainer) return;
    
    this.cardsContainer.innerHTML = '';
    
    if (recommendations.length === 0) {
      this.showEmptyState();
      return;
    }
    
    recommendations.forEach((rec, index) => {
      const card = this.createRecommendationCard(rec, index);
      this.cardsContainer.appendChild(card);
    });
    
    this.updateStats();
  },
  
  createRecommendationCard(rec, index) {
    const card = document.createElement('div');
    card.className = `recommendation-card priority-${rec.priority} status-${rec.status}`;
    card.dataset.id = rec.id;
    card.style.animationDelay = `${index * 100}ms`;
    
    const priorityColor = this.getPriorityColor(rec.priority);
    const priorityIcon = this.getPriorityIcon(rec.priority);
    const categoryIcon = this.getCategoryIcon(rec.category);
    
    card.innerHTML = `
      <div class="card-header">
        <div class="card-badges">
          <span class="priority-badge" style="background: ${priorityColor}20; color: ${priorityColor}">
            ${priorityIcon} ${rec.priority.toUpperCase()}
          </span>
          <span class="category-badge">${categoryIcon} ${rec.category}</span>
        </div>
        <div class="card-score">
          <div class="score-circle" style="--score: ${rec.score}">
            <span class="score-value">${rec.score}</span>
          </div>
        </div>
      </div>
      
      <div class="card-content">
        <h3 class="card-title">${rec.title}</h3>
        <p class="card-description">${rec.description}</p>
        
        <div class="impact-section">
          <div class="impact-header">
            <span class="impact-label">💡 Estimated Impact</span>
          </div>
          <div class="impact-metrics">
            ${this.renderImpactMetrics(rec.impact)}
          </div>
        </div>
        
        <div class="comparison-chart" id="comparison-${rec.id}"></div>
      </div>
      
      <div class="card-actions">
        ${rec.status === 'pending' ? `
          <button class="action-btn accept-btn" data-id="${rec.id}">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
            </svg>
            Accept
          </button>
          <button class="action-btn reject-btn" data-id="${rec.id}">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
            </svg>
            Reject
          </button>
          <button class="action-btn details-btn" data-id="${rec.id}">
            Details
          </button>
        ` : `
          <div class="status-badge status-${rec.status}">
            ${rec.status === 'accepted' ? '✓ Accepted' : '✗ Rejected'}
          </div>
          <span class="status-time">${this.formatTime(rec.decidedAt)}</span>
        `}
      </div>
    `;
    
    const acceptBtn = card.querySelector('.accept-btn');
    const rejectBtn = card.querySelector('.reject-btn');
    const detailsBtn = card.querySelector('.details-btn');
    
    if (acceptBtn) {
      acceptBtn.addEventListener('click', () => this.acceptRecommendation(rec.id));
    }
    if (rejectBtn) {
      rejectBtn.addEventListener('click', () => this.rejectRecommendation(rec.id));
    }
    if (detailsBtn) {
      detailsBtn.addEventListener('click', () => this.showDetails(rec.id));
    }
    
    setTimeout(() => {
      this.renderComparisonChart(rec);
    }, 100);
    
    return card;
  },
  
  renderImpactMetrics(impact) {
    const metrics = [];
    
    if (impact.cost_savings) {
      metrics.push(`
        <div class="impact-metric">
          <span class="metric-icon">💰</span>
          <span class="metric-value">$${impact.cost_savings.toFixed(2)}/mo</span>
          <span class="metric-label">Cost Savings</span>
        </div>
      `);
    }
    
    if (impact.performance_gain) {
      metrics.push(`
        <div class="impact-metric">
          <span class="metric-icon">⚡</span>
          <span class="metric-value">+${impact.performance_gain}%</span>
          <span class="metric-label">Performance</span>
        </div>
      `);
    }
    
    if (impact.latency_reduction) {
      metrics.push(`
        <div class="impact-metric">
          <span class="metric-icon">⏱️</span>
          <span class="metric-value">-${impact.latency_reduction}ms</span>
          <span class="metric-label">Latency</span>
        </div>
      `);
    }
    
    if (impact.resource_savings) {
      metrics.push(`
        <div class="impact-metric">
          <span class="metric-icon">📊</span>
          <span class="metric-value">-${impact.resource_savings}%</span>
          <span class="metric-label">Resources</span>
        </div>
      `);
    }
    
    return metrics.join('');
  },
  
  renderComparisonChart(rec) {
    const container = document.getElementById(`comparison-${rec.id}`);
    if (!container) return;
    
    const width = container.clientWidth;
    const height = 120;
    
    const svg = d3.select(container)
      .append('svg')
      .attr('width', width)
      .attr('height', height);
    
    const data = [
      { label: 'Before', value: 100, color: '#ef4444' },
      { label: 'After', value: 100 - (rec.impact.resource_savings || rec.impact.performance_gain || 20), color: '#10b981' }
    ];
    
    const x = d3.scaleBand()
      .domain(data.map(d => d.label))
      .range([0, width])
      .padding(0.3);
    
    const y = d3.scaleLinear()
      .domain([0, 100])
      .range([height - 20, 10]);
    
    svg.selectAll('.bar')
      .data(data)
      .enter()
      .append('rect')
      .attr('class', 'comparison-bar')
      .attr('x', d => x(d.label))
      .attr('y', height - 20)
      .attr('width', x.bandwidth())
      .attr('height', 0)
      .attr('rx', 6)
      .attr('fill', d => d.color)
      .attr('opacity', 0.8)
      .transition()
      .duration(1000)
      .delay((d, i) => i * 200)
      .attr('y', d => y(d.value))
      .attr('height', d => height - 20 - y(d.value));
    
    svg.selectAll('.bar-label')
      .data(data)
      .enter()
      .append('text')
      .attr('class', 'comparison-label')
      .attr('x', d => x(d.label) + x.bandwidth() / 2)
      .attr('y', d => y(d.value) - 5)
      .attr('text-anchor', 'middle')
      .attr('fill', '#f3f4f6')
      .attr('font-size', '14px')
      .attr('font-weight', '700')
      .attr('opacity', 0)
      .text(d => `${d.value.toFixed(0)}%`)
      .transition()
      .duration(500)
      .delay((d, i) => i * 200 + 1000)
      .attr('opacity', 1);
    
    svg.selectAll('.axis-label')
      .data(data)
      .enter()
      .append('text')
      .attr('class', 'comparison-axis-label')
      .attr('x', d => x(d.label) + x.bandwidth() / 2)
      .attr('y', height - 5)
      .attr('text-anchor', 'middle')
      .attr('fill', '#9ca3af')
      .attr('font-size', '12px')
      .attr('font-weight', '600')
      .text(d => d.label);
    
    if (data.length === 2) {
      const arrowX = x(data[0].label) + x.bandwidth() + (x(data[1].label) - x(data[0].label) - x.bandwidth()) / 2;
      svg.append('text')
        .attr('x', arrowX)
        .attr('y', height / 2)
        .attr('text-anchor', 'middle')
        .attr('font-size', '24px')
        .attr('opacity', 0)
        .text('→')
        .transition()
        .duration(500)
        .delay(1500)
        .attr('opacity', 0.6);
    }
  },
  
  initializeTimeline() {
    this.timelineContainer = this.el.querySelector('#optimization-timeline');
    if (!this.timelineContainer) return;
    
    this.renderTimeline();
  },
  
  renderTimeline(history = this.history) {
    if (!this.timelineContainer) return;
    
    this.timelineContainer.innerHTML = '';
    
    if (history.length === 0) {
      this.timelineContainer.innerHTML = '<div class="empty-timeline">No optimization history yet</div>';
      return;
    }
    
    history.forEach((item, index) => {
      const timelineItem = document.createElement('div');
      timelineItem.className = `timeline-item timeline-${item.status}`;
      timelineItem.style.animationDelay = `${index * 50}ms`;
      
      const icon = item.status === 'accepted' ? '✓' : '✗';
      const statusColor = item.status === 'accepted' ? '#10b981' : '#ef4444';
      
      timelineItem.innerHTML = `
        <div class="timeline-dot" style="background: ${statusColor}"></div>
        <div class="timeline-content">
          <div class="timeline-header">
            <span class="timeline-title">${item.title}</span>
            <span class="timeline-time">${this.formatTime(item.timestamp)}</span>
          </div>
          <div class="timeline-details">
            <span class="timeline-icon">${icon}</span>
            <span class="timeline-status">${item.status}</span>
            ${item.savings ? `<span class="timeline-savings">💰 $${item.savings.toFixed(2)}/mo</span>` : ''}
          </div>
        </div>
      `;
      
      this.timelineContainer.appendChild(timelineItem);
    });
  },
  
  setupEventHandlers() {
    this.handleEvent('new_recommendation', (data) => {
      this.addRecommendation(data);
    });
    
    this.handleEvent('recommendations_batch', (data) => {
      this.recommendations = data.recommendations || [];
      this.renderCards();
    });
    
    this.handleEvent('history_update', (data) => {
      this.history = data.history || [];
      this.renderTimeline();
    });
  },
  
  addRecommendation(rec) {
    this.recommendations.unshift(rec);
    this.renderCards();
    
    this.showNotification(`New ${rec.priority} priority recommendation: ${rec.title}`);
  },
  
  acceptRecommendation(id) {
    const card = this.cardsContainer.querySelector(`[data-id="${id}"]`);
    if (!card) return;
    
    card.classList.add('accepting');
    
    setTimeout(() => {
      this.spawnConfetti(card);
      
      const rec = this.recommendations.find(r => r.id === id);
      if (rec) {
        rec.status = 'accepted';
        rec.decidedAt = new Date().toISOString();
        
        this.history.unshift({
          ...rec,
          status: 'accepted',
          timestamp: new Date().toISOString()
        });
        
        this.stats.acceptedCount++;
        this.stats.pendingCount--;
        this.stats.totalSavings += rec.impact.cost_savings || 0;
        
        this.renderTimeline();
        this.updateStats();
      }
      
      this.pushEvent('accept_recommendation', { id });
      
      setTimeout(() => {
        card.classList.remove('accepting');
        this.renderCards();
      }, 1500);
    }, 300);
  },
  
  rejectRecommendation(id) {
    const card = this.cardsContainer.querySelector(`[data-id="${id}"]`);
    if (!card) return;
    
    card.classList.add('rejecting');
    
    setTimeout(() => {
      const rec = this.recommendations.find(r => r.id === id);
      if (rec) {
        rec.status = 'rejected';
        rec.decidedAt = new Date().toISOString();
        
        this.history.unshift({
          ...rec,
          status: 'rejected',
          timestamp: new Date().toISOString()
        });
        
        this.stats.rejectedCount++;
        this.stats.pendingCount--;
        
        this.renderTimeline();
        this.updateStats();
      }
      
      this.pushEvent('reject_recommendation', { id });
      
      setTimeout(() => {
        card.classList.remove('rejecting');
        this.renderCards();
      }, 1000);
    }, 300);
  },
  
  showDetails(id) {
    const rec = this.recommendations.find(r => r.id === id);
    if (!rec) return;
    
    this.pushEvent('show_recommendation_details', { recommendation: rec });
  },
  
  spawnConfetti(card) {
    const rect = card.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    
    for (let i = 0; i < 30; i++) {
      const confetti = document.createElement('div');
      confetti.className = 'confetti-particle';
      confetti.style.left = `${centerX}px`;
      confetti.style.top = `${centerY}px`;
      confetti.style.background = this.getRandomColor();
      
      document.body.appendChild(confetti);
      
      const angle = (Math.PI * 2 * i) / 30;
      const velocity = 100 + Math.random() * 100;
      const tx = Math.cos(angle) * velocity;
      const ty = Math.sin(angle) * velocity;
      
      confetti.animate([
        { transform: 'translate(0, 0) scale(1)', opacity: 1 },
        { transform: `translate(${tx}px, ${ty}px) scale(0)`, opacity: 0 }
      ], {
        duration: 1000 + Math.random() * 500,
        easing: 'cubic-bezier(0, .9, .57, 1)'
      }).onfinish = () => confetti.remove();
    }
  },
  
  updateStats() {
    const statsEl = this.el.querySelector('#optimizer-stats');
    if (!statsEl) return;
    
    this.stats.pendingCount = this.recommendations.filter(r => r.status === 'pending').length;
    
    statsEl.innerHTML = `
      <div class="stat-card">
        <div class="stat-icon">💰</div>
        <div class="stat-value">$${this.stats.totalSavings.toFixed(2)}</div>
        <div class="stat-label">Total Savings/mo</div>
      </div>
      <div class="stat-card">
        <div class="stat-icon">✓</div>
        <div class="stat-value">${this.stats.acceptedCount}</div>
        <div class="stat-label">Accepted</div>
      </div>
      <div class="stat-card">
        <div class="stat-icon">⏳</div>
        <div class="stat-value">${this.stats.pendingCount}</div>
        <div class="stat-label">Pending</div>
      </div>
      <div class="stat-card">
        <div class="stat-icon">✗</div>
        <div class="stat-value">${this.stats.rejectedCount}</div>
        <div class="stat-label">Rejected</div>
      </div>
    `;
  },
  
  showEmptyState() {
    this.cardsContainer.innerHTML = `
      <div class="empty-state">
        <div class="empty-icon">🎯</div>
        <h3>No Recommendations</h3>
        <p>The AI optimizer is analyzing your system. Check back soon for optimization suggestions.</p>
      </div>
    `;
  },
  
  startAnimations() {
    setInterval(() => {
      const highPriorityCards = this.cardsContainer.querySelectorAll('.priority-high, .priority-critical');
      highPriorityCards.forEach(card => {
        card.classList.add('pulse-attention');
        setTimeout(() => card.classList.remove('pulse-attention'), 1000);
      });
    }, 5000);
  },
  
  getPriorityColor(priority) {
    const colors = {
      low: '#06b6d4',
      medium: '#fbbf24',
      high: '#f97316',
      critical: '#ef4444'
    };
    return colors[priority] || colors.medium;
  },
  
  getPriorityIcon(priority) {
    const icons = {
      low: '🔵',
      medium: '🟡',
      high: '🟠',
      critical: '🔴'
    };
    return icons[priority] || icons.medium;
  },
  
  getCategoryIcon(category) {
    const icons = {
      performance: '⚡',
      cost: '💰',
      security: '🔒',
      scalability: '📈',
      reliability: '🛡️'
    };
    return icons[category] || '🎯';
  },
  
  getRandomColor() {
    const colors = ['#8b5cf6', '#ec4899', '#10b981', '#fbbf24', '#06b6d4'];
    return colors[Math.floor(Math.random() * colors.length)];
  },
  
  formatTime(timestamp) {
    if (!timestamp) return '';
    const date = new Date(timestamp);
    const now = new Date();
    const diff = now - date;
    
    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
    return `${Math.floor(diff / 86400000)}d ago`;
  },
  
  showNotification(message) {
    this.pushEvent('toast', { type: 'info', message });
  },
  
  destroyed() {
    console.log('[OptimizerDashboard] Destroyed');
  }
};

export default OptimizerDashboardHook;
