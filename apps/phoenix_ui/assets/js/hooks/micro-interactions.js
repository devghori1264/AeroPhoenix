export const MicroInteractionsHook = {
  mounted() {
    console.log('[MicroInteractions] Mounted');
    
    this.initializeRippleEffects();
    this.initializeToasts();
    this.initializeFormValidation();
    this.initializeSkeletonLoaders();
  },
  
  initializeRippleEffects() {
    const buttons = this.el.querySelectorAll('.btn, button, .clickable');
    
    buttons.forEach(button => {
      button.addEventListener('click', (e) => {
        const ripple = document.createElement('span');
        ripple.className = 'ripple-effect';
        
        const rect = button.getBoundingClientRect();
        const size = Math.max(rect.width, rect.height);
        const x = e.clientX - rect.left - size / 2;
        const y = e.clientY - rect.top - size / 2;
        
        ripple.style.width = ripple.style.height = `${size}px`;
        ripple.style.left = `${x}px`;
        ripple.style.top = `${y}px`;
        
        button.appendChild(ripple);
        
        setTimeout(() => ripple.remove(), 600);
      });
    });
  },
  
  initializeToasts() {
    this.handleEvent('toast', (data) => {
      this.showToast(data.type, data.message);
    });
  },
  
  showToast(type, message) {
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    
    const icons = {
      success: '✓',
      error: '✗',
      warning: '⚠',
      info: 'ℹ'
    };
    
    toast.innerHTML = `
      <span class="toast-icon">${icons[type] || icons.info}</span>
      <span class="toast-message">${message}</span>
    `;
    
    const container = document.getElementById('toast-container') || this.createToastContainer();
    container.appendChild(toast);
    
    setTimeout(() => toast.classList.add('toast-show'), 10);
    setTimeout(() => {
      toast.classList.remove('toast-show');
      setTimeout(() => toast.remove(), 300);
    }, 3000);
  },
  
  createToastContainer() {
    const container = document.createElement('div');
    container.id = 'toast-container';
    document.body.appendChild(container);
    return container;
  },
  
  initializeFormValidation() {
    const inputs = this.el.querySelectorAll('input, textarea, select');
    
    inputs.forEach(input => {
      input.addEventListener('blur', () => {
        if (input.validity.valid) {
          input.classList.remove('input-error');
          input.classList.add('input-success');
        } else {
          input.classList.remove('input-success');
          input.classList.add('input-error');
        }
      });
      
      input.addEventListener('focus', () => {
        input.classList.add('input-focused');
      });
      
      input.addEventListener('blur', () => {
        input.classList.remove('input-focused');
      });
    });
  },
  
  initializeSkeletonLoaders() {
    this.handleEvent('show_skeleton', (data) => {
      const target = this.el.querySelector(data.selector);
      if (target) {
        target.classList.add('skeleton-loading');
      }
    });
    
    this.handleEvent('hide_skeleton', (data) => {
      const target = this.el.querySelector(data.selector);
      if (target) {
        target.classList.remove('skeleton-loading');
      }
    });
  },
  
  destroyed() {
    console.log('[MicroInteractions] Destroyed');
  }
};

export default MicroInteractionsHook;
