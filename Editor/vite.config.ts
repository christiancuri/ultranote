import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The bundle is served by the native app from `app://editor/…`, so every URL in
// the output must be relative (`base: './'`), including lazy chunks.
export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: '../build/editor',
    emptyOutDir: true,
    target: 'safari17',
    chunkSizeWarningLimit: 1500,
  },
  server: { port: 5173, strictPort: false },
  preview: { port: 4173, strictPort: false },
})
