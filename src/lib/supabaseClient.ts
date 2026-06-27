import { createClient } from '@supabase/supabase-js';

// The Supabase URL + anon key are read from the environment (Vite injects
// `import.meta.env.VITE_*` at build time). NEVER hardcode the key — see
// `.env.example` for the variable names and the README quickstart for how to
// populate `.env` from your local `supabase start` output. The anon key is a
// public, RLS-gated key; the service-role key is never used in the client.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Missing Supabase env vars. Copy `.env.example` to `.env` and set ' +
      'VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see the README quickstart).',
  );
}

/**
 * The single supabase-js client instance for the app. All data access goes
 * through this client (PostgREST + Auth); the app issues no raw SQL. RLS scopes
 * every query to the authenticated user's tenant in the database.
 */
export const supabase = createClient(supabaseUrl, supabaseAnonKey);
