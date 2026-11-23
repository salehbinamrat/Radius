import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Compile into the pre-existing ASP.NET static asset directory without replacing its UI.
export default defineConfig({
  plugins: [react()],
  base: '/modern/',
  build: {
    outDir: '../wwwroot/modern',
    emptyOutDir: true,
    lib: { entry: 'src/main.tsx', formats: ['es'], fileName: () => 'noc-react.mjs' },
    cssCodeSplit: false,
  },
});
