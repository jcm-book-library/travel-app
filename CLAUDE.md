# Travel Companion: notes for Claude

> **Stack decided (Option B). Data model waiting for the owner's approval.** Lines marked **(proposed)** are not decided yet. Don't scaffold until the owner approves the data model.

## Decisions (from the owner, 23 Oct 26)
- **Phones:** latest iPhone and latest Samsung. Both installed as a home-screen PWA.
- **Route:** Egypt first (group tour), then Czechia, Latvia, Lithuania, Estonia, Finland, Poland, Germany. In February, Egypt, the Baltics and Finland are UTC+2 and Czechia, Poland and Germany are UTC+1, so zone changes are one hour; still store IANA zones (`Africa/Cairo`, `Europe/Prague`, `Europe/Riga`, `Europe/Vilnius`, `Europe/Tallinn`, `Europe/Helsinki`, `Europe/Warsaw`, `Europe/Berlin`).
- **Source material:** tour and flight PDFs; other bookings are confirmation emails/pages that can be turned into PDFs. Import is done in a Claude session into an import file (no paid AI inside the app).
- **Offline = read-only.** Itinerary, times and meeting points must be viewable offline. Wi-Fi is available daily, so edits are online-only and there is no offline edit queue in Phase 1.
- **Map:** an online in-app map is enough (they use other apps for navigation). No offline map packs. Cached tiles are a nice-to-have, not a requirement.
- **"Where we've been":** a daily record of places actually visited is a core feature, not a route-following map.
- **Sign-in:** email 6-digit code typed inside the app (no link, so iOS never switches windows). Secure but easy.
- **Editing:** both users edit everything. Each user has a colour (owner = blue, sister = pink); additions and edits are tinted by who made them. Default text is white/black by light/dark mode.
- **Trips:** every trip is stored. A finished trip can be **archived** (read-only log) and is excluded from resets and "fresh start" actions. The app shows the active trip; a trip switcher can come later.
- **Look:** house look (Proton Seasons, dark) plus a light mode; refine once the app is running.

**Read the house rules first:** [HOUSE-RULES.md](https://github.com/jcm-book-library/control-room/blob/main/HOUSE-RULES.md) in `control-room` (plain text: https://raw.githubusercontent.com/jcm-book-library/control-room/main/HOUSE-RULES.md). The notes below are this repo's own; where they are more specific, they win. The project charter is `project.json`.

## What this is
- A phone-first travel companion for two people (the owner and their sister) on a February 2027 trip: group tour, flights, independent stays, day tours, several cities and regions.
- Everything lives in **one timeline**, grouped by day, then city, then region.
- It's also a test case: the data model must support more trips later.

## Where this repo differs from the house template
- **Not a single-file app.** It needs a service worker, an offline database and a map, so it uses a Vite build (proposed). The claude.ai artifact route doesn't apply (artifacts can't work offline).
- **Data lives in Supabase, not a Google Sheet.** The Google Sheet rules in HOUSE-RULES section 1 don't apply here; the Supabase rules below do.
- GitHub Pages is published by a GitHub Action that builds `dist/` from `main` (like recall-arcade).

## Stack (decided: Option B, Vite PWA)
- Vite + React + TypeScript, `vite-plugin-pwa` (Workbox) for the service worker and install.
- Dexie (IndexedDB) as the on-phone copy of the trip; Supabase JS for auth and sync.
- Leaflet or MapLibre GL JS for an online map (stops, hotels, meeting points, visited places). Pick a tile provider whose free tier and terms fit (OpenStreetMap's own tiles have a usage policy; check before launch).
- Tests: Vitest for logic (time zones, sleep maths, sync), Playwright for screens at 390px and 1280px, including an offline run.
- Scripts and packages pinned to exact versions.

## Rules for the code
- **Offline first.** Screens read from Dexie, never straight from Supabase. Sync runs in the background and writes into Dexie.
- **The whole active trip is on the phone** (it's small), so the itinerary, times and meeting points open in flight mode. The map needs a connection.
- **Edits are online-only** in Phase 1; offline, the app is read-only and says so. Concurrent edits: last write wins per row, using `updated_at`. An offline outbox is a possible later add if it proves needed.
- **Who did it:** every row keeps `updated_by`; the UI tints by the member's `colour`.
- **Times:** every timed item stores a local date, an optional local time and an IANA time zone (`Europe/Rome`). Flights store both ends. Never store "naked" times without a zone. Display in the item's own local time; label the zone when it differs from the previous item.
- **Unconfirmed times are normal:** `time_precision` is `exact`, `approx`, `part_of_day` or `none`. Show "Afternoon" or "Time TBC", never a fake 00:00.
- **One-handed use:** main actions in the bottom third of the screen, touch targets at least 44px, no sideways scrolling.
- **Display:** Australian English, `19 Oct 26` dates, 24-hour times (proposed), °C, km.

## Supabase rules
- **Row Level Security on every table**, no exceptions. Access is by `trip_members`.
- Schema changes only as numbered SQL files in `supabase/migrations/`. Never edit a table by hand in the dashboard without writing the migration.
- Every row has a `uuid` id (made on the phone so offline adds work), `created_at`, `updated_at`, `updated_by` and `deleted_at` (soft delete, so deletes sync).
- The Supabase URL and anon key may go in the code (they're public by design, RLS protects the data). The service-role key never goes in the repo or the app.
- **Free tier watch:** 500 MB database, 1 GB file storage, free projects pause after 7 days unused (restore from the dashboard). Flag anything that would need a paid plan.

## Privacy (the repo and site are public)
- No real itinerary data, hotel names, booking references, flight numbers, names or photos in the repo. Real trip data goes into Supabase only.
- Import files with real data live in `import/private/`, which is git-ignored.
- Test data is made up.

## Folder structure (proposed)
```
travel-app/
  CLAUDE.md  README.md  project.json
  index.html                Vite entry
  public/                   manifest.webmanifest, icons/
  src/
    main.tsx
    app/                    routes, layout, bottom nav
    features/
      auth/                 email-code sign-in
      itinerary/            timeline, day view, item editor, quick add
      meetings/             pinned meeting points
      map/                  today map, offline tile download
      import/               paste-text / JSON import
      sleep/  places/  people/  overview/     (Phase 2)
      photos/  feed/                          (Phase 3)
    lib/
      supabase.ts  db.ts (Dexie)  sync.ts (pull + outbox)
      time.ts (zones, part of day)  geo.ts
    components/             shared UI
    styles/tokens.css       house look tokens
  supabase/
    migrations/             0001_core.sql, ...
    seed.sql                made-up demo trip
  import/
    format.md               the import format
    private/                real trip files (git-ignored)
  tests/  unit/  e2e/
  .github/workflows/pages.yml
```

## Phase plan
Today is 23 Oct 26. Phase 1 must be done by **mid-Jan 27**; departure is Feb 27.

**Phase 1: must work on the trip**
1. Week 1: Supabase project, schema + RLS, email-code sign-in for two users, installable PWA shell on both phones. **Offline-read spike** (iPhone home-screen storage) is now the biggest risk.
2. Weeks 2–3: timeline by day / city / region; add and edit items; unconfirmed times.
3. Week 4: import (pasted structured text or JSON) and load the real trip.
4. Week 5: pinned meeting places and times, visible to both users.
5. Weeks 6–7: "Where we've been" daily log (mark places visited, with a note); online map of the day (stops, hotel, meeting points, visited); offline read cache.
6. Week 8: time-zone polish, install on both phones, flight-mode tests, archive-a-trip.
7. Week 9: field test on a real day out with both phones. Fix list.
8. Weeks 10–12 (Christmas break in here): buffer. **Phase 1 frozen by mid-Jan.**

**Phase 2: only if Phase 1 is working by mid-Dec**
- Sleep planner (target hours per user, latest bedtime from hotel arrival and next start, across zones).
- Favourite restaurants and wishlist on the map.
- Fellow travellers log (records, not accounts).
- Whole-trip overview map.

**Phase 3: during or after the trip**
- Photo upload, matched to day and place by EXIF time (and GPS when the phone keeps it), compressed with thumbnails.
- Shared trip updates feed.

## Working with the owner
- Small steps. Commit and push each working milestone to the session branch; `main` only through a PR the owner merges.
- Offer options with trade-offs; don't make big decisions silently. Say early if scope is slipping.
- Model use per HOUSE-RULES section 3: lead session for data model, sync and time-zone logic; Sonnet subagents for building screens from a spec and Playwright tests; Haiku for sweeps and checks.
