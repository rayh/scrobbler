#!/usr/bin/env node
// Seeds DynamoDB with fake users, posts, and follows for local development.
//
// What it does:
//   1. Clears all existing table data
//   2. Writes/updates ray's real profile (adds handle field)
//   3. Writes 4 fake user profiles + handle lookups
//   4. Follows each fake user as ray via the real POST /follow Lambda
//      (exercises social.ts — writes correct following/follower edges + timeline backfill)
//   5. Writes 2 geotagged posts per fake user directly to DynamoDB
//      (DynamoDB stream fires fanout.ts automatically, building ray's timeline)
//
// Run via: npm run seed

import { readFileSync } from "fs";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, GetCommand } from "@aws-sdk/lib-dynamodb";
import { CognitoIdentityProviderClient, AdminInitiateAuthCommand } from "@aws-sdk/client-cognito-identity-provider";
import { Resource } from "sst";
import { clearAll } from "./clear-data.mjs";

// ── Config ─────────────────────────────────────────────────────────────────────

const TABLE = Resource.ScrobbledTable.name;

// SST outputs — user pool is a raw Pulumi resource, not an sst.aws component,
// so it isn't exposed via Resource.*. Read from .sst/outputs.json instead.
const outputs = JSON.parse(readFileSync(".sst/outputs.json", "utf8"));
const USER_POOL_ID = outputs.userPoolId;
const CLIENT_ID    = outputs.userPoolClientId;
const API_URL      = outputs.api;

// Ray's real Cognito sub and Apple user ID (stable for this user pool)
const RAY_SUB      = "02954444-00a1-7056-ad7b-c1a948b7d30b";
const RAY_APPLE_ID = "000436.509be144192c4df7910f46c954c3563c.0107";

// Fake users — deterministic UUIDs that won't clash with real Cognito v7 UUIDs
const FAKE_USERS = [
  {
    sub:    "bbbbbbbb-0000-0000-0000-000000000001",
    handle: "sarahbeats",
    name:   "Sarah Chen",
    email:  "sarah@example.com",
    bio:    "Electronic music producer & DJ 🎧",
  },
  {
    sub:    "bbbbbbbb-0000-0000-0000-000000000002",
    handle: "mikevibes",
    name:   "Mike Rodriguez",
    email:  "mike@example.com",
    bio:    "Indie rock enthusiast 🎸",
  },
  {
    sub:    "bbbbbbbb-0000-0000-0000-000000000003",
    handle: "emmaflow",
    name:   "Emma Thompson",
    email:  "emma@example.com",
    bio:    "Jazz & soul collector 🎷",
  },
  {
    sub:    "bbbbbbbb-0000-0000-0000-000000000004",
    handle: "alexsound",
    name:   "Alex Kim",
    email:  "alex@example.com",
    bio:    "Hip-hop head & beatmaker 🎤",
  },
];

// Posts per fake user — 2 each
const POSTS_BY_HANDLE = {
  sarahbeats: [
    {
      track: {
        id: "1498378115", title: "Levitating", artist: "Dua Lipa",
        album: "Future Nostalgia",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music114/v4/5b/b8/c8/5bb8c8a5-8684-b8b1-4a31-c5f7a06b4e35/20UMGIM13877.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/future-nostalgia/1498378108?i=1498378115",
      },
      comment: "The production on this is absolutely insane! 🔥",
      tags: ["dualipa", "production", "dance"],
      hoursAgo: 3,
    },
    {
      track: {
        id: "1440838686", title: "Bad Guy", artist: "Billie Eilish",
        album: "When We All Fall Asleep, Where Do We Go?",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music114/v4/59/b8/82/59b882b8-2e11-3c8b-edb2-0e99b3a3b2a7/19UMGIM03883.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/bad-guy/1440838683?i=1440838686",
      },
      comment: "Still hits different every single time 🖤",
      tags: ["billieeilish", "pop", "vibes"],
      hoursAgo: 9,
    },
  ],
  mikevibes: [
    {
      track: {
        id: "1567714698", title: "Good 4 U", artist: "Olivia Rodrigo",
        album: "SOUR",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music114/v4/d7/f3/36/d7f3366d-8e24-3e19-a5c2-c1c5f7f7f7f7/21UMGIM29757.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/sour/1567714688?i=1567714698",
      },
      comment: "Olivia's songwriting is next level 🎵",
      tags: ["oliviarodrigo", "songwriting", "pop"],
      hoursAgo: 5,
    },
    {
      track: {
        id: "1544494715", title: "Blinding Lights", artist: "The Weeknd",
        album: "After Hours",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music114/v4/ef/6f/04/ef6f049c-ce6f-dc2e-1c65-c8b5-b5b5b5b5b5b5/20UMGIM24697.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/after-hours/1499378108?i=1499378112",
      },
      comment: "Absolute classic. Never gets old 🌃",
      tags: ["theweeknd", "afterhours", "rnb"],
      hoursAgo: 14,
    },
  ],
  emmaflow: [
    {
      track: {
        id: "1485802976", title: "Watermelon Sugar", artist: "Harry Styles",
        album: "Fine Line",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music114/v4/ad/ae/ba/adaeba4c-8b33-c5d9-e6b4-f5e2-f5e2f5e2f5e2/19UMGIM66701.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/fine-line/1485802965?i=1485802976",
      },
      comment: "Summer vibes all year round ☀️",
      tags: ["harrystyles", "summer", "chill"],
      hoursAgo: 7,
    },
    {
      track: {
        id: "1522776464", title: "Heat Waves", artist: "Glass Animals",
        album: "Dreamland",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/33/7c/6e/337c6ef3-cc8e-1034-cf4c-7f7f7f7f7f7f/21UMGIM21200.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/dreamland/1522776454?i=1522776464",
      },
      comment: "Glass Animals never disappoints 🌊",
      tags: ["glassanimals", "dreamland", "indie"],
      hoursAgo: 20,
    },
  ],
  alexsound: [
    {
      track: {
        id: "1576845644", title: "Stay", artist: "The Kid LAROI & Justin Bieber",
        album: "F*CK LOVE 3",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/6a/4b/2c/6a4b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d/21UMGIM65439.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/stay-single/1576845642?i=1576845644",
      },
      comment: "This collab hits different 🎤",
      tags: ["kidlaroi", "justinbieber", "collab"],
      hoursAgo: 2,
    },
    {
      track: {
        id: "1544457069", title: "Montero (Call Me by Your Name)", artist: "Lil Nas X",
        album: "MONTERO",
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/7a/8b/9c/7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d/21UMGIM73458.rgb.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/montero/1571208585?i=1571208587",
      },
      comment: "Can't get this out of my head 🎸",
      tags: ["lilnasx", "montero", "pop"],
      hoursAgo: 11,
    },
  ],
};

// Sydney location (H3 resolution 8)
const LOCATION = {
  latitude:   -33.8688,
  longitude:  151.2093,
  hex:        "88be0e35cbfffff",
  resolution: 8,
};

// One adjacent hex for the nearby feed (ring-1 neighbour)
const ADJACENT_HEX = "88be0e35cbfffff".replace("cbf", "c9f"); // deterministic neighbour

// ── AWS clients ────────────────────────────────────────────────────────────────

const ddb     = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const cognito = new CognitoIdentityProviderClient({ region: "eu-west-1" });

// ── Helpers ────────────────────────────────────────────────────────────────────

function postId() {
  return `post-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
}

async function apiFetch(path, { method = "GET", token, body } = {}) {
  const res = await fetch(`${API_URL}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  if (!res.ok) throw new Error(`${method} ${path} → HTTP ${res.status}: ${JSON.stringify(json)}`);
  return json;
}

// ── Steps ──────────────────────────────────────────────────────────────────────

async function writeRayProfile() {
  console.log("\n👤 Writing ray's profile...");

  // Upsert profile — preserves email/providers/createdAt, adds handle
  const existing = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: { pk: `user#${RAY_SUB}`, sk: "profile" },
  }));

  const now = new Date().toISOString();
  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: {
      pk:        `user#${RAY_SUB}`,
      sk:        "profile",
      userId:    RAY_SUB,
      handle:    "ray",
      name:      existing.Item?.name || "Ray",
      email:     existing.Item?.email || "",
      providers: existing.Item?.providers || ["apple"],
      createdAt: existing.Item?.createdAt || now,
      updatedAt: now,
    },
  }));

  // Write handle lookup pointing to real sub
  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: "handle#ray", sk: "lookup", userId: RAY_SUB },
  }));

  console.log(`   ✅ user#${RAY_SUB} / profile  (handle: ray)`);
  console.log(`   ✅ handle#ray → ${RAY_SUB}`);
}

async function writeFakeUsers() {
  console.log("\n👥 Writing fake user profiles...");
  const now = new Date().toISOString();

  for (const user of FAKE_USERS) {
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: {
        pk:        `user#${user.sub}`,
        sk:        "profile",
        userId:    user.sub,
        handle:    user.handle,
        name:      user.name,
        email:     user.email,
        bio:       user.bio,
        providers: ["apple"],
        createdAt: now,
        updatedAt: now,
      },
    }));

    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { pk: `handle#${user.handle}`, sk: "lookup", userId: user.sub },
    }));

    console.log(`   ✅ @${user.handle} (${user.sub})`);
  }
}

async function getRayIdToken() {
  console.log("\n🔑 Getting ray's idToken via AdminInitiateAuth...");

  // Fetch the stored password from the provider record
  const provider = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: { pk: `provider#apple#${RAY_APPLE_ID}`, sk: "lookup" },
  }));

  if (!provider.Item?.password) {
    throw new Error(
      `No password found for ray (provider#apple#${RAY_APPLE_ID}).\n` +
      `Sign in on device at least once first so the provider record exists.`
    );
  }

  const result = await cognito.send(new AdminInitiateAuthCommand({
    UserPoolId: USER_POOL_ID,
    ClientId:   CLIENT_ID,
    AuthFlow:   "ADMIN_USER_PASSWORD_AUTH",
    AuthParameters: {
      USERNAME: RAY_APPLE_ID,
      PASSWORD: provider.Item.password,
    },
  }));

  const idToken = result.AuthenticationResult?.IdToken;
  if (!idToken) throw new Error("AdminInitiateAuth returned no IdToken");

  console.log("   ✅ Got idToken");
  return idToken;
}

async function followFakeUsers(idToken) {
  console.log("\n🤝 Following fake users as @ray...");

  for (const user of FAKE_USERS) {
    try {
      await apiFetch("/follow", {
        method: "POST",
        token:  idToken,
        body:   { targetHandle: user.handle, action: "follow" },
      });
      console.log(`   ✅ ray → @${user.handle}`);
    } catch (err) {
      // Already following is fine — social.ts uses PutCommand (idempotent)
      console.log(`   ⚠️  @${user.handle}: ${err.message}`);
    }
  }
}

async function writeFakePosts() {
  console.log("\n🎵 Writing fake posts (DDB stream will fan out to ray's timeline)...");

  const TTL_7D  = Math.floor(Date.now() / 1000) + 7  * 24 * 60 * 60;
  const TTL_3D  = Math.floor(Date.now() / 1000) + 3  * 24 * 60 * 60;

  for (const user of FAKE_USERS) {
    const userPosts = POSTS_BY_HANDLE[user.handle];

    for (const postDef of userPosts) {
      const ts        = Date.now() - postDef.hoursAgo * 60 * 60 * 1000;
      const id        = postId();
      const createdAt = new Date(ts).toISOString();

      const basePost = {
        postId:     id,
        userId:     user.sub,
        userHandle: user.handle,
        userName:   user.name,
        track:      postDef.track,
        comment:    postDef.comment,
        tags:       postDef.tags,
        createdAt,
        timestamp:  ts,
        likes:      0,
        reposts:    0,
        location:   LOCATION,
        gsi1pk:    `location#${LOCATION.hex}`,
        gsi1sk:    `${ts}#${id}`,
      };

      // 1. User post item — this is what triggers the DDB stream → fanout.ts
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: {
          pk: `user#${user.sub}#posts`,
          sk: `post#${ts}#${id}`,
          ...basePost,
        },
      }));

      // 2. Primary location item (for location feed)
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: {
          pk: `location#${LOCATION.hex}`,
          sk: `${ts}#${id}`,
          ...basePost,
          ttl: TTL_7D,
        },
      }));

      // 3. Adjacent hex item (for nearby feed ring)
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: {
          pk:     `location#${ADJACENT_HEX}`,
          sk:     `${ts}#${id}`,
          ...basePost,
          nearby: true,
          ttl:    TTL_3D,
        },
      }));

      console.log(`   ✅ @${user.handle}: "${postDef.track.title}" (${postDef.hoursAgo}h ago)`);

      // Small delay between posts to avoid identical timestamps
      await new Promise(r => setTimeout(r, 10));
    }
  }
}

async function waitForFanout() {
  process.stdout.write("\n⏳ Waiting 4s for DynamoDB stream fan-out...");
  await new Promise(r => setTimeout(r, 4000));
  console.log(" done\n");
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main() {
  console.log("🌱 Seeding ScrobbledAT dev data");
  console.log(`   Table:  ${TABLE}`);
  console.log(`   API:    ${API_URL}`);
  console.log(`   Pool:   ${USER_POOL_ID}`);

  // Preserve ray's provider record — it holds the Cognito password set by the
  // auth Lambda on first sign-in. Wiping it would break AdminInitiateAuth.
  await clearAll({ preservePks: [`provider#apple#${RAY_APPLE_ID}`] });
  await writeRayProfile();
  await writeFakeUsers();

  let idToken;
  try {
    idToken = await getRayIdToken();
  } catch (err) {
    console.warn(`\n⚠️  Could not get ray's idToken: ${err.message}`);
    console.warn("   Skipping follow step — run again after signing in on device.\n");
  }

  if (idToken) {
    await followFakeUsers(idToken);
  }

  await writeFakePosts();

  if (idToken) {
    await waitForFanout();
  }

  console.log("🎉 Seed complete!");
  console.log("\n📊 Summary:");
  console.log(`   👤 ray's profile: updated`);
  console.log(`   👥 Fake users:    ${FAKE_USERS.length} (${FAKE_USERS.map(u => "@" + u.handle).join(", ")})`);
  console.log(`   🎵 Posts:         ${FAKE_USERS.length * 2} (${FAKE_USERS.length * 2 * 3} DDB items including location)`);
  console.log(`   🤝 Follows:       ${idToken ? FAKE_USERS.length : "skipped (no idToken)"}`);
  console.log(`   📰 Timeline:      ${idToken ? "built via fanout Lambda" : "skipped"}`);
}

main().catch(err => { console.error("\n❌", err.message); process.exit(1); });
