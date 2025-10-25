const LogsHook = {
    mounted() {
        this.container = this.el;
        this.container.innerHTML = "";
        this.handleEvent("new_log", ({ log }) => {
            if (!log) return;
        const line = document.createElement("div");
        line.className = "text-xs font-mono text-gray-200 whitespace-pre";
        line.innerText = `${log.time} [${log.machine_id}] ${log.msg}`;
        this.container.prepend(line);
        while (this.container.childNodes.length > 500) {
            this.container.removeChild(this.container.lastChild);
        }
        });
    }
};

export default LogsHook;