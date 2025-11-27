export const FeatureFlagsHook = {
  mounted() {
    console.log('[FeatureFlags] Mounted');
    
    this.flags = [];
    this.initializeFlags();
    this.setupEventHandlers();
  },
  
  initializeFlags() {
    this.container = this.el.querySelector('#flags-container');
    if (!this.container) return;
    
    this.renderFlags();
  },
  
  renderFlags(flags = this.flags) {
    if (!this.container) return;
    
    this.container.innerHTML = '';
    
    flags.forEach((flag, index) => {
      const card = document.createElement('div');
      card.className = `flag-card ${flag.enabled ? 'flag-enabled' : 'flag-disabled'}`;
      card.style.animationDelay = `${index * 50}ms`;
      
      card.innerHTML = `
        <div class="flag-header">
          <div class="flag-info">
            <h4>${flag.name}</h4>
            <p>${flag.description}</p>
          </div>
          <label class="toggle-switch">
            <input type="checkbox" ${flag.enabled ? 'checked' : ''} data-flag-id="${flag.id}">
            <span class="toggle-slider"></span>
          </label>
        </div>
        
        <div class="rollout-section">
          <div class="rollout-label">Rollout: ${flag.rollout}%</div>
          <div class="rollout-bar">
            <div class="rollout-fill" style="width: ${flag.rollout}%"></div>
          </div>
        </div>
        
        <div class="flag-metrics">
          <div class="metric">
            <span class="metric-label">Users Affected</span>
            <span class="metric-value">${flag.users_affected || 0}</span>
          </div>
          <div class="metric">
            <span class="metric-label">Performance Impact</span>
            <span class="metric-value ${flag.performance_impact > 0 ? 'positive' : 'negative'}">
              ${flag.performance_impact > 0 ? '+' : ''}${flag.performance_impact}%
            </span>
          </div>
        </div>
      `;
      
      const toggle = card.querySelector('input[type="checkbox"]');
      toggle.addEventListener('change', (e) => {
        this.toggleFlag(flag.id, e.target.checked);
      });
      
      this.container.appendChild(card);
    });
  },
  
  setupEventHandlers() {
    this.handleEvent('flags_update', (data) => {
      this.flags = data.flags || [];
      this.renderFlags();
    });
    
    this.handleEvent('flag_changed', (data) => {
      const flag = this.flags.find(f => f.id === data.id);
      if (flag) {
        Object.assign(flag, data);
        this.renderFlags();
      }
    });
  },
  
  toggleFlag(id, enabled) {
    this.pushEvent('toggle_flag', { id, enabled });
    
    const card = this.container.querySelector(`input[data-flag-id="${id}"]`).closest('.flag-card');
    card.classList.add('flag-toggling');
    setTimeout(() => card.classList.remove('flag-toggling'), 500);
  },
  
  destroyed() {
    console.log('[FeatureFlags] Destroyed');
  }
};

export default FeatureFlagsHook;
