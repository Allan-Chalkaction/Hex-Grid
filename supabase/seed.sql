-- supabase/seed.sql
-- Dev tenant + dev membership giving the app a working tenant context on first run
-- (no empty-tenant state). Loaded automatically after migrations on `supabase db reset`.
--
-- FK ordering: membership.user_id -> auth.users(id), so the dev auth user MUST exist
-- before the membership row. There are two supported paths (README documents both):
--
--   1. Operator-created (production-shaped): the operator creates the dev user via
--      Supabase Studio Auth UI / `supabase` CLI FIRST, then runs `supabase db reset`.
--      This seed then upserts the membership against the fixed dev UUID below.
--
--   2. Self-contained local dev (default for a clean `db reset`): this seed itself
--      inserts a local-only dev auth user (idempotent upsert against the fixed UUID)
--      so a clean `supabase db reset` stands the whole system up with zero manual
--      steps. This is a LOCAL-DEV convenience only — never a production path.
--
-- Both paths upsert against the SAME fixed dev UUID, so the seed is re-runnable
-- (`supabase db reset` can be run repeatedly without duplicate-key errors).
--
-- Fixed dev identifiers (referenced by the README quickstart):
--   dev user UUID:   00000000-0000-0000-0000-0000000000d1
--   dev tenant UUID: 00000000-0000-0000-0000-0000000000a1
--   dev login:       dev@hex-grid.local / devpass123  (LOCAL DEV ONLY)

-- ---------------------------------------------------------------------------
-- 1. Dev auth user (local-dev self-contained path; idempotent upsert).
--    A bcrypt-hashed password so email/password sign-in works out of the box.
--    If the operator already created the dev user (path 1 above), this upsert
--    simply reconciles the same fixed UUID — it does not create a duplicate.
-- ---------------------------------------------------------------------------
-- NOTE: the token columns (confirmation_token, recovery_token, email_change*,
-- etc.) are set to '' rather than left NULL. GoTrue scans these into non-nullable
-- Go strings, so a NULL there produces "converting NULL to string is unsupported"
-- and a 500 at login. Empty string is the correct "no pending token" value.
insert into auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token,
  email_change, email_change_token_new, email_change_token_current,
  created_at, updated_at
)
values (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-0000000000d1',
  'authenticated', 'authenticated', 'dev@hex-grid.local',
  crypt('devpass123', gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
  '', '',
  '', '', '',
  now(), now()
)
on conflict (id) do update
  set email              = excluded.email,
      encrypted_password = excluded.encrypted_password,
      email_confirmed_at = excluded.email_confirmed_at,
      confirmation_token = excluded.confirmation_token,
      recovery_token     = excluded.recovery_token,
      updated_at         = now();

-- An email identity row so GoTrue resolves the email/password login fully.
insert into auth.identities (
  provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
values (
  '00000000-0000-0000-0000-0000000000d1',
  '00000000-0000-0000-0000-0000000000d1',
  '{"sub":"00000000-0000-0000-0000-0000000000d1","email":"dev@hex-grid.local","email_verified":true}'::jsonb,
  'email', now(), now(), now()
)
on conflict (provider_id, provider) do update
  set identity_data   = excluded.identity_data,
      last_sign_in_at = now(),
      updated_at      = now();

-- ---------------------------------------------------------------------------
-- 2. Dev tenant (idempotent upsert against a fixed UUID).
-- ---------------------------------------------------------------------------
insert into tenant (id, name)
values ('00000000-0000-0000-0000-0000000000a1', 'Dev Tenant')
on conflict (id) do update set name = excluded.name;

-- ---------------------------------------------------------------------------
-- 3. Dev membership binding the dev user to the dev tenant (the pluggable-auth
--    seam). PK (user_id, tenant_id) makes this naturally idempotent.
-- ---------------------------------------------------------------------------
insert into membership (user_id, tenant_id, role)
values (
  '00000000-0000-0000-0000-0000000000d1',
  '00000000-0000-0000-0000-0000000000a1',
  'owner'
)
on conflict (user_id, tenant_id) do update set role = excluded.role;
