import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: { outDir: 'dist-community', rolldownOptions: { input: 'community.html' } },
  server: { port: 5175, proxy: { '/api/admin/': { target: process.env.ADMIN_PROXY_TARGET || 'http://127.0.0.1:18081', changeOrigin: true } } },
})
