// Commit graph visualization — Canvas 2D rendering of the DAG.
const LANE_COLORS = [
  "#00ff88", "#ff6b6b", "#4ecdc4", "#ffe66d",
  "#a78bfa", "#f472b6", "#38bdf8", "#fb923c",
]

const CONF = {
  rowHeight: 32,
  laneWidth: 20,
  nodeRadius: 4,
  mergeSize: 5,
  leftPad: 16,
  font: "11px ui-monospace, 'SF Mono', 'Cascadia Code', monospace",
  bg: "#0a0a0f",
  textColor: "#c8c8d4",
  dimColor: "#555568",
  branchBg: "rgba(0, 255, 136, 0.12)",
  branchColor: "#00ff88",
  laneLineWidth: 1.5,
  laneLineAlpha: 0.35,
}

function laneColor(col) {
  return LANE_COLORS[col % LANE_COLORS.length]
}

function laneX(col) {
  return CONF.leftPad + col * CONF.laneWidth
}

function rowY(row) {
  return 24 + row * CONF.rowHeight
}

function relativeTime(iso) {
  const d = new Date(iso)
  const diff = Date.now() - d.getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return `${mins}m`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `${hrs}h`
  const days = Math.floor(hrs / 24)
  if (days < 30) return `${days}d`
  const months = Math.floor(days / 30)
  return `${months}mo`
}

function drawRoundRect(ctx, x, y, w, h, r) {
  ctx.beginPath()
  if (ctx.roundRect) {
    ctx.roundRect(x, y, w, h, r)
  } else {
    ctx.moveTo(x + r, y)
    ctx.lineTo(x + w - r, y)
    ctx.arcTo(x + w, y, x + w, y + r, r)
    ctx.lineTo(x + w, y + h - r)
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
    ctx.lineTo(x + r, y + h)
    ctx.arcTo(x, y + h, x, y + h - r, r)
    ctx.lineTo(x, y + r)
    ctx.arcTo(x, y, x + r, y, r)
    ctx.closePath()
  }
}

function clearCanvas(canvas) {
  const ctx = canvas.getContext("2d")
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, canvas.width, canvas.height)
  canvas.width = 0
  canvas.height = 0
  canvas.style.width = "0"
  canvas.style.height = "0"
}

function render(canvas, data) {
  const ctx = canvas.getContext("2d")
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  if (!data || !data.nodes || data.nodes.length === 0) {
    canvas.width = 0
    canvas.height = 0
    return
  }

  const dpr = window.devicePixelRatio || 1
  const graphWidth = CONF.leftPad + (data.max_columns + 1) * CONF.laneWidth
  const textAreaStart = graphWidth + 12
  const totalWidth = Math.max(textAreaStart + 560, 700)
  const totalHeight = 48 + data.nodes.length * CONF.rowHeight

  canvas.width = totalWidth * dpr
  canvas.height = totalHeight * dpr
  canvas.style.width = totalWidth + "px"
  canvas.style.height = totalHeight + "px"

  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

  // Background
  ctx.fillStyle = CONF.bg
  ctx.fillRect(0, 0, totalWidth, totalHeight)

  // Build oid -> node lookup
  const nodeByOid = {}
  for (const n of data.nodes) {
    nodeByOid[n.oid] = n
  }

  const laneSnapshots = data.active_lanes_per_row || []

  // 1) Draw lane continuity lines — only between rows where the lane
  //    is active in BOTH the current AND next row's snapshot.
  //    This prevents dangling stubs at lane endpoints.
  for (let row = 0; row < laneSnapshots.length - 1; row++) {
    const activeCols = laneSnapshots[row]
    const nextActiveCols = new Set(laneSnapshots[row + 1] || [])
    if (!activeCols) continue

    const y1 = rowY(row)
    const y2 = rowY(row + 1)

    for (const col of activeCols) {
      if (!nextActiveCols.has(col)) continue // lane ends here — skip stub

      const x = laneX(col)
      ctx.globalAlpha = CONF.laneLineAlpha
      ctx.strokeStyle = laneColor(col)
      ctx.lineWidth = CONF.laneLineWidth
      ctx.beginPath()
      ctx.moveTo(x, y1)
      ctx.lineTo(x, y2)
      ctx.stroke()
    }
  }
  ctx.globalAlpha = 1.0

  // 2) Draw cross-lane edges
  for (const edge of data.edges) {
    if (edge.from_col === edge.to_col) continue

    const fromX = laneX(edge.from_col)
    const fromY = rowY(edge.from_row)
    const toX = laneX(edge.to_col)
    const toNode = nodeByOid[edge.to_oid]
    const toY = toNode ? rowY(toNode.row) : fromY + CONF.rowHeight

    ctx.strokeStyle = laneColor(edge.to_col)
    ctx.lineWidth = CONF.laneLineWidth
    ctx.globalAlpha = 0.7
    ctx.beginPath()
    ctx.moveTo(fromX, fromY)

    const midY = (fromY + toY) / 2
    ctx.bezierCurveTo(fromX, midY, toX, midY, toX, toY)
    ctx.stroke()
  }
  ctx.globalAlpha = 1.0

  // 3) Draw nodes and labels
  ctx.font = CONF.font
  for (const node of data.nodes) {
    const x = laneX(node.column)
    const y = rowY(node.row)
    const color = laneColor(node.column)

    // Node shape
    if (node.is_merge) {
      const s = CONF.mergeSize
      ctx.fillStyle = CONF.bg
      ctx.strokeStyle = color
      ctx.lineWidth = 2
      ctx.beginPath()
      ctx.moveTo(x, y - s)
      ctx.lineTo(x + s, y)
      ctx.lineTo(x, y + s)
      ctx.lineTo(x - s, y)
      ctx.closePath()
      ctx.fill()
      ctx.stroke()
    } else {
      ctx.fillStyle = color
      ctx.beginPath()
      ctx.arc(x, y, CONF.nodeRadius, 0, Math.PI * 2)
      ctx.fill()
    }

    // Text: [short_oid] [branch badges] [message] [author] [time]
    let tx = textAreaStart

    // Short OID
    ctx.fillStyle = color
    ctx.globalAlpha = 0.8
    ctx.fillText(node.short_oid, tx, y + 4)
    ctx.globalAlpha = 1.0
    tx += 62

    // Branch badges
    if (node.branches && node.branches.length > 0) {
      for (const br of node.branches) {
        const tw = ctx.measureText(br).width + 10
        ctx.fillStyle = CONF.branchBg
        drawRoundRect(ctx, tx - 3, y - 7, tw, 16, 3)
        ctx.fill()
        ctx.fillStyle = CONF.branchColor
        ctx.fillText(br, tx + 2, y + 4)
        tx += tw + 4
      }
      tx += 4
    }

    // Message (truncated)
    const msgEnd = textAreaStart + 400
    const msgMaxW = Math.max(msgEnd - tx, 80)
    ctx.fillStyle = CONF.textColor
    let msg = node.message || ""
    if (ctx.measureText(msg).width > msgMaxW) {
      while (msg.length > 0 && ctx.measureText(msg + "…").width > msgMaxW) {
        msg = msg.slice(0, -1)
      }
      msg += "…"
    }
    ctx.fillText(msg, tx, y + 4)

    // Author + time
    ctx.fillStyle = CONF.dimColor
    ctx.fillText(node.author || "", textAreaStart + 410, y + 4)
    ctx.fillText(relativeTime(node.timestamp), textAreaStart + 510, y + 4)
  }
}

const GraphHook = {
  mounted() {
    this.canvas = this.el

    this.handleEvent("graph:update", (data) => {
      render(this.canvas, data)
    })

    this.handleEvent("graph:clear", () => {
      clearCanvas(this.canvas)
    })
  },

  updated() {},
  destroyed() {},
}

export default GraphHook
