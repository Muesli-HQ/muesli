import { requiredString, stableUuid } from "./normalize.mjs";

export async function resolveWorkspaceContext(request, supabase, options = {}) {
  const workspaceSlug = requiredString(
    request.headers.get("x-sales-caddie-workspace") ?? request.headers.get("x-workspace-slug"),
    "x-sales-caddie-workspace"
  );
  const userEmail = requiredString(
    request.headers.get("x-sales-caddie-user-email") ?? request.headers.get("x-user-email"),
    "x-sales-caddie-user-email"
  ).toLowerCase();
  const installKey = requiredString(
    request.headers.get("x-sales-caddie-install-key") ?? request.headers.get("x-install-key"),
    "x-sales-caddie-install-key"
  );

  const workspace = await findOrCreateWorkspace(supabase, workspaceSlug, options);
  const member = await findOrCreateMember(supabase, workspace.id, userEmail, request, options);
  const install = await upsertAppInstall(supabase, workspace.id, member.id, installKey, request);

  return { workspace, member, install, workspaceSlug, userEmail, installKey };
}

async function findOrCreateWorkspace(supabase, slug, options) {
  const rows = await supabase.select("workspaces", {
    select: "id,slug,name",
    slug: `eq.${slug}`,
    limit: "1",
  });
  if (rows?.[0]) return rows[0];
  if (!options.allowWorkspaceAutoCreate) {
    const error = new Error(`Workspace '${slug}' was not found.`);
    error.status = 403;
    throw error;
  }
  const [created] = await supabase.insert("workspaces", [
    {
      id: stableUuid(`workspace|${slug}`),
      slug,
      name: slug,
      metadata: { created_by: "sales_caddie_cloud_api" },
    },
  ], { returning: "representation" });
  return created;
}

async function findOrCreateMember(supabase, workspaceId, email, request, options) {
  const rows = await supabase.select("workspace_members", {
    select: "id,email,role,display_name",
    workspace_id: `eq.${workspaceId}`,
    email: `eq.${email}`,
    limit: "1",
  });
  if (rows?.[0]) return rows[0];
  if (!options.allowMemberAutoCreate) {
    const error = new Error(`Workspace member '${email}' was not found.`);
    error.status = 403;
    throw error;
  }
  const displayName = request.headers.get("x-sales-caddie-user-name") || email;
  const [created] = await supabase.insert("workspace_members", [
    {
      id: stableUuid(`member|${workspaceId}|${email}`),
      workspace_id: workspaceId,
      email,
      display_name: displayName,
      role: "rep",
      metadata: { created_by: "sales_caddie_cloud_api" },
    },
  ], { returning: "representation" });
  return created;
}

async function upsertAppInstall(supabase, workspaceId, memberId, installKey, request) {
  const appVersion = request.headers.get("x-sales-caddie-version") || null;
  const installId = stableUuid(`install|${workspaceId}|${installKey}`);
  const [row] = await supabase.upsert("app_installs", [
    {
      id: installId,
      workspace_id: workspaceId,
      member_id: memberId,
      install_key: installKey,
      app_version: appVersion,
      platform: "macos",
      last_seen_at: new Date().toISOString(),
      metadata: { user_agent: request.headers.get("user-agent") || "" },
    },
  ], { returning: "representation" });
  return row;
}
