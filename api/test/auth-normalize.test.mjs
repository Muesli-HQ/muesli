import assert from "node:assert/strict";
import test from "node:test";
import { bearerTokenFromHeader, constantTimeEqual } from "../src/auth.mjs";
import { normalizePriority, normalizeTriggerPhrases, stableUuid } from "../src/normalize.mjs";

test("bearer token parsing accepts only bearer scheme", () => {
  assert.equal(bearerTokenFromHeader("Bearer secret"), "secret");
  assert.equal(bearerTokenFromHeader("bearer secret"), "secret");
  assert.equal(bearerTokenFromHeader("Basic secret"), "");
  assert.equal(bearerTokenFromHeader(""), "");
});

test("constant-time equality rejects empty and mismatched values", () => {
  assert.equal(constantTimeEqual("abc", "abc"), true);
  assert.equal(constantTimeEqual("abc", "abcd"), false);
  assert.equal(constantTimeEqual("", ""), false);
});

test("stableUuid is deterministic and uuid-shaped", () => {
  const first = stableUuid("meeting|workspace|install|42");
  const second = stableUuid("meeting|workspace|install|42");
  const different = stableUuid("meeting|workspace|install|43");

  assert.equal(first, second);
  assert.notEqual(first, different);
  assert.match(first, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("library field normalization matches desktop payloads", () => {
  assert.deepEqual(normalizeTriggerPhrases("too expensive\ncost; timing"), ["too expensive", "cost", "timing"]);
  assert.deepEqual(normalizeTriggerPhrases([" a ", "", "b"]), ["a", "b"]);
  assert.equal(normalizePriority("high"), 2);
  assert.equal(normalizePriority("low"), -1);
  assert.equal(normalizePriority("medium"), 1);
  assert.equal(normalizePriority(7), 7);
});
