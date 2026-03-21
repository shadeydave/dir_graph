import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import fs from 'node:fs'
import path from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'

const DIFFS_DIR = path.join(process.env.HOME ?? '', 'sites', 'diffs')

function getBody(req: IncomingMessage): Promise<string> {
  return new Promise(resolve => {
    let body = ''
    req.on('data', chunk => (body += chunk))
    req.on('end', () => resolve(body))
  })
}

function json(res: ServerResponse, status: number, data: unknown) {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-cache',
  })
  res.end(JSON.stringify(data))
}

export default defineConfig({
  plugins: [
    react(),
    {
      name: 'diffs-api',
      configureServer(server) {
        server.middlewares.use(async (req, res, next) => {
          const url = req.url ?? ''

          // GET /api/projects
          if (req.method === 'GET' && url === '/api/projects') {
            try {
              const dirs = fs.existsSync(DIFFS_DIR)
                ? fs
                    .readdirSync(DIFFS_DIR)
                    .filter(f => fs.statSync(path.join(DIFFS_DIR, f)).isDirectory())
                : []
              return json(res, 200, dirs)
            } catch {
              return json(res, 200, [])
            }
          }

          // /api/diffs/:project/(ast|ledger|submit)
          const m = url.match(/^\/api\/diffs\/([^/]+)\/(ast|ledger|submit)(\?.*)?$/)
          if (!m) return next()

          const [, project, action] = m
          const projectDir = path.join(DIFFS_DIR, project)

          if (req.method === 'GET' && action === 'ast') {
            const p = path.join(projectDir, 'full_ast.json')
            try {
              return json(res, 200, JSON.parse(fs.readFileSync(p, 'utf-8')))
            } catch {
              return json(res, 404, { error: 'AST not found. Run export_to_viewer first.' })
            }
          }

          if (req.method === 'GET' && action === 'ledger') {
            const p = path.join(projectDir, 'diff_ledger.json')
            try {
              return json(res, 200, JSON.parse(fs.readFileSync(p, 'utf-8')))
            } catch {
              return json(res, 404, { error: 'Ledger not found.' })
            }
          }

          if (req.method === 'POST' && action === 'submit') {
            const p = path.join(projectDir, 'diff_ledger.json')
            try {
              const diff = JSON.parse(await getBody(req))
              const ledger = JSON.parse(fs.readFileSync(p, 'utf-8'))
              ledger.diffs.push(diff)
              fs.writeFileSync(p, JSON.stringify(ledger, null, 2))
              return json(res, 200, { status: 'ok', diff_id: diff.diff_id })
            } catch (e) {
              return json(res, 500, { error: String(e) })
            }
          }

          next()
        })
      },
    },
  ],
})
