const ToastHook = {
    mounted() {
        this.setupNotifications();
    },

    updated() {
        this.setupNotifications();
    },

    setupNotifications() {
        const notifications = this.el.querySelectorAll('.notification-item');
        notifications.forEach((notification) => {
            if (notification.dataset.toastSetup) return;
            notification.dataset.toastSetup = 'true';
            const closeBtn = notification.querySelector('[data-notification-close]');
            if (closeBtn) {
                closeBtn.addEventListener('click', () => {
                    this.dismissNotification(notification);
                });
            }
            setTimeout(() => {
                this.dismissNotification(notification);
            }, 5000);
        });
    },

    dismissNotification(notification) {
        notification.style.animation = 'slideOutRight 0.3s ease-in';
        setTimeout(() => {
            notification.remove();

            const remaining = this.el.querySelectorAll('.notification-item');
            if (remaining.length === 0) {
                this.pushEvent("clear-flash", {});
            }
        }, 300);
    }
};

export default ToastHook;
