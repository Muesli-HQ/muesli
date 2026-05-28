# Sales Caddie Supabase Sync

Sales Caddie remains local-first. Realtime call assist, transcription, overlay prompts, and Jessica commands should keep working even if Supabase is offline. Supabase is the durable team layer for artifacts that should survive a laptop, feed manager dashboards, or be visible in the Sales CRM.

## What Syncs First

- `sales_caddie_agent_events`: Jessica/Sales Agent command history, including transcript, response, provider, status, optional local action, and app install metadata.
- `sales_caddie_library_items`: shared Sales Assist library records for the knowledge base, objections, battlecards, discovery prompts, buying signals, pricing cues, close prompts, and talk-time nudges.
- `sales_caddie_meetings`: completed meeting records, including local meeting ID, title, transcript, summary, start/end timestamps, status, source, template info, and manual notes in metadata.
- `sales_caddie_call_insights`: live Sales Assist moments shown during calls, including objection/buying-signal kind, evidence quote, suggested talk track, priority, local meeting ID, app install, and user metadata.

The app settings still include staged toggles for future syncs:

- call insights captured during live calls

## Meeting And Insight Sync

When Settings -> Sales -> Supabase Sync -> Transcripts is enabled, the app syncs the latest completed meeting records into:

`sales_app.sales_caddie_meetings`

The local app remains the source of truth for the recording and editable transcript. Supabase receives the text artifacts and metadata needed for dashboards and later CRM/customer views. Raw audio is not uploaded.

Sales Assist overlay moments sync into:

`sales_app.sales_caddie_call_insights`

Those insight rows are appended as coaching events. They currently reference the local meeting ID in `metadata.local_meeting_id`; a later hosted API can attach them to durable cloud meeting/customer IDs.

## Sales Library Sync

When Settings -> Sales -> Supabase Sync -> Sales library is enabled, the app fetches enabled rows from:

`sales_app.sales_caddie_library_items`

Rows are mapped into the local Sales Assist library:

- `kind = knowledge_base` becomes the Sales Assist knowledge base text.
- `kind = objection` becomes objection cards.
- `kind = competitor` or `battlecard` becomes battlecards.
- other supported cue kinds map directly: `buying_signal`, `discovery`, `pricing`, `close`, and `talk_ratio`.

If the shared table is empty, the app seeds it from the current local library. After a remote library is pulled, the app marks the library as admin-managed and stores `sales_assist_admin_library_updated_at` in local config.

## Desktop Configuration

Settings -> Sales -> Supabase Sync:

- Enable sync
- Supabase URL, for example `https://project.supabase.co`
- Supabase anon key
- Workspace, for example `skriber-sales`
- Optional user/rep ID

Use a Supabase anon key with Row Level Security policies for production users. Do not put a service-role key into the desktop app.

## Migration

Run `docs/supabase_sales_caddie_schema.sql` in Supabase SQL Editor. It creates the `sales_app` schema tables that Sales Caddie expects.

In Supabase Data API settings, expose the `sales_app` schema. Without that, the app will save its local config but PostgREST calls will fail because only the default schemas are visible.

## Design Notes

- Sales Caddie writes to Supabase with PostgREST using `Accept-Profile: sales_app` and `Content-Profile: sales_app`.
- Sync failures are logged and never block the local app.
- Raw audio is not synced by this layer.
- `app_install_id` identifies a local app install without tying records to a specific machine name.
- The starter SQL uses permissive internal-testing RLS policies for `anon` and `authenticated`. Tighten those policies by workspace/user before rolling sync out broadly.
