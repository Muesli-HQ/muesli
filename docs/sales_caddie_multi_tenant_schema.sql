create schema if not exists sales_app;

create extension if not exists pgcrypto;

create or replace function sales_app.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create table if not exists sales_app.workspaces (
    id uuid primary key default gen_random_uuid(),
    slug text not null unique,
    name text not null,
    plan text not null default 'trial',
    billing_status text not null default 'trialing',
    stripe_customer_id text,
    stripe_subscription_id text,
    default_retention_days integer not null default 365,
    recording_enabled boolean not null default false,
    transcript_enabled boolean not null default true,
    ai_assist_enabled boolean not null default true,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists sales_app.workspace_members (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    auth_user_id uuid references auth.users(id) on delete set null,
    email text not null,
    display_name text,
    role text not null default 'rep'
        check (role in ('owner', 'admin', 'manager', 'rep', 'viewer')),
    manager_member_id uuid references sales_app.workspace_members(id) on delete set null,
    is_active boolean not null default true,
    crm_user_id text,
    ghl_user_id text,
    calendar_email text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (workspace_id, email)
);

create index if not exists workspace_members_auth_user_idx
    on sales_app.workspace_members (auth_user_id)
    where auth_user_id is not null;

create index if not exists workspace_members_workspace_role_idx
    on sales_app.workspace_members (workspace_id, role, is_active);

create or replace function sales_app.is_workspace_member(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = sales_app, public
as $$
    select exists (
        select 1
        from sales_app.workspace_members wm
        where wm.workspace_id = p_workspace_id
          and wm.auth_user_id = auth.uid()
          and wm.is_active = true
    );
$$;

create or replace function sales_app.has_workspace_role(p_workspace_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = sales_app, public
as $$
    select exists (
        select 1
        from sales_app.workspace_members wm
        where wm.workspace_id = p_workspace_id
          and wm.auth_user_id = auth.uid()
          and wm.is_active = true
          and wm.role = any (p_roles)
    );
$$;

create table if not exists sales_app.app_installs (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    member_id uuid references sales_app.workspace_members(id) on delete set null,
    install_key text not null,
    app_version text,
    platform text not null default 'macos',
    last_seen_at timestamptz,
    revoked_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (workspace_id, install_key)
);

create index if not exists app_installs_workspace_member_idx
    on sales_app.app_installs (workspace_id, member_id);

create table if not exists sales_app.customers (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    owner_member_id uuid references sales_app.workspace_members(id) on delete set null,
    external_crm_id text,
    name text,
    company text,
    email text,
    phone text,
    status text,
    lifecycle_stage text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists customers_workspace_external_crm_unique_idx
    on sales_app.customers (workspace_id, external_crm_id)
    where external_crm_id is not null;

create index if not exists customers_workspace_email_idx
    on sales_app.customers (workspace_id, lower(email))
    where email is not null;

create table if not exists sales_app.meetings (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    customer_id uuid references sales_app.customers(id) on delete set null,
    rep_member_id uuid references sales_app.workspace_members(id) on delete set null,
    app_install_id uuid references sales_app.app_installs(id) on delete set null,
    external_calendar_event_id text,
    external_meeting_id text,
    title text,
    meeting_url text,
    source text,
    recording_status text not null default 'not_recorded',
    transcript_status text not null default 'pending',
    summary text,
    started_at timestamptz,
    ended_at timestamptz,
    duration_seconds integer,
    is_private boolean not null default false,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists meetings_workspace_calendar_unique_idx
    on sales_app.meetings (workspace_id, external_calendar_event_id)
    where external_calendar_event_id is not null;

create index if not exists meetings_workspace_started_idx
    on sales_app.meetings (workspace_id, started_at desc);

create index if not exists meetings_rep_started_idx
    on sales_app.meetings (rep_member_id, started_at desc);

create table if not exists sales_app.transcript_chunks (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    meeting_id uuid not null references sales_app.meetings(id) on delete cascade,
    speaker_label text,
    speaker_member_id uuid references sales_app.workspace_members(id) on delete set null,
    sequence_number integer not null,
    started_at_seconds numeric,
    ended_at_seconds numeric,
    text text not null,
    is_final boolean not null default true,
    confidence numeric,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    unique (meeting_id, sequence_number)
);

create index if not exists transcript_chunks_meeting_sequence_idx
    on sales_app.transcript_chunks (meeting_id, sequence_number);

create table if not exists sales_app.agent_events (
    id uuid primary key,
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    member_id uuid references sales_app.workspace_members(id) on delete set null,
    app_install_id uuid references sales_app.app_installs(id) on delete set null,
    meeting_id uuid references sales_app.meetings(id) on delete set null,
    provider text not null,
    status text not null,
    transcript text not null,
    response text not null,
    planner_command text,
    action_type text,
    action_status text,
    source_app text not null default 'Sales Caddie',
    metadata jsonb not null default '{}'::jsonb,
    client_created_at timestamptz not null,
    created_at timestamptz not null default now()
);

create index if not exists agent_events_workspace_created_idx
    on sales_app.agent_events (workspace_id, client_created_at desc);

create index if not exists agent_events_member_created_idx
    on sales_app.agent_events (member_id, client_created_at desc);

create table if not exists sales_app.library_items (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    created_by_member_id uuid references sales_app.workspace_members(id) on delete set null,
    kind text not null
        check (kind in (
            'knowledge_base',
            'objection',
            'battlecard',
            'buying_signal',
            'competitor',
            'close',
            'discovery',
            'discovery_question',
            'pricing',
            'talk_ratio',
            'talk_track',
            'process_rule'
        )),
    name text not null,
    competitor text,
    content text not null default '',
    trigger_phrases text[] not null default '{}'::text[],
    guidance text not null default '',
    priority integer not null default 0,
    is_enabled boolean not null default true,
    version integer not null default 1,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists library_items_workspace_kind_idx
    on sales_app.library_items (workspace_id, kind, is_enabled, priority desc);

create table if not exists sales_app.call_insights (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    meeting_id uuid references sales_app.meetings(id) on delete cascade,
    rep_member_id uuid references sales_app.workspace_members(id) on delete set null,
    library_item_id uuid references sales_app.library_items(id) on delete set null,
    kind text not null,
    name text not null,
    evidence text,
    guidance text,
    confidence numeric,
    timestamp_seconds integer,
    severity text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists call_insights_workspace_created_idx
    on sales_app.call_insights (workspace_id, created_at desc);

create index if not exists call_insights_meeting_idx
    on sales_app.call_insights (meeting_id, timestamp_seconds);

create table if not exists sales_app.call_suggestions (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    meeting_id uuid references sales_app.meetings(id) on delete cascade,
    rep_member_id uuid references sales_app.workspace_members(id) on delete set null,
    insight_id uuid references sales_app.call_insights(id) on delete set null,
    library_item_id uuid references sales_app.library_items(id) on delete set null,
    shown_at_seconds integer,
    title text not null,
    body text not null,
    status text not null default 'shown'
        check (status in ('queued', 'shown', 'dismissed', 'accepted', 'expired')),
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists call_suggestions_meeting_idx
    on sales_app.call_suggestions (meeting_id, shown_at_seconds);

create table if not exists sales_app.suggestion_feedback (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    suggestion_id uuid not null references sales_app.call_suggestions(id) on delete cascade,
    member_id uuid references sales_app.workspace_members(id) on delete set null,
    rating text not null
        check (rating in ('useful', 'not_useful', 'wrong', 'missed_context', 'too_late')),
    note text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create table if not exists sales_app.manager_alerts (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    customer_id uuid references sales_app.customers(id) on delete set null,
    meeting_id uuid references sales_app.meetings(id) on delete set null,
    rep_member_id uuid references sales_app.workspace_members(id) on delete set null,
    assigned_member_id uuid references sales_app.workspace_members(id) on delete set null,
    kind text not null,
    title text not null,
    body text,
    status text not null default 'open'
        check (status in ('open', 'acknowledged', 'resolved', 'dismissed')),
    severity text not null default 'medium'
        check (severity in ('low', 'medium', 'high', 'urgent')),
    due_at timestamptz,
    resolved_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists manager_alerts_workspace_status_idx
    on sales_app.manager_alerts (workspace_id, status, created_at desc);

create table if not exists sales_app.tasks (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    customer_id uuid references sales_app.customers(id) on delete set null,
    meeting_id uuid references sales_app.meetings(id) on delete set null,
    assigned_member_id uuid references sales_app.workspace_members(id) on delete set null,
    created_by_member_id uuid references sales_app.workspace_members(id) on delete set null,
    title text not null,
    body text,
    status text not null default 'open'
        check (status in ('open', 'in_progress', 'done', 'dismissed')),
    due_at timestamptz,
    completed_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists tasks_workspace_status_idx
    on sales_app.tasks (workspace_id, status, due_at);

create table if not exists sales_app.integration_connections (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references sales_app.workspaces(id) on delete cascade,
    provider text not null,
    display_name text,
    status text not null default 'active'
        check (status in ('active', 'disabled', 'error')),
    external_account_id text,
    connected_by_member_id uuid references sales_app.workspace_members(id) on delete set null,
    credentials_ref text,
    last_synced_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (workspace_id, provider, external_account_id)
);

create table if not exists sales_app.audit_events (
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid references sales_app.workspaces(id) on delete cascade,
    actor_member_id uuid references sales_app.workspace_members(id) on delete set null,
    actor_auth_user_id uuid references auth.users(id) on delete set null,
    action text not null,
    target_table text,
    target_id uuid,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists audit_events_workspace_created_idx
    on sales_app.audit_events (workspace_id, created_at desc);

do $$
declare
    v_table_name text;
begin
    foreach v_table_name in array array[
        'workspaces',
        'workspace_members',
        'app_installs',
        'customers',
        'meetings',
        'transcript_chunks',
        'agent_events',
        'library_items',
        'call_insights',
        'call_suggestions',
        'suggestion_feedback',
        'manager_alerts',
        'tasks',
        'integration_connections',
        'audit_events'
    ] loop
        execute format('drop trigger if exists set_updated_at on sales_app.%I', v_table_name);
        if exists (
            select 1
            from information_schema.columns
            where table_schema = 'sales_app'
              and table_name = v_table_name
              and column_name = 'updated_at'
        ) then
            execute format(
                'create trigger set_updated_at before update on sales_app.%I for each row execute function sales_app.set_updated_at()',
                v_table_name
            );
        end if;
    end loop;
end $$;

grant usage on schema sales_app to authenticated, service_role;
grant select, insert, update, delete on all tables in schema sales_app to authenticated, service_role;
grant usage, select on all sequences in schema sales_app to service_role;
alter default privileges in schema sales_app
    grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema sales_app
    grant select, insert, update, delete on tables to service_role;
alter default privileges in schema sales_app
    grant usage, select on sequences to service_role;

do $$
declare
    table_name text;
begin
    foreach table_name in array array[
        'workspaces',
        'workspace_members',
        'app_installs',
        'customers',
        'meetings',
        'transcript_chunks',
        'agent_events',
        'library_items',
        'call_insights',
        'call_suggestions',
        'suggestion_feedback',
        'manager_alerts',
        'tasks',
        'integration_connections',
        'audit_events'
    ] loop
        execute format('alter table sales_app.%I enable row level security', table_name);
    end loop;
end $$;

drop policy if exists workspaces_member_select on sales_app.workspaces;
create policy workspaces_member_select
    on sales_app.workspaces
    for select
    to authenticated
    using (sales_app.is_workspace_member(id));

drop policy if exists workspaces_admin_update on sales_app.workspaces;
create policy workspaces_admin_update
    on sales_app.workspaces
    for update
    to authenticated
    using (sales_app.has_workspace_role(id, array['owner', 'admin']))
    with check (sales_app.has_workspace_role(id, array['owner', 'admin']));

drop policy if exists workspace_members_member_select on sales_app.workspace_members;
create policy workspace_members_member_select
    on sales_app.workspace_members
    for select
    to authenticated
    using (sales_app.is_workspace_member(workspace_id));

drop policy if exists workspace_members_admin_write on sales_app.workspace_members;
create policy workspace_members_admin_write
    on sales_app.workspace_members
    for all
    to authenticated
    using (sales_app.has_workspace_role(workspace_id, array['owner', 'admin']))
    with check (sales_app.has_workspace_role(workspace_id, array['owner', 'admin']));

do $$
declare
    table_name text;
begin
    foreach table_name in array array[
        'app_installs',
        'customers',
        'meetings',
        'transcript_chunks',
        'agent_events',
        'library_items',
        'call_insights',
        'call_suggestions',
        'suggestion_feedback',
        'manager_alerts',
        'tasks',
        'integration_connections',
        'audit_events'
    ] loop
        execute format('drop policy if exists %I on sales_app.%I', table_name || '_workspace_select', table_name);
        execute format('drop policy if exists %I on sales_app.%I', table_name || '_workspace_insert', table_name);
        execute format('drop policy if exists %I on sales_app.%I', table_name || '_workspace_update', table_name);
        execute format('drop policy if exists %I on sales_app.%I', table_name || '_workspace_delete', table_name);

        execute format(
            'create policy %I on sales_app.%I for select to authenticated using (sales_app.is_workspace_member(workspace_id))',
            table_name || '_workspace_select',
            table_name
        );
        execute format(
            'create policy %I on sales_app.%I for insert to authenticated with check (sales_app.is_workspace_member(workspace_id))',
            table_name || '_workspace_insert',
            table_name
        );
        execute format(
            'create policy %I on sales_app.%I for update to authenticated using (sales_app.is_workspace_member(workspace_id)) with check (sales_app.is_workspace_member(workspace_id))',
            table_name || '_workspace_update',
            table_name
        );
        execute format(
            'create policy %I on sales_app.%I for delete to authenticated using (sales_app.has_workspace_role(workspace_id, array[''owner'', ''admin'']))',
            table_name || '_workspace_delete',
            table_name
        );
    end loop;
end $$;

-- Hosted API note:
-- The product API can use a service-role key on the server after validating the
-- caller, workspace, and app install. Never ship a service-role key in the
-- desktop app. Direct Supabase access should use authenticated users plus RLS.
