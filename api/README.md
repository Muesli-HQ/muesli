# Sales Caddie Cloud API

Phase 3 hosted API bridge for Sales Caddie.

The desktop app should eventually call this API instead of writing directly to Supabase. The API owns:

- API token authentication
- workspace/member/app install resolution
- server-side Supabase service-role writes
- validation and normalization
- a future place for SSO, audit logging, rate limits, retention policy, and integration fan-out

## Environment

```text
PORT=8787
SALES_CADDIE_API_TOKEN=internal-shared-token
SUPABASE_URL=https://project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
SALES_CADDIE_AUTO_CREATE_WORKSPACES=false
SALES_CADDIE_AUTO_CREATE_MEMBERS=false
SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS=owner@example.com,admin@example.com
SALES_CADDIE_PUBLIC_API_URL=https://sales-caddie-api-production.up.railway.app
SALES_CADDIE_INVITE_BASE_URL=https://sales-caddie-api-production.up.railway.app
SALES_CADDIE_DOWNLOAD_URL=https://freedspeech.xyz/download/
SALES_CADDIE_INVITE_TTL_HOURS=168
```

For internal bootstrap you can set the two auto-create flags to `true`. For customer deployments, pre-create workspaces and members.

`SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS` is an initial setup bridge. Those emails can use the admin member routes even if their current `workspace_members.role` is still `rep`. Once the right owners/admins are saved in Supabase, keep this list short or remove it.

## Required Headers

Every protected request needs:

```http
Authorization: Bearer <SALES_CADDIE_API_TOKEN>
x-sales-caddie-workspace: skriber-sales
x-sales-caddie-user-email: rep@example.com
x-sales-caddie-install-key: desktop-install-id
```

Optional:

```http
x-sales-caddie-user-name: Rep Name
x-sales-caddie-version: 0.1.0
```

## Routes

```text
GET  /health
GET  /join?token=<invite-token>
POST /v1/invites/redeem
GET  /v1/me
POST /v1/app-installs/heartbeat
GET  /v1/admin/members
POST /v1/admin/members
POST /v1/admin/invites
GET  /v1/library-items
POST /v1/library-items/sync
POST /v1/meetings/sync
POST /v1/call-insights
POST /v1/agent-events
```

### Admin Members

`GET /v1/me` returns the resolved workspace, current member, and effective permissions. Use it to decide what admin UI to show.

`GET /v1/admin/members` lists members in the current workspace. `POST /v1/admin/members` upserts one member or a `members[]` array:

```json
{
  "members": [
    {
      "email": "rep@example.com",
      "display_name": "Rep Name",
      "role": "rep",
      "manager_member_id": null,
      "is_active": true,
      "crm_user_id": "crm-123",
      "ghl_user_id": "ghl-123",
      "calendar_email": "rep@example.com",
      "permissions": {
        "can_record_meetings": false,
        "can_sync_meetings": true,
        "can_use_ai_assist": true,
        "can_use_sales_agent": true,
        "can_use_computer_control": false,
        "can_manage_private_notes": true
      }
    }
  ]
}
```

Allowed roles are `owner`, `admin`, `manager`, `rep`, and `viewer`. Admin writes are audit-logged to `audit_events`.

### Invites

`POST /v1/admin/invites` creates or updates a pending workspace member, stores a hashed invite token in that member's metadata, and returns an email-ready invite:

```json
{
  "email": "rep@example.com",
  "display_name": "Rep Name",
  "role": "rep",
  "permissions": {
    "can_sync_meetings": true,
    "can_use_sales_agent": true
  }
}
```

The response includes:

- `invite_url`: a public `/join?token=...` page with download instructions.
- `download_url`: the configured Sales Caddie download URL.
- `email.subject`, `email.body`, and `email.mailto_url`.

The desktop app can redeem the token through `POST /v1/invites/redeem` without the shared bearer token. For the internal pilot this returns the Sales Caddie Cloud config needed to join the workspace. The enterprise version should replace this with user/device tokens minted after Google OAuth or SSO.

## Local Run

```bash
cd api
npm test
npm start
```

## Notes

This API targets the product-grade tables in `docs/sales_caddie_multi_tenant_schema.sql`:

- `workspaces`
- `workspace_members`
- `app_installs`
- `meetings`
- `library_items`
- `call_insights`
- `agent_events`
- `audit_events`

The current desktop direct-Supabase sync remains useful as an internal/dev fallback while this API is rolled into the app.
