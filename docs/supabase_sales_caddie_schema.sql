create schema if not exists sales_app;

create table if not exists sales_app.sales_caddie_agent_events (
    id uuid primary key,
    workspace_id text not null,
    app_install_id text not null,
    user_id text,
    provider text not null,
    status text not null,
    transcript text not null,
    response text not null,
    planner_command text,
    source_app text not null default 'Sales Caddie',
    metadata jsonb not null default '{}'::jsonb,
    client_created_at timestamptz not null,
    created_at timestamptz not null default now()
);

create index if not exists sales_caddie_agent_events_workspace_created_idx
    on sales_app.sales_caddie_agent_events (workspace_id, client_created_at desc);

create table if not exists sales_app.sales_caddie_meetings (
    id uuid primary key default gen_random_uuid(),
    workspace_id text not null,
    local_id text,
    app_install_id text,
    user_id text,
    title text,
    source text,
    transcript text,
    summary text,
    started_at timestamptz,
    ended_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists sales_caddie_meetings_local_unique_idx
    on sales_app.sales_caddie_meetings (workspace_id, app_install_id, local_id)
    where local_id is not null;

create index if not exists sales_caddie_meetings_workspace_started_idx
    on sales_app.sales_caddie_meetings (workspace_id, started_at desc);

create table if not exists sales_app.sales_caddie_library_items (
    id uuid primary key default gen_random_uuid(),
    workspace_id text not null,
    kind text not null,
    name text not null,
    content text not null default '',
    trigger_phrases text[] not null default '{}'::text[],
    guidance text not null default '',
    priority integer not null default 0,
    is_enabled boolean not null default true,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists sales_caddie_library_items_workspace_kind_idx
    on sales_app.sales_caddie_library_items (workspace_id, kind, is_enabled);

create table if not exists sales_app.sales_caddie_call_insights (
    id uuid primary key default gen_random_uuid(),
    workspace_id text not null,
    meeting_id uuid references sales_app.sales_caddie_meetings(id) on delete set null,
    app_install_id text,
    user_id text,
    kind text not null,
    name text not null,
    evidence text,
    guidance text,
    confidence numeric,
    timestamp_seconds integer,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists sales_caddie_call_insights_workspace_created_idx
    on sales_app.sales_caddie_call_insights (workspace_id, created_at desc);

create table if not exists sales_app.sales_caddie_sync_state (
    workspace_id text not null,
    app_install_id text not null,
    sync_key text not null,
    cursor_value text,
    last_synced_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    primary key (workspace_id, app_install_id, sync_key)
);

grant usage on schema sales_app to anon, authenticated;
grant select, insert, update on all tables in schema sales_app to anon, authenticated;
alter default privileges in schema sales_app
    grant select, insert, update on tables to anon, authenticated;

do $$
declare
    table_name text;
begin
    foreach table_name in array array[
        'sales_caddie_agent_events',
        'sales_caddie_meetings',
        'sales_caddie_library_items',
        'sales_caddie_call_insights',
        'sales_caddie_sync_state'
    ] loop
        execute format('alter table sales_app.%I enable row level security', table_name);

        execute format('drop policy if exists sales_caddie_desktop_select on sales_app.%I', table_name);
        execute format('drop policy if exists sales_caddie_desktop_insert on sales_app.%I', table_name);
        execute format('drop policy if exists sales_caddie_desktop_update on sales_app.%I', table_name);

        execute format(
            'create policy sales_caddie_desktop_select on sales_app.%I for select to anon, authenticated using (true)',
            table_name
        );
        execute format(
            'create policy sales_caddie_desktop_insert on sales_app.%I for insert to anon, authenticated with check (true)',
            table_name
        );
        execute format(
            'create policy sales_caddie_desktop_update on sales_app.%I for update to anon, authenticated using (true) with check (true)',
            table_name
        );
    end loop;
end $$;

-- Production note:
-- These starter policies are permissive so the local desktop app can sync with an
-- anon key during internal testing. Tighten them by workspace/user before a broad
-- team rollout. The desktop app should never store a service-role key.
