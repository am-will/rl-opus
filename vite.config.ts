import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    host: '127.0.0.1',
    port: Number(process.env.PORT) || 5173,
  },
  build: { target: 'es2022' },
});
