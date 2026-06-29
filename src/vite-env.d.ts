/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string;
  readonly VITE_SUPABASE_ANON_KEY: string;
  // ZCTA / ZIP overlay (W5 + Wave 6 EH-T3). Optional — both are operator-supplied
  // and absent by default (graceful-degrade). `VITE_ZCTA_TILES_URL` was read in
  // `zctaSource.ts` since W5 but previously undeclared (EH-T3 closes that gap).
  readonly VITE_ZCTA_TILES_URL?: string;
  readonly VITE_ZCTA_SOURCE_LABEL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
