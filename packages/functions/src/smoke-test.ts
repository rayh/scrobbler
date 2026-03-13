/**
 * Smoke tests — run via `npx sst shell --stage <stage> -- npm run test:smoke`
 *
 * sst shell injects SST resources as SST_RESOURCE_<name> env vars (JSON objects).
 * We read the API URL from SST_RESOURCE_ScrobbledApi.
 */
export {};

const apiResource = process.env.SST_RESOURCE_ScrobbledApi
  ? JSON.parse(process.env.SST_RESOURCE_ScrobbledApi)
  : null;

const apiUrl = apiResource?.url?.replace(/\/$/, "") ?? null;

if (!apiUrl) {
  console.error(
    "❌ No API URL found. Expected SST_OUTPUT_api or SST_OUTPUT_apiDomain env var.\n" +
    "   Run via: npx sst shell --stage <stage> -- npm run test:smoke"
  );
  process.exit(1);
}

console.log(`🔍 Smoke testing API at: ${apiUrl}\n`);

// ── Helpers ──────────────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

async function test(
  name: string,
  fn: () => Promise<void>
): Promise<void> {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (err: any) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${err?.message ?? err}`);
    failed++;
  }
}

async function get(
  path: string,
  headers: Record<string, string> = {}
): Promise<{ status: number; body: any }> {
  const res = await fetch(`${apiUrl}${path}`, { headers });
  let body: any;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, body };
}

async function post(
  path: string,
  payload: unknown,
  headers: Record<string, string> = {}
): Promise<{ status: number; body: any }> {
  const res = await fetch(`${apiUrl}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(payload),
  });
  let body: any;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, body };
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// Public feed — unauthenticated, should return 200 with a posts array
await test("GET /feed/public returns 200 with posts array", async () => {
  const { status, body } = await get("/feed/public");
  assert(status === 200, `Expected 200, got ${status}`);
  assert(Array.isArray(body?.posts) || Array.isArray(body?.groups), `Expected body.posts or body.groups to be an array, got: ${JSON.stringify(body)}`);
});

// Authenticated endpoints return 401 without a token
await test("GET /feed/following returns 401 without auth", async () => {
  const { status } = await get("/feed/following");
  assert(status === 401, `Expected 401, got ${status}`);
});

await test("GET /me returns 401 without auth", async () => {
  const { status } = await get("/me");
  assert(status === 401, `Expected 401, got ${status}`);
});

await test("GET /me/posts returns 401 without auth", async () => {
  const { status } = await get("/me/posts");
  assert(status === 401, `Expected 401, got ${status}`);
});

await test("POST /music/share returns 401 without auth", async () => {
  const { status } = await post("/music/share", {});
  assert(status === 401, `Expected 401, got ${status}`);
});

// User lookup — should 404 for a handle that doesn't exist (not crash)
await test("GET /users/:handle returns 404 for unknown handle", async () => {
  const { status } = await get("/users/__smoke_test_nonexistent__");
  assert(status === 404, `Expected 404, got ${status}`);
});

// Auth endpoint rejects a bad payload with 400 (not 500)
await test("POST /auth/apple returns 400 for missing body", async () => {
  const { status } = await post("/auth/apple", {});
  assert(
    status === 400 || status === 401,
    `Expected 400 or 401, got ${status}`
  );
});

// ── Summary ───────────────────────────────────────────────────────────────────

console.log(`\n${passed + failed} tests: ${passed} passed, ${failed} failed`);

if (failed > 0) {
  process.exit(1);
}
