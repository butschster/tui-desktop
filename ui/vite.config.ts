import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import vue from '@vitejs/plugin-vue'
import { wippyComponentPlugin } from '@wippy-fe/vite-plugin'
import { defineConfig } from 'vite'

const moduleRoot = fileURLToPath(new URL('.', import.meta.url))

// The Kickside shell serves these packages through its import map; they must
// stay external so the bundle never ships its own copy (a bundled copy both
// bloats the artifact and breaks on `process.env` references in library code).
const shellProvided = [
  'vue',
  'pinia',
  'vue-router',
  'axios',
  'nanoevents',
  'luxon',
  '@iconify/vue',
  'iconify-icon',
  '@tanstack/vue-query',
  'sanitize-html',
  'markdown-it',
  'markdown-it-async',
  '@wippy-fe/proxy',
  '@wippy-fe/markdown-iframe',
]

export default defineConfig({
  plugins: [vue({ template: { compilerOptions: { isCustomElement: (t) => t.startsWith('wc-') } } }), wippyComponentPlugin()],
  // Lib builds don't auto-replace process.env; provide it so deps that read
  // NODE_ENV don't throw "process is not defined" in the browser/shadow DOM.
  define: {
    'process.env.NODE_ENV': JSON.stringify('production'),
    'process.env': '{}',
  },
  build: {
    target: 'esnext',
    lib: {
      entry: resolve(moduleRoot, 'src/index.ts'),
      name: 'AcmeStarter',
      fileName: 'index',
      formats: ['es'],
    },
    rollupOptions: {
      input: { index: resolve(moduleRoot, 'src/index.ts') },
      external: [...shellProvided, /^primevue\//],
      output: {
        entryFileNames: '[name].js',
        chunkFileNames: '[name]-[hash].js',
        assetFileNames: '[name]-[hash][extname]',
      },
      preserveEntrySignatures: false,
    },
    sourcemap: true,
  },
})
