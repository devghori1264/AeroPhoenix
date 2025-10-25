const PredictiveHook = {
    mounted() {
        this.handleEvent("predictive:update", ({ recs }) => {
            this.el.innerHTML = ""
            if (!recs || recs.length === 0) {
                this.el.innerHTML = "<div class='text-gray-400'>No insights yet</div>"
                return
            }
            recs.forEach(r => {
                const d = document.createElement("div")
                d.className = "mb-2"
                d.innerText = `• ${r.message} (${r.score})`
                this.el.appendChild(d)
            })
        })
    }
}
export default PredictiveHook