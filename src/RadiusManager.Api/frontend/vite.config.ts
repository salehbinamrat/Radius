import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Compile into the pre-existing ASP.NET static asset directory without replacing its UI.
export default defineConfig({
  plugins: [react()],
  // Vite library mode keeps React's NODE_ENV branch when compiled as a library.
  // This shipped entrypoint is browser-only production code: never require Node "process".
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  base: '/modern/',
  build: {
    outDir: '../wwwroot/modern',
    emptyOutDir: true,
    lib: { entry: 'src/main.tsx', formats: ['es'], fileName: () => 'noc-react.mjs' },
    cssCodeSplit: false,
  },
});
