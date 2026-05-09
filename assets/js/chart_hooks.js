/**
 * LiveView hooks for charts (phoenix-colocated stub exports empty hooks — these replace them).
 */

const FEE_BUCKETS = ["1-2", "2-5", "5-10", "10-25", "25-50", "50-100", "100-300", "300+"]

export const FeeHistogram = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    let hist = {}
    try {
      hist = JSON.parse(this.el.dataset.histogram || "{}")
    } catch (_e) {
      hist = {}
    }

    let bars = this.el.querySelector(".histogram-bars")
    if (!bars) {
      bars = document.createElement("div")
      bars.className = "histogram-bars"
      this.el.appendChild(bars)
    }

    const counts = FEE_BUCKETS.map((k) => hist[k] || 0)
    const max = Math.max(1, ...counts)

    bars.replaceChildren()

    const row = document.createElement("div")
    row.style.display = "flex"
    row.style.alignItems = "flex-end"
    row.style.gap = "6px"
    row.style.minHeight = "100px"
    row.style.paddingTop = "8px"
    row.style.width = "100%"

    FEE_BUCKETS.forEach((key, i) => {
      const count = counts[i]
      const col = document.createElement("div")
      col.style.flex = "1"
      col.style.display = "flex"
      col.style.flexDirection = "column"
      col.style.alignItems = "center"
      col.style.minWidth = "0"

      const fill = document.createElement("div")
      fill.style.width = "100%"
      fill.style.minHeight = "4px"
      fill.style.background = "var(--accent-orange, #f97316)"
      fill.style.borderRadius = "2px"
      fill.style.height = `${Math.max(4, (count / max) * 96)}px`

      const cnt = document.createElement("span")
      cnt.className = "mono"
      cnt.style.fontSize = "11px"
      cnt.textContent = String(count)

      const lbl = document.createElement("span")
      lbl.className = "mono muted"
      lbl.style.fontSize = "10px"
      lbl.style.textAlign = "center"
      lbl.style.wordBreak = "break-all"
      lbl.textContent = key

      col.appendChild(fill)
      col.appendChild(cnt)
      col.appendChild(lbl)
      row.appendChild(col)
    })

    bars.appendChild(row)
  },
}

export const Sparkline = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    let vals = []
    try {
      vals = JSON.parse(this.el.dataset.values || "[]")
    } catch (_e) {
      vals = []
    }

    const w = Math.max(200, this.el.clientWidth || this.el.parentElement?.clientWidth || 400)
    const h = 88
    const canvas = document.createElement("canvas")
    canvas.width = w
    canvas.height = h
    const ctx = canvas.getContext("2d")

    const bg = getComputedStyle(this.el).getPropertyValue("--base-bg") || "#13131a"
    ctx.fillStyle = bg.trim() || "#13131a"
    ctx.fillRect(0, 0, w, h)

    if (vals.length === 0) {
      ctx.fillStyle = "#888"
      ctx.font = "12px ui-monospace, monospace"
      ctx.fillText("No samples yet (empty mempool is normal during IBD)", 10, h / 2)
      this.el.replaceChildren(canvas)
      return
    }

    const min = Math.min(...vals)
    const max = Math.max(...vals)
    const range = Math.max(1, max - min)

    ctx.strokeStyle = getComputedStyle(this.el).getPropertyValue("--accent-orange")?.trim() || "#f97316"
    ctx.lineWidth = 2
    ctx.beginPath()

    vals.forEach((v, i) => {
      const x = vals.length === 1 ? w / 2 : 4 + (i / (vals.length - 1)) * (w - 8)
      const y = h - 6 - ((v - min) / range) * (h - 12)
      if (i === 0) {
        ctx.moveTo(x, y)
      } else {
        ctx.lineTo(x, y)
      }
    })
    ctx.stroke()

    this.el.replaceChildren(canvas)
  },
}
