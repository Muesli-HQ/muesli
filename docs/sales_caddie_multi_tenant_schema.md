# Sales Caddie Multi-Tenant Cloud Schema

This is the product-grade Supabase shape for selling Sales Caddie outside Skriber.

The intended architecture is:

`Sales Caddie desktop app -> Sales Caddie hosted API -> Supabase`

For the sellable version, customers should not connect their own Supabase projects. Sales Caddie should own one managed cloud database, with every customer isolated by `workspace_id`.

## Core Principles

- Every customer/company is a `workspace`.
- Every user belongs to one or more workspaces through `workspace_members`.
- Every operational table carries `workspace_id`.
- The desktop app has an `app_install_id` so we can track devices without exposing machine names.
- Supabase Auth can power the admin portal, while the hosted API can use service-role credentials server-side.
- RLS should still exist as a defense layer and for direct admin-portal reads.
- Raw audio is not stored by default. Transcripts, summaries, insights, and agent events are stored.

## Main Objects

- `workspaces`: customer companies.
- `workspace_members`: users, roles, rep identity, manager relationships.
- `app_installs`: desktop installs/devices.
- `customers`: customer/account records discovered from calls, CRM, calendar, or manual entry.
- `meetings`: call/meeting records.
- `transcript_chunks`: live or post-call transcript segments.
- `agent_events`: Jessica/Sales Agent command history.
- `library_items`: shared KB, objections, battlecards, buying signals, discovery questions, talk tracks.
- `call_insights`: structured moments detected during calls.
- `call_suggestions`: prompts shown to reps during calls.
- `suggestion_feedback`: whether a suggestion was useful, ignored, wrong, etc.
- `manager_alerts`: churn, upsell, escalation, coaching, and follow-up alerts.
- `tasks`: follow-up actions for reps/managers.
- `integration_connections`: CRM/calendar/dialer/meeting tool connection metadata.
- `audit_events`: admin and sensitive workflow audit log.

## Role Model

Suggested roles:

- `owner`: owns billing and all admin settings.
- `admin`: manages users, libraries, integrations, retention, and policies.
- `manager`: sees team calls, insights, coaching, alerts.
- `rep`: sees their own calls, suggestions, history, and approved shared library.
- `viewer`: read-only manager/admin style access.

## Data Isolation

All workspace-owned rows use:

```sql
workspace_id uuid not null references sales_app.workspaces(id)
```

RLS checks membership through:

```sql
sales_app.is_workspace_member(workspace_id)
sales_app.has_workspace_role(workspace_id, array['owner', 'admin'])
```

For the hosted API, it is still fine to use a service-role key server-side, but direct browser/admin portal access should rely on Supabase Auth and RLS.

## Rollout Path

1. Keep current local-first sync working for Skriber.
2. Add this schema to a new migration when building the hosted product.
3. Build a hosted API that validates user/workspace/app install before writing.
4. Move desktop config from "Supabase URL + anon key" to "Sign in to Sales Caddie Cloud".
5. Add admin portal for workspace settings, library management, users, alerts, and reporting.

