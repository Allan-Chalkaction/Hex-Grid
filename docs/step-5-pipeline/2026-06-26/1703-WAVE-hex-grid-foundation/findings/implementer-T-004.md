# Implementer — T-004

STATUS: complete
SHA: d5d9abb93be2047e2843ae16da3a7174bcd1f9a1
FILES: src/lib/supabaseClient.ts, src/lib/auth.ts, src/lib/tenant.ts

Three thin lib modules. supabaseClient.ts constructs the supabase-js client from import.meta.env.VITE_SUPABASE_URL/ANON_KEY with a friendly throw on missing env (AC-010 client-read half; never hardcodes the key). auth.ts is the identity seam (AC-007): exposes getSession/signIn/signOut/onAuthStateChange and is the SOLE module touching supabase.auth — verified via `git grep supabase.auth -- 'src/*'` that the only occurrences are inside auth.ts (the AuthGate consumer reference is a comment, not a call). tenant.ts resolves active tenant from membership (getActiveTenantId/listMemberships) — a separate membership -> tenant_id step from the identity source, so RLS policies (keyed on membership) never change when auth is swapped. typecheck/eslint/prettier all exit 0.
