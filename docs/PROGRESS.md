# Implementation ledger — LARP Studio

Plan: `docs/superpowers/plans/2026-10-25-workshop.md`.
User specification explicitly requests immediate implementation; no approval pause.
Cloud checkout is already isolated; no worktree created. Initial branch `work` is unborn.
Pre-flight: storage returns plain dictionaries consumed by packages/export/Qt.
Package import restores explicit record IDs and code reservations through transaction.

Task 1: complete — `pytest tests/test_project.py -q`: 18 passed.
Task 2: complete — 34 storage/export/package tests passed before GUI work.
Task 3: complete — 42 tests including clicked GUI workflow and WAV decoding passed.
Task 4: complete — repeatable install, pip check, Qt startup, Linux packaged
startup (with an existing game), source docs and Windows CI configuration.
Environment draft saved install_script/start_skill; metadata named LARP Studio.
Publication/restoration and Windows CI execution are not verified.

Final review: independent read-only reviewer; three Important findings and one
minor found. Integer overflow was regraded Important because bad input escaped
the GUI error handler. All addressed in one regression pass; 60 tests passed.
- Commit error: previous package restored and version/history rolled back.
- Windows aliases/device names/ADS rejected before extraction.
- Existing content-addressed media checked before reuse.
- Persisted integers bounded and version exhaustion reported.
- Additional self-review: never delete a concurrently created target folder;
  symlinked media cannot write outside project. Regression tests RED→GREEN.

No deferred review findings. Windows execution, codecs and EXE validation remain
explicit platform limitations, not claimed as verified. Mobile/server are deferred
per user scope. Source, docs and CI reviewed; no remote publication performed.

## Browser delivery — superseding user choice

User explicitly selected permanent browser link, no installation; later Codex
changes must preserve game data. Browser app built under web/ with IndexedDB.
No EXE work is required for this selected delivery. Original Python source retained.
12 Node tests, 10 real browser acceptance checks, 2 browser regression checks.
Independent review: three Important issues reproduced with RED tests before fixes:
Enter paragraphs, pending media/text edits, export/import size-limit consistency.
Compatibility checked: Python reads/imports browser .rpgpack; openpyxl reads
browser Excel and pypdf reads browser PDF with default spoiler hiding.
Production npm audit: 0 vulnerabilities after dependency updates.
Deployment: source pushed to main, commit 6e813a8. GitHub run 40191908509 passed
installation, Node tests, build and both browser suites; Configure Pages failed
with Create Pages site / Resource not accessible by integration (403), including
the workflow's GITHUB_TOKEN. User asked asynchronously to enable Settings > Pages
> Source: GitHub Actions. No site availability claim until actual HTTPS check.
Manual desktop workflow's invalid runner context in job env corrected to a local
settings directory; no desktop runtime or functionality changed.

Deployment completed after user enabled Source: GitHub Actions. Run 40194144453:
build and deploy success. Public site https://mgoutside16-spec.github.io/larp/
returns HTTP 200. Real published assets passed create/save/reload and downloads
for XLSX/PDF/.rpgpack in a fresh browser context; no JS errors/failed requests.
TLS verification preserved via system-trusted urllib transport for cloud browser
requests (its private trust store lacks the environment proxy CA).


## Accounts and shared browser workshop — version 0.3

User paused Android work. Confirmed Supabase schema/update and Site URL setup.
Preapproved administrator mgoutside16@gmail.com requires verified email.
Account login/cabinet, global admin/master roles, project sharing with pending
invites, server RLS/CAS, private media, project-specific groups and saved image
printing implemented. Original local database preserved for explicit admin import.
Sidebar contains supplied «Без правил» emblem; example card rasterized directly
from supplied PDF. Export: per-code PNG ZIP, source resolution, 300 dpi.

Independent read-only review: isolated proposal database prevents shared-cache
refresh from losing a saved edit; busy print export survives background polling;
long codes fit large font, registration name retained, group errors localized.
Each reproduced before fixing. Also covered revoked/deleted selected project.
Final checks: 26 Node tests, 158 real PostgreSQL assertions, browser suites
10 acceptance / 2 editor regressions / 8 account scenarios / 5 review regressions.
Multipart browser fixture now receives actual File/Blob bytes over loopback HTTP:
Chromium intercepted postData omitted file-backed data; checksum export correctly
rejected those empty test uploads. Production SDK/upload code unchanged.
Real backend denies anonymous table/identity RPC access (401/42501). No actual
user password or auth email used in tests; owner completes registration himself.
Updated reusable cloud setup/start instructions saved to configuration draft.
Publication of final source is verified separately below.


Version 0.3 deployed from main commit 0c45794 by GitHub run 40202136444.
policies/build/deploy all success. Actual published HTTPS responses verified
in Chromium via system-trusted urllib transport: login/password, inaccessible
projects before sign-in, logo, registration name/email/password, seven HTTP 200
responses and zero uncaught JS errors. No real account/email created by agent.
Working tree clean after documentation commit.
