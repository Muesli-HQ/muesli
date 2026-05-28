import { timingSafeEqual } from "node:crypto";

export function bearerTokenFromHeader(headerValue = "") {
  const [scheme, token] = String(headerValue ?? "").trim().split(/\s+/, 2);
  if (!scheme || scheme.toLowerCase() !== "bearer") return "";
  return token ?? "";
}

export function constantTimeEqual(a = "", b = "") {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  if (left.length !== right.length) return false;
  if (left.length === 0) return false;
  return timingSafeEqual(left, right);
}

export function requireApiToken(request, expectedToken) {
  if (!expectedToken) {
    return { ok: false, status: 500, error: "SALES_CADDIE_API_TOKEN is not configured." };
  }
  const token = bearerTokenFromHeader(request.headers.get("authorization"));
  if (!constantTimeEqual(token, expectedToken)) {
    return { ok: false, status: 401, error: "Invalid or missing API token." };
  }
  return { ok: true };
}
