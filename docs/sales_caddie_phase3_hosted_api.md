# Sales Caddie Phase 3 Hosted API

Phase 3 moves Sales Caddie from "desktop app writes to Supabase" toward:

```text
Sales Caddie desktop -> Sales Caddie Cloud API -> Supabase
```

## Why This Matters

Direct desktop-to-Supabase sync is fine for an internal pilot. Enterprise customers need a controlled server boundary:

- no Supabase service keys in desktop builds
- centralized auth and workspace enforcement
- validation before data hits the database
- audit logging and retention policy hooks
- a clean place for CRM/calendar/dialer integrations
- future SSO/SAML without rewriting desktop sync logic

## What Was Added

The `api/` package is a minimal Node 20 service with:

- bearer-token protected routes
- workspace/member/app-install resolution
- server-side Supabase REST client
- org identity endpoint
- admin member management with role checks
- admin invite creation and public invite redemption
- meeting sync
- call insight sync
- agent/Jessica event sync
- sales library fetch and sync
- audit event writes for admin member changes
- tests that run without a real Supabase project

## Current Auth Model

For the first internal pass, requests use:

```http
Authorization: Bearer <SALES_CADDIE_API_TOKEN>
```

And identity headers:

```http
x-sales-caddie-workspace: skriber-sales
x-sales-caddie-user-email: rep@example.com
x-sales-caddie-install-key: desktop-install-id
```

This is intentionally simple. The next enterprise auth step is replacing the shared API token with short-lived device/user tokens minted after sign-in.

## Org Admin Layer

The hosted API now has the first workable org-management surface:

```text
GET  /v1/me
GET  /v1/admin/members
POST /v1/admin/members
POST /v1/admin/invites
GET  /join?token=...
POST /v1/invites/redeem
```

`/v1/me` returns the current workspace, current member, and effective permissions. The admin member routes let an owner/admin add reps, managers, admins, CRM/GHL IDs, calendar emails, active status, manager mappings, and feature-level permissions. Admin changes write an `audit_events` row.

The invite route turns "add this rep" into a real onboarding path: it creates a pending inactive member, stores only a hashed setup token, returns a download link plus an email-ready subject/body, and exposes a public `/join` page where the invitee can download Sales Caddie and copy the setup code. `POST /v1/invites/redeem` exchanges a valid token for the workspace/cloud config used by the desktop app.

For bootstrap, set:

```text
SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS=owner@example.com,admin@example.com
```

Those emails can manage members even before their Supabase role has been corrected. This should be treated as a setup bridge, not long-term auth.

## Production Hardening Still Needed

- Replace shared API token with user/device auth.
- Add per-workspace rate limits.
- Extend audit writes to all sensitive actions.
- Enforce workspace policy for transcript retention and private meetings.
- Add request IDs and structured logging.
- Add API deployment config and health checks.
- Add desktop API client and keep direct Supabase only as dev fallback.
