/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Room server origin baked in at build time, e.g. rooms.example.workers.dev. */
  readonly VITE_ROOM_SERVER?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
