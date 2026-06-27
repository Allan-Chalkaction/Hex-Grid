# Wave 2 — customers-geocoding (Customers + geocoding CRUD)

**Status:** plan-only.

**Ships:** add/import customers, see them as pins.

- Manual add-customer form → geocode (US Census, behind a `Geocoder` interface) → persist → pin.
- CSV / SQLite bulk import: parse → batch geocode → dedup → persist, with a results/errors report.
- Edit / move / delete; geocode cache so re-adds are free.

**Gates:** code-reviewer · security-auditor (file upload + external geocode calls).

Depends on: Wave 1 (hex-grid-foundation).
