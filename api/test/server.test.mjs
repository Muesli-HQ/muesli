import assert from "node:assert/strict";
import test from "node:test";
import { createApp } from "../src/server.mjs";

const env = {
  SALES_CADDIE_API_TOKEN: "test-token",
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-role",
  SALES_CADDIE_AUTO_CREATE_WORKSPACES: "true",
  SALES_CADDIE_AUTO_CREATE_MEMBERS: "true",
};

test("health is public", async () => {
  const app = createApp(env, fakeFetch());
  const response = await app(new Request("http://localhost/health"));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).ok, true);
});

test("invite landing page is public and includes setup code", async () => {
  const app = createApp({
    ...env,
    SALES_CADDIE_PUBLIC_API_URL: "https://api.salescaddie.test",
    SALES_CADDIE_DOWNLOAD_URL: "https://salescaddie.test/download",
  }, fakeFetch());
  const response = await app(new Request("http://localhost/join?token=abc123"));
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Join Sales Caddie/);
  assert.match(html, /abc123/);
  assert.match(html, /https:\/\/salescaddie\.test\/download/);
});

test("protected routes require bearer token", async () => {
  const app = createApp(env, fakeFetch());
  const response = await app(new Request("http://localhost/v1/meetings/sync", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
  }));
  assert.equal(response.status, 401);
});

test("meeting sync resolves context and writes normalized meeting rows", async () => {
  const calls = [];
  const app = createApp(env, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/meetings/sync", {
    body: {
      meetings: [
        {
          local_id: "42",
          title: "Demo",
          transcript: "Prospect: I like this.",
          summary: "Good demo.",
          started_at: "2026-05-27T17:00:00Z",
          duration_seconds: 120,
        },
      ],
    },
  }));

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, count: 1 });
  const meetingWrite = calls.find((call) => call.url.pathname.endsWith("/meetings") && call.options.method === "POST");
  assert.ok(meetingWrite);
  const payload = JSON.parse(meetingWrite.options.body);
  assert.equal(payload[0].title, "Demo");
  assert.equal(payload[0].transcript_status, "completed");
  assert.equal(payload[0].metadata.local_id, "42");
  assert.equal(payload[0].metadata.transcript, "Prospect: I like this.");
});

test("me returns workspace identity and effective permissions", async () => {
  const app = createApp({
    ...env,
    SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS: "rep@skriber.com",
  }, fakeFetch());
  const response = await app(new Request("http://localhost/v1/me", {
    headers: requestHeaders(),
  }));

  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.ok, true);
  assert.equal(payload.member.email, "rep@skriber.com");
  assert.equal(payload.permissions.can_manage_members, true);
  assert.equal(payload.permissions.can_use_sales_agent, true);
  assert.equal(payload.permissions.can_use_computer_control, false);
});

test("admin member sync upserts role, rep mappings, and permission metadata", async () => {
  const calls = [];
  const app = createApp({
    ...env,
    SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS: "rep@skriber.com",
  }, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/admin/members", {
    body: {
      members: [
        {
          email: "manager@skriber.com",
          display_name: "Sales Manager",
          role: "manager",
          ghl_user_id: "ghl-123",
          crm_user_id: "crm-123",
          calendar_email: "manager-calendar@skriber.com",
          permissions: {
            can_sync_meetings: true,
            can_use_computer_control: false,
            unsupported_permission: true,
          },
        },
      ],
    },
  }));

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, count: 1 });
  const memberWrite = calls.find((call) => call.url.pathname.endsWith("/workspace_members") && call.options.method === "POST" && call.url.searchParams.get("on_conflict") === "workspace_id,email");
  assert.ok(memberWrite);
  const payload = JSON.parse(memberWrite.options.body);
  assert.equal(payload[0].email, "manager@skriber.com");
  assert.equal(payload[0].role, "manager");
  assert.equal(payload[0].ghl_user_id, "ghl-123");
  assert.equal(payload[0].metadata.permissions.can_sync_meetings, true);
  assert.equal(payload[0].metadata.permissions.can_use_computer_control, false);
  assert.equal(payload[0].metadata.permissions.unsupported_permission, undefined);
  const auditWrite = calls.find((call) => call.url.pathname.endsWith("/audit_events") && call.options.method === "POST");
  assert.ok(auditWrite);
});

test("admin member routes require workspace admin", async () => {
  const app = createApp(env, fakeFetch());
  const response = await app(request("http://localhost/v1/admin/members", {
    body: { email: "rep2@skriber.com" },
  }));

  assert.equal(response.status, 403);
  assert.match((await response.json()).error, /admin role/i);
});

test("admin invite creates pending member and email-ready invite", async () => {
  const calls = [];
  const app = createApp({
    ...env,
    SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS: "rep@skriber.com",
    SALES_CADDIE_PUBLIC_API_URL: "https://api.salescaddie.test",
    SALES_CADDIE_INVITE_BASE_URL: "https://app.salescaddie.test",
    SALES_CADDIE_DOWNLOAD_URL: "https://salescaddie.test/download",
  }, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/admin/invites", {
    body: {
      email: "newrep@skriber.com",
      display_name: "New Rep",
      role: "rep",
      permissions: {
        can_sync_meetings: true,
        can_use_sales_agent: true,
      },
    },
  }));

  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.ok, true);
  assert.equal(result.email.to, "newrep@skriber.com");
  assert.match(result.invite_url, /^https:\/\/app\.salescaddie\.test\/join\?token=/);
  assert.equal(result.download_url, "https://salescaddie.test/download");
  assert.match(result.email.body, /Download Sales Caddie/);
  assert.equal(result.email_delivery.sent, false);

  const memberWrite = calls.find((call) => call.url.pathname.endsWith("/workspace_members") && call.options.method === "POST" && call.url.searchParams.get("on_conflict") === "workspace_id,email");
  assert.ok(memberWrite);
  const payload = JSON.parse(memberWrite.options.body);
  assert.equal(payload[0].email, "newrep@skriber.com");
  assert.equal(payload[0].is_active, false);
  assert.equal(payload[0].metadata.invite.status, "pending");
  assert.ok(payload[0].metadata.invite.token_hash);
});

test("admin invite sends email through Resend when configured", async () => {
  const calls = [];
  const app = createApp({
    ...env,
    SALES_CADDIE_BOOTSTRAP_ADMIN_EMAILS: "rep@skriber.com",
    SALES_CADDIE_EMAIL_PROVIDER: "resend",
    RESEND_API_KEY: "resend-test-key",
    SALES_CADDIE_EMAIL_FROM: "Sales Caddie <noreply@salescaddie.test>",
  }, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/admin/invites", {
    body: {
      email: "newrep@skriber.com",
      display_name: "New Rep",
      role: "rep",
    },
  }));

  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.email_delivery.sent, true);
  const emailCall = calls.find((call) => String(call.url).startsWith("https://api.resend.com/emails"));
  assert.ok(emailCall);
  const payload = JSON.parse(emailCall.options.body);
  assert.deepEqual(payload.to, ["newrep@skriber.com"]);
  assert.match(payload.text, /Open this invite link/);
});

test("invite redeem returns desktop cloud config without shared auth header", async () => {
  const app = createApp({
    ...env,
    SALES_CADDIE_PUBLIC_API_URL: "https://api.salescaddie.test",
  }, fakeFetch());
  const response = await app(new Request("http://localhost/v1/invites/redeem", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: "valid-invite-token" }),
  }));

  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.ok, true);
  assert.equal(result.workspace.slug, "skriber-sales");
  assert.equal(result.member.email, "invited@skriber.com");
  assert.equal(result.config.sales_caddie_cloud_api_url, "https://api.salescaddie.test");
  assert.equal(result.config.sales_caddie_cloud_api_token, "test-token");
  assert.equal(result.config.sales_caddie_cloud_workspace_slug, "skriber-sales");
});

test("library sync maps competitor cards to battlecards", async () => {
  const calls = [];
  const app = createApp(env, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/library-items/sync", {
    body: {
      items: [
        {
          kind: "competitor",
          name: "Nabla",
          trigger_phrases: "Nabla\nusing Nabla",
          guidance: "Ask what still needs cleanup.",
          priority: "high",
        },
      ],
    },
  }));

  assert.equal(response.status, 200);
  const libraryWrite = calls.find((call) => call.url.pathname.endsWith("/library_items") && call.options.method === "POST");
  const payload = JSON.parse(libraryWrite.options.body);
  assert.equal(payload[0].kind, "battlecard");
  assert.deepEqual(payload[0].trigger_phrases, ["Nabla", "using Nabla"]);
  assert.equal(payload[0].priority, 2);
});

test("library sync preserves desktop live cue kinds", async () => {
  const calls = [];
  const app = createApp(env, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/library-items/sync", {
    body: {
      items: [
        {
          kind: "close",
          name: "Close the trial",
          trigger_phrases: ["let's do it"],
          guidance: "Move immediately to setup.",
        },
      ],
    },
  }));

  assert.equal(response.status, 200);
  const libraryWrite = calls.find((call) => call.url.pathname.endsWith("/library_items") && call.options.method === "POST");
  const payload = JSON.parse(libraryWrite.options.body);
  assert.equal(payload[0].kind, "close");
});

test("agent event sync accepts desktop local ids", async () => {
  const calls = [];
  const app = createApp(env, fakeFetch(calls));
  const response = await app(request("http://localhost/v1/agent-events", {
    body: {
      events: [
        {
          id: "local-agent-event-1",
          provider: "hosted_jessica",
          status: "done",
          transcript: "What should I say?",
          response: "Ask one clarifying question.",
        },
      ],
    },
  }));

  assert.equal(response.status, 200);
  const eventWrite = calls.find((call) => call.url.pathname.endsWith("/agent_events") && call.options.method === "POST");
  const payload = JSON.parse(eventWrite.options.body);
  assert.match(payload[0].id, /^[0-9a-f-]{36}$/);
  assert.equal(payload[0].metadata.local_id, "local-agent-event-1");
  assert.equal(payload[0].response, "Ask one clarifying question.");
});

function request(url, { body, headers = {} } = {}) {
  return new Request(url, {
    method: "POST",
    headers: {
      authorization: "Bearer test-token",
      "content-type": "application/json",
      "x-sales-caddie-workspace": "skriber-sales",
      "x-sales-caddie-user-email": "rep@skriber.com",
      "x-sales-caddie-install-key": "install-123",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

function requestHeaders(headers = {}) {
  return {
    authorization: "Bearer test-token",
    "content-type": "application/json",
    "x-sales-caddie-workspace": "skriber-sales",
    "x-sales-caddie-user-email": "rep@skriber.com",
    "x-sales-caddie-install-key": "install-123",
    ...headers,
  };
}

function fakeFetch(calls = []) {
  return async (url, options) => {
    const parsedURL = new URL(url);
    calls.push({ url: parsedURL, options });

    if (String(parsedURL).startsWith("https://api.resend.com/emails")) {
      return json({ id: "email_123" }, 200);
    }
    if (options.method === "GET" && parsedURL.pathname.endsWith("/workspace_members") && parsedURL.searchParams.has("metadata->invite->>token_hash")) {
      return json([
        {
          id: "44444444-4444-5444-9444-444444444444",
          workspace_id: "11111111-1111-5111-9111-111111111111",
          email: "invited@skriber.com",
          display_name: "Invited Rep",
          role: "rep",
          is_active: false,
          metadata: {
            invite: {
              status: "pending",
              token_hash: parsedURL.searchParams.get("metadata->invite->>token_hash").replace(/^eq\\./, ""),
              expires_at: "2999-01-01T00:00:00.000Z",
            },
          },
        },
      ]);
    }
    if (options.method === "GET" && parsedURL.pathname.endsWith("/workspaces") && parsedURL.searchParams.get("id") === "eq.11111111-1111-5111-9111-111111111111") {
      return json([{ id: "11111111-1111-5111-9111-111111111111", slug: "skriber-sales", name: "Skriber Sales" }]);
    }
    if (options.method === "GET" && parsedURL.pathname.endsWith("/workspaces")) {
      return json([]);
    }
    if (options.method === "GET" && parsedURL.pathname.endsWith("/workspace_members")) {
      return json([
        {
          id: "22222222-2222-5222-9222-222222222222",
          email: "rep@skriber.com",
          role: "rep",
          metadata: {
            permissions: {
              can_use_sales_agent: true,
              can_use_computer_control: false,
            },
          },
        },
      ]);
    }
    if (options.method === "POST" && parsedURL.pathname.endsWith("/workspaces")) {
      return json([{ id: "11111111-1111-5111-9111-111111111111", slug: "skriber-sales", name: "skriber-sales" }]);
    }
    if (options.method === "POST" && parsedURL.pathname.endsWith("/workspace_members")) {
      return json([{ id: "22222222-2222-5222-9222-222222222222", email: "rep@skriber.com", role: "rep" }]);
    }
    if (options.method === "POST" && parsedURL.pathname.endsWith("/app_installs")) {
      return json([{ id: "33333333-3333-5333-9333-333333333333", install_key: "install-123" }]);
    }
    return json(null);
  };
}

function json(payload, status = 200) {
  return new Response(payload === null ? "" : JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
