import { defineConfig } from 'vitest/config';

// Vitest harness for hex-grid (CG-T10). Two test classes share this config:
//   * tests/unit/**         — pure logic, NO DB, NO network.
//   * tests/integration/**  — live against the LOCAL Supabase stack; self-skip
//                             (describe.skip) when SERVICE_ROLE_KEY / API_URL are
//                             absent so `npm test` never hard-fails in a no-DB CI.
//
// See tests/README.md for the exact run command (it exports the local Supabase
// keys into the process env the integration tests read from process.env).
export default defineConfig({
  test: {
    // Node — these tests cover logic + DB, never React rendering (no jsdom).
    environment: 'node',
    // Wave 4 (AS-T1+): the saturation-coverage unit/layer tests are CO-LOCATED
    // with their source (`src/lib/coverage.test.ts`,
    // `src/components/saturationLayer.test.ts`) per the wave spec's planned
    // files. They are pure logic / deck.gl layer-config assertions (no React
    // render), so the `node` environment serves them exactly as the tests/**
    // suite. The existing tests/** glob is unchanged.
    include: ['tests/**/*.test.ts', 'src/**/*.test.ts'],
    setupFiles: ['tests/setup/env.ts'],
    // The app singleton `src/lib/supabaseClient.ts` reads import.meta.env.VITE_*
    // at MODULE LOAD and throws if absent. Unit tests transitively import it (via
    // customers.ts / csvImport.ts), so we feed it harmless DUMMY values here. The
    // singleton is NEVER used by any test — integration tests build their own
    // clients from process.env (see tests/helpers/integration.ts). These are not
    // secrets (placeholder URL + a non-functional key string).
    env: {
      VITE_SUPABASE_URL: 'http://127.0.0.1:54321',
      VITE_SUPABASE_ANON_KEY: 'vitest-placeholder-anon-key-unused',
    },
    // Integration tests create auth users + seed/teardown rows; keep them serial
    // within a file and give DB round-trips headroom.
    testTimeout: 30000,
    hookTimeout: 30000,
  },
});
