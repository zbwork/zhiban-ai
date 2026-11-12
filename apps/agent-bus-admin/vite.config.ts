import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5174,
    proxy: {
      // /api/agent-bus/ 走 bus :8080 (公开 OIDC 入口 + 客户端 API)
      // 必须排在通配 '/api/' 前面 (vite proxy 按声明顺序匹配)
      // 并行会话/worktree 起第二个本地实例时用 BUS_PROXY_TARGET / ADMIN_PROXY_TARGET 覆盖
      '/api/agent-bus/': {
        target: process.env.BUS_PROXY_TARGET || 'http://127.0.0.1:18080',
        changeOrigin: true,
      },
      // 其余 /api/ 走 admin :8082
      // 用 '/api/' 而非 '/api'; 否则 vite 把 '/api-keys' 这类路由也当 API 代理掉
      // (M1 B2 新加的 /api-keys 前端路由踩过)。
      '/api/': {
        target: process.env.ADMIN_PROXY_TARGET || 'http://127.0.0.1:18081',
        changeOrigin: true,
      },
    },
  },
})
