import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

function resolveAppVersion(): string {
  if (process.env.VITE_APP_VERSION) return process.env.VITE_APP_VERSION
  for (const candidate of ['../VERSION', './VERSION']) {
    try {
      return readFileSync(resolve(__dirname, candidate), 'utf8').trim()
    } catch {
      // try next candidate
    }
  }
  return 'dev'
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify(resolveAppVersion()),
  },
  server: {
    port: 5173,
    host: true,
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
        secure: false
      }
    }
  }
})
