'use strict'

const { app, BrowserWindow, shell } = require('electron')
const path = require('path')
const http = require('http')
const fs = require('fs')
const os = require('os')

const DIFFS_DIR = path.join(os.homedir(), 'sites', 'diffs')
const PORT = 5174 // separate from Vite dev port (5173)

// ── Helpers ────────────────────────────────────────────────────

function getBody(req) {
  return new Promise(resolve => {
    let data = ''
    req.on('data', chunk => (data += chunk))
    req.on('end', () => resolve(data))
  })
}

function json(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' })
  res.end(JSON.stringify(data))
}

function serveStatic(res, filePath) {
  const MIME = {
    '.html': 'text/html',
    '.js': 'application/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
  }
  try {
    const ext = path.extname(filePath).toLowerCase()
    const content = fs.readFileSync(filePath)
    res.writeHead(200, { 'Content-Type': MIME[ext] ?? 'application/octet-stream' })
    res.end(content)
  } catch {
    res.writeHead(404)
    res.end('Not found')
  }
}

// ── Production HTTP server (static + API) ─────────────────────

async function startServer(distPath) {
  const server = http.createServer(async (req, res) => {
    const rawUrl = req.url ?? '/'

    // CORS — allow Vite dev renderer to reach this in dev if needed
    res.setHeader('Access-Control-Allow-Origin', '*')
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end() }

    // GET /api/projects
    if (req.method === 'GET' && rawUrl === '/api/projects') {
      try {
        const dirs = fs.existsSync(DIFFS_DIR)
          ? fs.readdirSync(DIFFS_DIR).filter(f =>
              fs.statSync(path.join(DIFFS_DIR, f)).isDirectory())
          : []
        return json(res, 200, dirs)
      } catch { return json(res, 200, []) }
    }

    // /api/diffs/:project/(ast|ledger|submit)
    const m = rawUrl.match(/^\/api\/diffs\/([^/?]+)\/(ast|ledger|submit)/)
    if (m) {
      const [, project, action] = m
      const dir = path.join(DIFFS_DIR, project)

      if (req.method === 'GET' && action === 'ast') {
        try { return json(res, 200, JSON.parse(fs.readFileSync(path.join(dir, 'full_ast.json'), 'utf-8'))) }
        catch { return json(res, 404, { error: 'AST not found. Run export_to_viewer first.' }) }
      }

      if (req.method === 'GET' && action === 'ledger') {
        try { return json(res, 200, JSON.parse(fs.readFileSync(path.join(dir, 'diff_ledger.json'), 'utf-8'))) }
        catch { return json(res, 404, { error: 'Ledger not found.' }) }
      }

      if (req.method === 'POST' && action === 'submit') {
        try {
          const diff = JSON.parse(await getBody(req))
          const ledgerPath = path.join(dir, 'diff_ledger.json')
          const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf-8'))
          ledger.diffs.push(diff)
          fs.writeFileSync(ledgerPath, JSON.stringify(ledger, null, 2))
          return json(res, 200, { status: 'ok', diff_id: diff.diff_id })
        } catch (e) { return json(res, 500, { error: String(e) }) }
      }
    }

    // Static file serving — SPA fallback to index.html
    const urlPath = rawUrl.split('?')[0]
    const filePath = path.extname(urlPath)
      ? path.join(distPath, urlPath)
      : path.join(distPath, 'index.html')

    serveStatic(res, filePath)
  })

  await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve))
  return server
}

// ── Window ─────────────────────────────────────────────────────

function createWindow(url) {
  const win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 900,
    minHeight: 600,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    title: 'DirGraph Viewer',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
    },
  })

  win.loadURL(url)

  // Open external links in the default browser, not in Electron
  win.webContents.setWindowOpenHandler(({ url: externalUrl }) => {
    shell.openExternal(externalUrl)
    return { action: 'deny' }
  })

  return win
}

// ── App lifecycle ──────────────────────────────────────────────

app.whenReady().then(async () => {
  let url

  if (app.isPackaged) {
    const distPath = path.join(__dirname, '../dist')
    await startServer(distPath)
    url = `http://localhost:${PORT}`
  } else {
    // Dev: Vite is already running on 5173 (started by concurrently)
    url = 'http://localhost:5173'
  }

  createWindow(url)

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow(url)
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
