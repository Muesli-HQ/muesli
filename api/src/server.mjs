import { createHash, randomBytes } from "node:crypto";
import { SupabaseRestClient } from "./supabaseRest.mjs";
import { requireApiToken } from "./auth.mjs";
import { normalizePriority, normalizeTriggerPhrases, parseJSONBody, requiredString, stableUuid } from "./normalize.mjs";
import { resolveWorkspaceContext } from "./workspaceContext.mjs";

const DEFAULT_PORT = 8787;

export function createApp(env = process.env, fetchImpl = fetch) {
  const supabase = new SupabaseRestClient({
    url: env.SUPABASE_URL,
    serviceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY,
    fetchImpl,
  });
  const options = {
    allowWorkspaceAutoCreate: env.SALES_CADDIE_AUTO_CREATE_WORKSPACES === "true",
    allowMemberAutoCreate: env.SALES_CADDIE_AUTO_CREATE_MEMBERS === "true",
  };

  return async function app(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/health") {
        return json({ ok: true, service: "sales-caddie-cloud-api" });
      }

      if (request.method === "GET" && url.pathname === "/join") {
        const token = url.searchParams.get("token") ?? "";
        return html(inviteLandingPage({ token, downloadURL: downloadURLForInvite(env), apiURL: publicBaseURL(env) }));
      }

      if (request.method === "POST" && url.pathname === "/v1/invites/redeem") {
        const body = await parseJSONBody(request);
        const token = requiredString(body.token, "invite token");
        const tokenHash = tokenSha256(token);
        const rows = await supabase.select("workspace_members", {
          select: "id,workspace_id,email,display_name,role,manager_member_id,is_active,crm_user_id,ghl_user_id,calendar_email,metadata",
          "metadata->invite->>token_hash": `eq.${tokenHash}`,
          limit: "1",
        });
        const member = rows?.[0];
        if (!member) return json({ ok: false, error: "Invite was not found or has expired." }, 404);
        const invite = member.metadata?.invite ?? {};
        if (invite.status === "accepted" || invite.status === "revoked") {
          return json({ ok: false, error: `Invite is ${invite.status}.` }, 409);
        }
        if (invite.expires_at && Date.parse(invite.expires_at) < Date.now()) {
          return json({ ok: false, error: "Invite has expired." }, 410);
        }

        const workspaces = await supabase.select("workspaces", {
          select: "id,slug,name",
          id: `eq.${member.workspace_id}`,
          limit: "1",
        });
        const workspace = workspaces?.[0];
        if (!workspace) return json({ ok: false, error: "Invite workspace was not found." }, 404);

        const acceptedMetadata = {
          ...(member.metadata ?? {}),
          invite: {
            ...invite,
            status: "accepted",
            accepted_at: new Date().toISOString(),
          },
        };
        await supabase.upsert("workspace_members", [
          {
            id: member.id,
            workspace_id: member.workspace_id,
            email: member.email,
            display_name: member.display_name,
            role: member.role,
            manager_member_id: member.manager_member_id,
            is_active: true,
            crm_user_id: member.crm_user_id,
            ghl_user_id: member.ghl_user_id,
            calendar_email: member.calendar_email,
            metadata: acceptedMetadata,
          },
        ], { onConflict: "id" });

        return json({
          ok: true,
          workspace: { id: workspace.id, slug: workspace.slug, name: workspace.name },
          member: publicMember({ ...member, is_active: true, metadata: acceptedMetadata }),
          config: {
            sales_caddie_cloud_sync_enabled: true,
            sales_caddie_cloud_api_url: publicBaseURL(env),
            sales_caddie_cloud_api_token: env.SALES_CADDIE_API_TOKEN,
            sales_caddie_cloud_workspace_slug: workspace.slug,
            supabase_user_id: member.email,
            user_name: member.display_name ?? member.email,
          },
        });
      }

      const auth = requireApiToken(request, env.SALES_CADDIE_API_TOKEN);
      if (!auth.ok) return json({ ok: false, error: auth.error }, auth.status);

      if (request.method === "POST" && url.pathname === "/v1/app-installs/heartbeat") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        return json({ ok: true, workspace_id: context.workspace.id, member_id: context.member.id, app_install_id: context.install.id });
      }

      if (request.method === "GET" && url.pathname === "/v1/me") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        return json({
          ok: true,
          workspace: context.workspace,
          member: publicMember(context.member),
          permissions: workspacePermissions(context, env),
        });
      }

      if (request.method === "GET" && url.pathname === "/v1/admin/members") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        requireWorkspaceAdmin(context, env);
        const rows = await supabase.select("workspace_members", {
          select: "id,email,display_name,role,manager_member_id,is_active,crm_user_id,ghl_user_id,calendar_email,metadata,created_at,updated_at",
          workspace_id: `eq.${context.workspace.id}`,
          order: "is_active.desc,role.asc,display_name.asc,email.asc",
        });
        return json({ ok: true, members: (rows ?? []).map(publicMember) });
      }

      if (request.method === "POST" && url.pathname === "/v1/admin/members") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        requireWorkspaceAdmin(context, env);
        const body = await parseJSONBody(request);
        const members = Array.isArray(body.members) ? body.members : [body.member ?? body];
        const rows = members.filter(Boolean).map((member) => adminMemberRow(member, context));
        if (rows.length > 0) {
          await supabase.upsert("workspace_members", rows, { onConflict: "workspace_id,email", returning: "representation" });
          await writeAuditEvent(supabase, context, "workspace_members.upsert", {
            count: rows.length,
            emails: rows.map((row) => row.email),
          });
        }
        return json({ ok: true, count: rows.length });
      }

      if (request.method === "POST" && url.pathname === "/v1/admin/invites") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        requireWorkspaceAdmin(context, env);
        const body = await parseJSONBody(request);
        const invite = adminInvite(body.member ?? body, context, env);
        const row = adminMemberRow(invite.member, context);
        row.is_active = false;
        row.metadata = {
          ...row.metadata,
          invite: invite.metadata,
        };
        await supabase.upsert("workspace_members", [row], { onConflict: "workspace_id,email", returning: "representation" });
        await writeAuditEvent(supabase, context, "workspace_members.invite", {
          email: row.email,
          role: row.role,
          expires_at: invite.metadata.expires_at,
        });
        const emailDelivery = await maybeSendInviteEmail(invite, env, fetchImpl);
        return json({
          ok: true,
          member: publicMember(row),
          invite_url: invite.inviteURL,
          download_url: invite.downloadURL,
          email: invite.email,
          email_delivery: emailDelivery,
        });
      }

      if (request.method === "GET" && url.pathname === "/v1/library-items") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        const rows = await supabase.select("library_items", {
          select: "*",
          workspace_id: `eq.${context.workspace.id}`,
          is_enabled: "eq.true",
          order: "priority.desc,name.asc",
        });
        return json({ ok: true, items: rows ?? [] });
      }

      if (request.method === "POST" && url.pathname === "/v1/library-items/sync") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        const body = await parseJSONBody(request);
        const items = Array.isArray(body.items) ? body.items : [];
        const rows = items.map((item) => libraryRow(item, context));
        if (rows.length > 0) {
          await supabase.upsert("library_items", rows, { onConflict: "id" });
        }
        return json({ ok: true, count: rows.length });
      }

      if (request.method === "POST" && url.pathname === "/v1/meetings/sync") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        const body = await parseJSONBody(request);
        const meetings = Array.isArray(body.meetings) ? body.meetings : [body.meeting ?? body];
        const rows = meetings.filter(Boolean).map((meeting) => meetingRow(meeting, context));
        if (rows.length > 0) {
          await supabase.upsert("meetings", rows, { onConflict: "id" });
        }
        return json({ ok: true, count: rows.length });
      }

      if (request.method === "POST" && url.pathname === "/v1/call-insights") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        const body = await parseJSONBody(request);
        const insights = Array.isArray(body.insights) ? body.insights : [body.insight ?? body];
        const rows = insights.filter(Boolean).map((insight) => callInsightRow(insight, context));
        if (rows.length > 0) {
          await supabase.insert("call_insights", rows);
        }
        return json({ ok: true, count: rows.length });
      }

      if (request.method === "POST" && url.pathname === "/v1/agent-events") {
        const context = await resolveWorkspaceContext(request, supabase, options);
        const body = await parseJSONBody(request);
        const events = Array.isArray(body.events) ? body.events : [body.event ?? body];
        const rows = events.filter(Boolean).map((event) => agentEventRow(event, context));
        if (rows.length > 0) {
          await supabase.upsert("agent_events", rows, { onConflict: "id" });
        }
        return json({ ok: true, count: rows.length });
      }

      return json({ ok: false, error: "Not found." }, 404);
    } catch (error) {
      const status = error.status || 500;
      return json({ ok: false, error: error.message, details: error.details ?? undefined }, status);
    }
  };
}

function publicMember(member) {
  return {
    id: member.id,
    email: member.email,
    display_name: member.display_name ?? member.displayName ?? null,
    role: member.role,
    manager_member_id: member.manager_member_id ?? member.managerMemberID ?? null,
    is_active: member.is_active ?? member.isActive ?? true,
    crm_user_id: member.crm_user_id ?? member.crmUserID ?? null,
    ghl_user_id: member.ghl_user_id ?? member.ghlUserID ?? null,
    calendar_email: member.calendar_email ?? member.calendarEmail ?? null,
    permissions: member.metadata?.permissions ?? {},
    metadata: member.metadata ?? {},
    created_at: member.created_at ?? null,
    updated_at: member.updated_at ?? null,
  };
}

function workspacePermissions(context, env) {
  const role = context.member.role;
  const isAdmin = isWorkspaceAdmin(context, env);
  const memberPermissions = context.member.metadata?.permissions ?? {};
  return {
    can_admin_workspace: isAdmin,
    can_manage_members: isAdmin,
    can_manage_library: isAdmin || role === "manager",
    can_view_team_calls: isAdmin || role === "manager",
    can_use_sales_agent: memberPermissions.can_use_sales_agent ?? true,
    can_sync_meetings: memberPermissions.can_sync_meetings ?? context.workspace.transcript_enabled ?? true,
    can_record_meetings: memberPermissions.can_record_meetings ?? context.workspace.recording_enabled ?? false,
    can_use_ai_assist: memberPermissions.can_use_ai_assist ?? context.workspace.ai_assist_enabled ?? true,
    can_use_computer_control: memberPermissions.can_use_computer_control ?? true,
    can_manage_private_notes: memberPermissions.can_manage_private_notes ?? true,
  };
}

function requireWorkspaceAdmin(context, env) {
  if (isWorkspaceAdmin(context, env)) return;
  const error = new Error("Workspace admin role is required.");
  error.status = 403;
  throw error;
}

function isWorkspaceAdmin(context, env) {
  if (["owner", "admin"].includes(context.member.role)) return true;
  const bootstrapEmails = String(env.SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS ?? "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);
  return bootstrapEmails.includes(context.userEmail);
}

function adminMemberRow(member, context) {
  const email = requiredString(member.email, "member email").toLowerCase();
  const role = normalizeRole(member.role ?? "rep");
  const metadata = {
    ...(member.metadata ?? {}),
    permissions: normalizeMemberPermissions(member.permissions ?? member.metadata?.permissions),
  };
  return {
    id: member.id && isUuid(member.id) ? member.id : stableUuid(`member|${context.workspace.id}|${email}`),
    workspace_id: context.workspace.id,
    email,
    display_name: member.display_name ?? member.displayName ?? member.name ?? email,
    role,
    manager_member_id: uuidOrNull(member.manager_member_id ?? member.managerMemberID),
    is_active: member.is_active ?? member.isActive ?? true,
    crm_user_id: member.crm_user_id ?? member.crmUserID ?? null,
    ghl_user_id: member.ghl_user_id ?? member.ghlUserID ?? null,
    calendar_email: member.calendar_email ?? member.calendarEmail ?? email,
    metadata,
  };
}

function adminInvite(member, context, env) {
  const email = requiredString(member.email, "member email").toLowerCase();
  const displayName = member.display_name ?? member.displayName ?? member.name ?? email;
  const role = normalizeRole(member.role ?? "rep");
  const token = randomBytes(24).toString("base64url");
  const expiresAt = new Date(Date.now() + inviteTTLHours(env) * 60 * 60 * 1000).toISOString();
  const inviteURL = `${inviteBaseURL(env)}/join?token=${encodeURIComponent(token)}`;
  const downloadURL = downloadURLForInvite(env);
  const subject = `You're invited to Sales Caddie`;
  const body = [
    `Hi ${displayName},`,
    "",
    `${context.member.display_name ?? context.userEmail} invited you to join ${context.workspace.name ?? context.workspace.slug} in Sales Caddie.`,
    "",
    `1. Download Sales Caddie: ${downloadURL}`,
    `2. Open this invite link to finish setup: ${inviteURL}`,
    "",
    `This invite expires ${expiresAt}.`,
  ].join("\n");
  return {
    member: {
      ...member,
      email,
      display_name: displayName,
      role,
      calendar_email: member.calendar_email ?? member.calendarEmail ?? email,
    },
    metadata: {
      status: "pending",
      token_hash: tokenSha256(token),
      invited_by_member_id: context.member.id,
      invited_by_email: context.userEmail,
      invited_at: new Date().toISOString(),
      expires_at: expiresAt,
      download_url: downloadURL,
    },
    inviteURL,
    downloadURL,
    email: {
      to: email,
      subject,
      body,
      mailto_url: `mailto:${encodeURIComponent(email)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`,
    },
  };
}

async function maybeSendInviteEmail(invite, env, fetchImpl) {
  const provider = String(env.SALES_CADDIE_EMAIL_PROVIDER ?? "").trim().toLowerCase();
  if (!provider) {
    return { sent: false, provider: "none", reason: "Email provider is not configured." };
  }
  if (provider !== "resend") {
    return { sent: false, provider, reason: `Unsupported email provider '${provider}'.` };
  }
  const apiKey = String(env.RESEND_API_KEY ?? "").trim();
  const from = String(env.SALES_CADDIE_EMAIL_FROM ?? "").trim();
  if (!apiKey || !from) {
    return { sent: false, provider, reason: "RESEND_API_KEY and SALES_CADDIE_EMAIL_FROM are required." };
  }
  const response = await fetchImpl("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: [invite.email.to],
      subject: invite.email.subject,
      text: invite.email.body,
    }),
  });
  const text = await response.text();
  if (!response.ok) {
    return { sent: false, provider, status: response.status, reason: text || "Email provider rejected the message." };
  }
  return { sent: true, provider, status: response.status };
}

function normalizeRole(role) {
  const value = String(role ?? "").toLowerCase();
  if (["owner", "admin", "manager", "rep", "viewer"].includes(value)) return value;
  const error = new Error(`Unsupported member role '${role}'.`);
  error.status = 400;
  throw error;
}

function normalizeMemberPermissions(permissions) {
  if (!permissions || typeof permissions !== "object" || Array.isArray(permissions)) return {};
  const allowed = [
    "can_record_meetings",
    "can_sync_meetings",
    "can_use_ai_assist",
    "can_use_sales_agent",
    "can_use_computer_control",
    "can_manage_private_notes",
  ];
  return Object.fromEntries(
    Object.entries(permissions)
      .filter(([key]) => allowed.includes(key))
      .map(([key, value]) => [key, Boolean(value)])
  );
}

async function writeAuditEvent(supabase, context, action, metadata = {}) {
  await supabase.insert("audit_events", [
    {
      workspace_id: context.workspace.id,
      actor_member_id: context.member.id,
      action,
      target_table: "workspace_members",
      metadata,
    },
  ]);
}

function libraryRow(item, context) {
  const kind = requiredString(item.kind, "kind");
  const name = requiredString(item.name, "name");
  const id = item.id || stableUuid(`library|${context.workspace.id}|${kind}|${name}`);
  return {
    id,
    workspace_id: context.workspace.id,
    created_by_member_id: context.member.id,
    kind: kind === "competitor" ? "battlecard" : kind,
    name,
    content: item.content ?? "",
    trigger_phrases: normalizeTriggerPhrases(item.trigger_phrases ?? item.triggerPhrases),
    guidance: item.guidance ?? item.talk_track ?? item.talkTrack ?? "",
    priority: normalizePriority(item.priority),
    is_enabled: item.is_enabled ?? item.isEnabled ?? true,
    metadata: item.metadata ?? {},
  };
}

function meetingRow(meeting, context) {
  const localId = requiredString(meeting.local_id ?? meeting.localID ?? meeting.id, "meeting local id");
  const id = meeting.id && isUuid(meeting.id)
    ? meeting.id
    : stableUuid(`meeting|${context.workspace.id}|${context.install.id}|${localId}`);
  const transcript = meeting.transcript ?? meeting.raw_transcript ?? meeting.rawTranscript ?? "";
  const summary = meeting.summary ?? meeting.formatted_notes ?? meeting.formattedNotes ?? "";
  return {
    id,
    workspace_id: context.workspace.id,
    rep_member_id: context.member.id,
    app_install_id: context.install.id,
    external_calendar_event_id: meeting.calendar_event_id ?? meeting.calendarEventID ?? null,
    title: meeting.title ?? "Meeting",
    source: meeting.source ?? "meeting",
    transcript_status: transcript.trim() ? "completed" : "missing",
    summary,
    started_at: meeting.started_at ?? meeting.startedAt ?? meeting.start_time ?? meeting.startTime ?? null,
    ended_at: meeting.ended_at ?? meeting.endedAt ?? null,
    duration_seconds: integerOrNull(meeting.duration_seconds ?? meeting.durationSeconds),
    is_private: Boolean(meeting.is_private ?? meeting.isPrivate ?? false),
    metadata: {
      ...(meeting.metadata ?? {}),
      local_id: localId,
      transcript,
    },
  };
}

function callInsightRow(insight, context) {
  const kind = requiredString(insight.kind, "kind");
  const name = requiredString(insight.name ?? insight.objection, "name");
  return {
    id: insight.id && isUuid(insight.id) ? insight.id : undefined,
    workspace_id: context.workspace.id,
    meeting_id: insight.meeting_id ?? insight.meetingID ?? null,
    kind,
    name,
    evidence: insight.evidence ?? insight.quote ?? "",
    guidance: insight.guidance ?? insight.talk_track ?? insight.talkTrack ?? "",
    confidence: numberOrNull(insight.confidence),
    timestamp_seconds: integerOrNull(insight.timestamp_seconds ?? insight.timestampSeconds),
    metadata: {
      ...(insight.metadata ?? {}),
      source: "sales_caddie_cloud_api",
      local_meeting_id: insight.local_meeting_id ?? insight.localMeetingID ?? null,
      member_id: context.member.id,
      app_install_id: context.install.id,
    },
  };
}

function agentEventRow(event, context) {
  const localId = requiredString(event.local_id ?? event.localID ?? event.id, "event id");
  const id = isUuid(localId)
    ? localId
    : stableUuid(`agent-event|${context.workspace.id}|${context.install.id}|${localId}`);
  return {
    id,
    workspace_id: context.workspace.id,
    member_id: context.member.id,
    app_install_id: context.install.id,
    meeting_id: event.meeting_id ?? event.meetingID ?? null,
    provider: event.provider ?? "hosted_jessica",
    status: event.status ?? "done",
    transcript: event.transcript ?? "",
    response: event.response ?? "",
    planner_command: event.planner_command ?? event.plannerCommand ?? null,
    action_type: event.action_type ?? event.actionType ?? null,
    action_status: event.action_status ?? event.actionStatus ?? null,
    source_app: event.source_app ?? event.sourceApp ?? "Sales Caddie",
    metadata: {
      ...(event.metadata ?? {}),
      local_id: localId,
    },
    client_created_at: event.client_created_at ?? event.clientCreatedAt ?? new Date().toISOString(),
  };
}

function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function inviteLandingPage({ token, downloadURL, apiURL }) {
  const safeToken = escapeHTML(token);
  const safeDownloadURL = escapeHTML(downloadURL);
  const safeAPIURL = escapeHTML(apiURL);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Join Sales Caddie</title>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f7f7f4; color: #181816; }
    main { max-width: 680px; margin: 8vh auto; padding: 32px; }
    .card { background: #fff; border: 1px solid #ddd8ca; border-radius: 12px; padding: 28px; box-shadow: 0 12px 40px rgba(20, 31, 28, 0.08); }
    h1 { margin: 0 0 8px; font-size: 36px; line-height: 1.05; }
    p { color: #5f625b; font-size: 16px; line-height: 1.5; }
    a.button { display: inline-block; margin: 10px 0 20px; padding: 12px 16px; border-radius: 8px; background: #0d5f43; color: white; text-decoration: none; font-weight: 700; }
    code { display: block; padding: 14px; border-radius: 8px; background: #f0eee7; color: #1c1c19; word-break: break-all; }
    .muted { font-size: 13px; color: #7a7d75; }
  </style>
</head>
<body>
  <main>
    <div class="card">
      <h1>Join Sales Caddie</h1>
      <p>Download Sales Caddie, then paste this setup code when prompted.</p>
      <a class="button" href="${safeDownloadURL}">Download Sales Caddie</a>
      <p><strong>Setup code</strong></p>
      <code>${safeToken}</code>
      <p class="muted">Cloud API: ${safeAPIURL}</p>
    </div>
  </main>
</body>
</html>`;
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function tokenSha256(token) {
  return createHash("sha256").update(token).digest("hex");
}

function inviteTTLHours(env) {
  const value = Number(env.SALES_CADDIE_INVITE_TTL_HOURS ?? 168);
  return Number.isFinite(value) && value > 0 ? value : 168;
}

function inviteBaseURL(env) {
  return String(env.SALES_CADDIE_INVITE_BASE_URL ?? env.SALES_CADDIE_PUBLIC_APP_URL ?? publicBaseURL(env)).replace(/\/+$/, "");
}

function publicBaseURL(env) {
  const explicit = env.SALES_CADDIE_PUBLIC_API_URL;
  if (explicit) return String(explicit).replace(/\/+$/, "");
  const railway = env.RAILWAY_PUBLIC_DOMAIN || env.RAILWAY_STATIC_URL;
  if (railway) return `https://${String(railway).replace(/^https?:\/\//, "").replace(/\/+$/, "")}`;
  return "http://localhost:8787";
}

function downloadURLForInvite(env) {
  return String(env.SALES_CADDIE_DOWNLOAD_URL ?? "https://freedspeech.xyz/download/").trim();
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value ?? ""));
}

function uuidOrNull(value) {
  return isUuid(value) ? value : null;
}

function integerOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.round(number) : null;
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT || DEFAULT_PORT);
  const app = createApp();
  const server = await import("node:http").then(({ createServer }) =>
    createServer(async (incoming, outgoing) => {
      const request = new Request(`http://${incoming.headers.host}${incoming.url}`, {
        method: incoming.method,
        headers: incoming.headers,
        body: incoming.method === "GET" || incoming.method === "HEAD" ? undefined : incoming,
        duplex: "half",
      });
      const response = await app(request);
      outgoing.writeHead(response.status, Object.fromEntries(response.headers));
      if (response.body) {
        const reader = response.body.getReader();
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          outgoing.write(Buffer.from(value));
        }
      }
      outgoing.end();
    })
  );
  server.listen(port, () => {
    console.log(`Sales Caddie Cloud API listening on :${port}`);
  });
}
