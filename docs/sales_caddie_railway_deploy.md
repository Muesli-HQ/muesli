# Sales Caddie Cloud API Railway Deploy

Railway project:

```text
loving-charisma
```

Railway service:

```text
sales-caddie-api
```

Public URL:

```text
https://sales-caddie-api-production.up.railway.app
```

Health check:

```bash
curl https://sales-caddie-api-production.up.railway.app/health
```

Expected:

```json
{"ok":true,"service":"sales-caddie-cloud-api"}
```

## Configured

- `SALES_CADDIE_API_TOKEN`
- `SUPABASE_URL`
- `SALES_CADDIE_AUTO_CREATE_WORKSPACES=true`
- `SALES_CADDIE_AUTO_CREATE_MEMBERS=true`
- `NODE_ENV=production`
- `PORT=8787`

The local Sales Caddie Dev config has the API URL and token stored, but `sales_caddie_cloud_sync_enabled` is still `false` until the service-role key and schema are ready.

## Still Required

Add this Railway variable to `sales-caddie-api`:

```text
SUPABASE_SERVICE_ROLE_KEY=<Sales Caddie Supabase service-role key>
```

Then run:

```text
docs/sales_caddie_multi_tenant_schema.sql
```

against the same Sales Caddie Supabase project.

After that, protected API routes such as `/v1/app-installs/heartbeat`, `/v1/meetings/sync`, `/v1/library-items`, `/v1/call-insights`, and `/v1/agent-events` can write through the hosted API.
