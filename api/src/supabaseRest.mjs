export class SupabaseRestClient {
  constructor({ url, serviceRoleKey, schema = "sales_app", fetchImpl = fetch }) {
    this.url = String(url ?? "").replace(/\/+$/, "");
    this.serviceRoleKey = serviceRoleKey;
    this.schema = schema;
    this.fetchImpl = fetchImpl;
  }

  assertConfigured() {
    if (!this.url) throw Object.assign(new Error("SUPABASE_URL is not configured."), { status: 500 });
    if (!this.serviceRoleKey) throw Object.assign(new Error("SUPABASE_SERVICE_ROLE_KEY is not configured."), { status: 500 });
  }

  async select(table, query = {}) {
    return this.request(table, { method: "GET", query });
  }

  async insert(table, rows, { returning = "minimal" } = {}) {
    return this.request(table, {
      method: "POST",
      body: rows,
      prefer: `return=${returning}`,
    });
  }

  async upsert(table, rows, { onConflict = "id", returning = "minimal" } = {}) {
    return this.request(table, {
      method: "POST",
      query: { on_conflict: onConflict },
      body: rows,
      prefer: `resolution=merge-duplicates,return=${returning}`,
    });
  }

  async request(table, { method, query = {}, body, prefer } = {}) {
    this.assertConfigured();
    const endpoint = new URL(`${this.url}/rest/v1/${table}`);
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== null && value !== "") {
        endpoint.searchParams.set(key, value);
      }
    }

    const headers = {
      apikey: this.serviceRoleKey,
      authorization: `Bearer ${this.serviceRoleKey}`,
      accept: "application/json",
      "accept-profile": this.schema,
      "content-profile": this.schema,
    };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (prefer) headers.prefer = prefer;

    const response = await this.fetchImpl(endpoint, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    const parsed = text ? safeParseJSON(text) : null;
    if (!response.ok) {
      const error = new Error(parsed?.message || text || `Supabase request failed with ${response.status}.`);
      error.status = response.status;
      error.details = parsed;
      throw error;
    }
    return parsed;
  }
}

function safeParseJSON(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
