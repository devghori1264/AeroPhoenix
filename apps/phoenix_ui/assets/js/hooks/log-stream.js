export const LogStreamHook = {
  mounted() {
    console.log('[LogStream] Mounted');
    
    this.logs = [];
    this.filteredLogs = [];
    this.maxLogs = 10000;
    this.visibleRange = { start: 0, end: 50 };
    this.rowHeight = 24;
    this.autoScroll = true;
    this.paused = false;
    
    this.filters = {
      level: 'all',
      search: '',
      regex: null,
      timeRange: 'all'
    };
    
    this.logLevels = {
      trace: { color: '#64748b', icon: '🔍', priority: 0 },
      debug: { color: '#06b6d4', icon: '🐛', priority: 1 },
      info: { color: '#10b981', icon: 'ℹ️', priority: 2 },
      warn: { color: '#fbbf24', icon: '⚠️', priority: 3 },
      error: { color: '#ef4444', icon: '❌', priority: 4 },
      fatal: { color: '#dc2626', icon: '💀', priority: 5 }
    };
    
    this.initializeContainer();
    this.setupEventHandlers();
    this.setupVirtualScroll();
    this.setupFilterControls();
    this.startAutoScroll();
  },
  
  initializeContainer() {
    this.container = this.el.querySelector('#log-container');
    this.viewport = this.el.querySelector('#log-viewport');
    this.scrollContainer = this.el.querySelector('#log-scroll-container');
    
    if (!this.container || !this.viewport || !this.scrollContainer) {
      console.error('[LogStream] Required elements not found');
      return;
    }
    
    this.viewportHeight = this.viewport.clientHeight;
    this.visibleRows = Math.ceil(this.viewportHeight / this.rowHeight) + 5;
  },
  
  setupVirtualScroll() {
    if (!this.scrollContainer) return;
    
    this.scrollContainer.addEventListener('scroll', () => {
      this.handleScroll();
    });
    
    let scrollTimeout;
    this.scrollContainer.addEventListener('scroll', () => {
      if (!this.programmaticScroll) {
        this.autoScroll = false;
        this.showScrollPausedIndicator();
        
        clearTimeout(scrollTimeout);
        scrollTimeout = setTimeout(() => {
          const isAtBottom = this.isScrolledToBottom();
          if (isAtBottom) {
            this.autoScroll = true;
            this.hideScrollPausedIndicator();
          }
        }, 1000);
      }
      this.programmaticScroll = false;
    });
  },
  
  handleScroll() {
    const scrollTop = this.scrollContainer.scrollTop;
    const startIndex = Math.floor(scrollTop / this.rowHeight);
    const endIndex = Math.min(
      startIndex + this.visibleRows,
      this.filteredLogs.length
    );
    
    this.visibleRange = { start: startIndex, end: endIndex };
    this.renderVisibleLogs();
  },
  
  renderVisibleLogs() {
    if (!this.container) return;
    
    const visibleLogs = this.filteredLogs.slice(
      this.visibleRange.start,
      this.visibleRange.end
    );
    
    const totalHeight = this.filteredLogs.length * this.rowHeight;
    this.container.style.height = `${totalHeight}px`;
    
    this.viewport.innerHTML = '';
    this.viewport.style.transform = `translateY(${this.visibleRange.start * this.rowHeight}px)`;
    
    visibleLogs.forEach((log, index) => {
      const logEl = this.createLogElement(log, this.visibleRange.start + index);
      this.viewport.appendChild(logEl);
    });
    
    this.updateStats();
  },
  
  createLogElement(log, index) {
    const div = document.createElement('div');
    div.className = `log-line log-level-${log.level}`;
    div.dataset.index = index;
    div.style.height = `${this.rowHeight}px`;
    
    const levelInfo = this.logLevels[log.level] || this.logLevels.info;
    
    const time = new Date(log.timestamp).toLocaleTimeString('en-US', {
      hour12: false,
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      fractionalSecondDigits: 3
    });
    
    const levelBadge = `<span class="log-level-badge" style="background-color: ${levelInfo.color}20; color: ${levelInfo.color}">${levelInfo.icon} ${log.level.toUpperCase()}</span>`;
    
    const source = log.source ? `<span class="log-source">[${log.source}]</span>` : '';
    
    const message = this.highlightMessage(log.message, log.level);
    
    div.innerHTML = `
      <span class="log-timestamp">${time}</span>
      ${levelBadge}
      ${source}
      <span class="log-message">${message}</span>
    `;
    
    div.addEventListener('click', () => {
      this.showLogDetails(log);
    });
    
    if (index >= this.filteredLogs.length - 5) {
      div.style.animation = 'log-slide-in 0.2s ease-out';
    }
    
    return div;
  },

  highlightMessage(message, level) {
    let highlighted = message;
    
    if (message.includes('{') && message.includes('}')) {
      highlighted = highlighted.replace(
        /\{[^}]+\}/g,
        match => `<span class="log-json">${this.escapeHtml(match)}</span>`
      );
    }
    
    highlighted = highlighted.replace(
      /\b(?:\d{1,3}\.){3}\d{1,3}\b/g,
      match => `<span class="log-ip">${match}</span>`
    );
    
    highlighted = highlighted.replace(
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi,
      match => `<span class="log-uuid">${match}</span>`
    );
    
    highlighted = highlighted.replace(
      /\b\d+(?:\.\d+)?(?:ms|MB|KB|GB|%|s)?\b/g,
      match => `<span class="log-number">${match}</span>`
    );
    
    highlighted = highlighted.replace(
      /https?:\/\/[^\s]+/g,
      match => `<a href="${match}" class="log-url" target="_blank">${match}</a>`
    );
    
    highlighted = highlighted.replace(
      /"([^"]+)"|'([^']+)'/g,
      (match, g1, g2) => `<span class="log-string">${match}</span>`
    );
    
    if (level === 'error' || level === 'fatal') {
      highlighted = highlighted.replace(
        /at\s+[\w\.]+\s+\([^)]+\)/g,
        match => `<span class="log-stacktrace">${match}</span>`
      );
    }
    
    if (this.filters.search) {
      const regex = this.filters.regex || new RegExp(this.escapeRegex(this.filters.search), 'gi');
      highlighted = highlighted.replace(
        regex,
        match => `<mark class="log-search-highlight">${match}</mark>`
      );
    }
    
    return highlighted;
  },
  
  setupEventHandlers() {
    this.handleEvent('log_message', (data) => {
      this.addLog(data);
    });
    
    this.handleEvent('log_batch', (data) => {
      this.addLogBatch(data.logs);
    });
    
    this.handleEvent('clear_logs', () => {
      this.clearLogs();
    });
    
    const resumeBtn = this.el.querySelector('#resume-autoscroll-btn');
    if (resumeBtn) {
      resumeBtn.addEventListener('click', () => {
        this.autoScroll = true;
        this.scrollToBottom();
        this.hideScrollPausedIndicator();
      });
    }
    
    const pauseBtn = this.el.querySelector('#pause-logs-btn');
    if (pauseBtn) {
      pauseBtn.addEventListener('click', () => {
        this.paused = !this.paused;
        pauseBtn.textContent = this.paused ? '▶️ Resume' : '⏸️ Pause';
        pauseBtn.classList.toggle('paused', this.paused);
      });
    }
    
    const exportBtn = this.el.querySelector('#export-logs-btn');
    if (exportBtn) {
      exportBtn.addEventListener('click', () => {
        this.exportLogs();
      });
    }
    
    const clearBtn = this.el.querySelector('#clear-logs-btn');
    if (clearBtn) {
      clearBtn.addEventListener('click', () => {
        this.clearLogs();
      });
    }
  },
  
  setupFilterControls() {
    const levelButtons = this.el.querySelectorAll('.log-level-filter');
    levelButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        levelButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.filters.level = btn.dataset.level;
        this.applyFilters();
      });
    });
    
    const searchInput = this.el.querySelector('#log-search-input');
    if (searchInput) {
      let searchTimeout;
      searchInput.addEventListener('input', (e) => {
        clearTimeout(searchTimeout);
        searchTimeout = setTimeout(() => {
          this.filters.search = e.target.value;
          this.applyFilters();
        }, 300);
      });
    }
    
    const regexToggle = this.el.querySelector('#log-regex-toggle');
    if (regexToggle) {
      regexToggle.addEventListener('change', (e) => {
        if (e.target.checked && this.filters.search) {
          try {
            this.filters.regex = new RegExp(this.filters.search, 'gi');
          } catch (err) {
            this.filters.regex = null;
            this.showError('Invalid regex pattern');
          }
        } else {
          this.filters.regex = null;
        }
        this.applyFilters();
      });
    }
  },
  
  addLog(logData) {
    if (this.paused) return;
    
    const log = {
      timestamp: logData.timestamp || new Date().toISOString(),
      level: logData.level || 'info',
      message: logData.message || '',
      source: logData.source || '',
      metadata: logData.metadata || {}
    };
    
    this.logs.push(log);
    
    if (this.logs.length > this.maxLogs) {
      this.logs = this.logs.slice(-this.maxLogs);
    }
    
    if (this.matchesFilters(log)) {
      this.filteredLogs.push(log);
      if (this.filteredLogs.length > this.maxLogs) {
        this.filteredLogs = this.filteredLogs.slice(-this.maxLogs);
      }
      this.renderVisibleLogs();
      
      if (this.autoScroll) {
        this.scrollToBottom();
      }
    }
  },
  
  addLogBatch(logs) {
    if (this.paused) return;
    
    logs.forEach(log => {
      this.logs.push(log);
    });
    
    if (this.logs.length > this.maxLogs) {
      this.logs = this.logs.slice(-this.maxLogs);
    }
    
    this.applyFilters();
  },
  
  applyFilters() {
    this.filteredLogs = this.logs.filter(log => this.matchesFilters(log));
    this.visibleRange = { start: 0, end: this.visibleRows };
    this.renderVisibleLogs();
    
    if (this.autoScroll) {
      this.scrollToBottom();
    }
    
    const indicator = this.el.querySelector('#filter-indicator');
    if (indicator) {
      indicator.classList.add('pulse');
      setTimeout(() => indicator.classList.remove('pulse'), 500);
    }
  },
  
  matchesFilters(log) {
    if (this.filters.level !== 'all') {
      const levelPriority = this.logLevels[log.level]?.priority || 0;
      const filterPriority = this.logLevels[this.filters.level]?.priority || 0;
      if (levelPriority < filterPriority) {
        return false;
      }
    }
    
    if (this.filters.search) {
      const searchLower = this.filters.search.toLowerCase();
      const message = log.message.toLowerCase();
      const source = (log.source || '').toLowerCase();
      
      if (this.filters.regex) {
        return this.filters.regex.test(log.message) || this.filters.regex.test(log.source || '');
      } else {
        return message.includes(searchLower) || source.includes(searchLower);
      }
    }
    
    return true;
  },
  
  startAutoScroll() {
    this.scrollToBottom();
  },
  
  scrollToBottom() {
    if (!this.scrollContainer) return;
    
    this.programmaticScroll = true;
    this.scrollContainer.scrollTop = this.scrollContainer.scrollHeight;
  },
  
  isScrolledToBottom() {
    if (!this.scrollContainer) return false;
    
    const threshold = 50;
    const scrollBottom = this.scrollContainer.scrollHeight - this.scrollContainer.scrollTop - this.scrollContainer.clientHeight;
    return scrollBottom < threshold;
  },
  
  showScrollPausedIndicator() {
    const indicator = this.el.querySelector('#scroll-paused-indicator');
    if (indicator) {
      indicator.classList.add('show');
    }
  },
  
  hideScrollPausedIndicator() {
    const indicator = this.el.querySelector('#scroll-paused-indicator');
    if (indicator) {
      indicator.classList.remove('show');
    }
  },
  
  showLogDetails(log) {
    this.pushEvent('show_log_details', {
      log: {
        timestamp: log.timestamp,
        level: log.level,
        message: log.message,
        source: log.source,
        metadata: log.metadata
      }
    });
  },
  
  exportLogs() {
    const logsToExport = this.filteredLogs.length > 0 ? this.filteredLogs : this.logs;
    const text = logsToExport.map(log => {
      const time = new Date(log.timestamp).toISOString();
      return `[${time}] ${log.level.toUpperCase()} ${log.source ? `[${log.source}]` : ''} ${log.message}`;
    }).join('\n');
    
    const blob = new Blob([text], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `logs-${new Date().toISOString()}.txt`;
    a.click();
    URL.revokeObjectURL(url);
    
    this.showSuccess(`Exported ${logsToExport.length} logs`);
  },
  
  clearLogs() {
    this.logs = [];
    this.filteredLogs = [];
    this.renderVisibleLogs();
    this.showSuccess('Logs cleared');
  },
  
  updateStats() {
    const statsEl = this.el.querySelector('#log-stats');
    if (!statsEl) return;
    
    const levelCounts = {};
    Object.keys(this.logLevels).forEach(level => {
      levelCounts[level] = this.logs.filter(log => log.level === level).length;
    });
    
    statsEl.innerHTML = `
      <span class="log-stat">Total: <strong>${this.logs.length}</strong></span>
      <span class="log-stat">Filtered: <strong>${this.filteredLogs.length}</strong></span>
      <span class="log-stat">Errors: <strong class="text-red-400">${levelCounts.error + levelCounts.fatal}</strong></span>
      <span class="log-stat">Warnings: <strong class="text-yellow-400">${levelCounts.warn}</strong></span>
    `;
  },
  
  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  },
  
  escapeRegex(text) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  },
  
  showSuccess(message) {
    this.pushEvent('toast', { type: 'success', message });
  },
  
  showError(message) {
    this.pushEvent('toast', { type: 'error', message });
  },
  
  destroyed() {
    console.log('[LogStream] Destroyed');
  }
};

export default LogStreamHook;
