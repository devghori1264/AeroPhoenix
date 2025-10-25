const ClipboardHook = {
    mounted() {
        this.handleEvent("copy-cli", ({ cmd }) => {
            if (!cmd) return;
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard
                .writeText(cmd)
                .catch(err => console.warn("[ClipboardHook] Clipboard write failed:", err));
            } else {
                const ta = document.createElement("textarea");
                ta.value = cmd;
                document.body.appendChild(ta);
                ta.select();
            try {
                document.execCommand("copy");
            } catch (e) {
                console.warn("[ClipboardHook] execCommand copy failed:", e);
            }
                ta.remove();
            }
        });
    }
};

export default ClipboardHook;