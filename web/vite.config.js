import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

// `npm run dev` proxies the API to the running vbal-api container (HTTPS, lab CA).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  // Dev only: the API's leaf is signed by the lab CA, which Vite's proxy does not load.
  server: { proxy: { '/api': { target: 'https://127.0.0.1:19191', secure: false } } },
});
