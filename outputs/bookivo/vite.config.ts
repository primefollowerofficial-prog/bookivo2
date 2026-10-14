import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({
  plugins: [react()],
  base: '/',
  build: {
    outDir: 'dist',
    rolldownOptions: {
      output: {
        codeSplitting: {
          groups: [
            { name: 'supabase', test: /node_modules[\\/]@supabase[\\/]/, priority: 10 },
            { name: 'react', test: /node_modules[\\/](react|react-dom|react-router-dom)[\\/]/, priority: 5 },
          ],
        },
      },
    },
  },
});
