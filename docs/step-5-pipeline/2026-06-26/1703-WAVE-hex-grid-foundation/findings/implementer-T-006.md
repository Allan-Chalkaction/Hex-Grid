# Implementer — T-006

STATUS: complete
SHA: 6d9b49c4874f7c0b9da781b15ade5728baf0129a
FILES: README.md

README quickstart (AC-008): ordered steps — (1) supabase start, (2) create dev auth user [self-contained Path A via the seed, or operator-created Path B via Studio/CLI] then `supabase db reset`, documenting the fixed dev UUID + the membership.user_id -> auth.users FK ordering T-003 seeds against, (3) cp .env.example .env + the VITE_* vars, (4) npm install + npm run dev. 'Auth seam' section (AC-007 doc half): states the swap point is src/lib/auth.ts / the identity source and that RLS policies never change because they key off membership. Documents OpenFreeMap liberty (no key) basemap with MapTiler free tier as a keyed alternative (no blocking on a key). Documents AC-003's two-tenant isolation verification as a runnable psql procedure (the acceptable W1 floor). No secrets in the README (AC-010 grep clean). docs-only/cosmetic; prettier clean.
