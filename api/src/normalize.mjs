import { createHash } from "node:crypto";

export function requiredString(value, name) {
  const trimmed = String(value ?? "").trim();
  if (!trimmed) {
    const error = new Error(`${name} is required.`);
    error.status = 400;
    throw error;
  }
  return trimmed;
}

export function stableUuid(seed) {
  const hash = createHash("sha256").update(seed).digest();
  const bytes = Buffer.from(hash.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function normalizePriority(value) {
  const raw = String(value ?? "").trim().toLowerCase();
  if (raw === "high") return 2;
  if (raw === "low") return -1;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : 1;
}

export function normalizeTriggerPhrases(value) {
  if (Array.isArray(value)) {
    return value.map((item) => String(item).trim()).filter(Boolean);
  }
  return String(value ?? "")
    .split(/[\n,;]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

export function parseJSONBody(request) {
  return request.json().catch(() => {
    const error = new Error("Request body must be valid JSON.");
    error.status = 400;
    throw error;
  });
}
