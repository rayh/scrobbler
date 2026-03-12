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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/6c/11/d6/6c11d681-aa3a-d59e-4c2e-f77e181026ab/190295092665.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/1a/37/d1/1a37d1b1-8508-54f2-f541-bf4e437dda76/19UMGIM05028.rgb.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/76/46/48/76464884-0e9c-1951-a3f6-ce02f74c2b19/21UMGIM26093.rgb.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/a6/6e/bf/a66ebf79-5008-8948-b352-a790fc87446b/19UM1IM04638.rgb.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/2b/c4/c9/2bc4c9d4-3bc6-ab13-3f71-df0b89b173de/886448022213.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/da/8b/77/da8b7731-6f4f-eacf-5e74-8b23389eefa1/20UMGIM03371.rgb.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/89/59/6a/89596ab9-fa3c-8d08-4d95-a6450fa2013c/886449400515.jpg/400x400bb.jpg",
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
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/8d/ef/37/8def37cf-f641-1bba-f312-61a9b8d19fbf/886449068029.jpg/400x400bb.jpg",
        appleMusicUrl: "https://music.apple.com/us/album/montero/1571208585?i=1571208587",
      },
      comment: "Can't get this out of my head 🎸",
      tags: ["lilnasx", "montero", "pop"],
      hoursAgo: 11,
    },
  ],
};

// Ray's own posts — added to his feed directly (he follows himself implicitly via own timeline)
const RAY_POSTS = [
  {
    track: {
      id: "1440837621", title: "Closer", artist: "Nine Inch Nails",
      album: "The Downward Spiral",
      artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/55/e0/85/55e0851e-11df-3b6a-7c54-4eef0efc2bed/15UMGIM67680.rgb.jpg/400x400bb.jpg",
      appleMusicUrl: "https://music.apple.com/us/album/closer/1440837096?i=1440837621",
    },
    comment: "Still as intense as the first time I heard it 🖤",
    tags: ["nin", "industrial", "classic"],
    hoursAgo: 1,
  },
  {
    track: {
      id: "1846649031", title: "Birds and the Bees", artist: "Dub Fx",
      album: "Thinking Clear",
      artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/b1/69/a6/b169a655-f28a-51d1-50e8-fa966fca9f7f/5043.jpg/400x400bb.jpg",
      appleMusicUrl: "https://music.apple.com/us/album/birds-and-the-bees/1846649030?i=1846649031",
    },
    comment: "Dub FX doing what he does best 🎙️",
    tags: ["dubfx", "beatbox", "loopstation"],
    hoursAgo: 4,
  },
];
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
  console.log("\n🎵 Writing fake posts and timeline items...");

  const TTL_7D  = Math.floor(Date.now() / 1000) + 7  * 24 * 60 * 60;
  const TTL_3D  = Math.floor(Date.now() / 1000) + 3  * 24 * 60 * 60;

  for (const user of FAKE_USERS) {
    const userPosts = POSTS_BY_HANDLE[user.handle];

    for (const postDef of userPosts) {
      const ts        = Date.now() - postDef.hoursAgo * 60 * 60 * 1000;
      const id        = postId();
      const createdAt = new Date(ts).toISOString();
      const trackKey  = `${postDef.track.title.toLowerCase().replace(/[^a-z0-9]/g,'')}#${postDef.track.artist.toLowerCase().replace(/[^a-z0-9]/g,'')}`;

      const basePost = {
        postId:     id,
        userId:     user.sub,
        userHandle: user.handle,
        userName:   user.name,
        track:      postDef.track,
        comment:    postDef.comment,
        tags:       postDef.tags,
        trackKey,
        createdAt,
        timestamp:  ts,
        likes:      0,
        reposts:    0,
        location:   LOCATION,
        gsi1pk:    `location#${LOCATION.hex}`,
        gsi1sk:    `${ts}#${id}`,
      };

      // 1. User post item
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: { pk: `user#${user.sub}#posts`, sk: `post#${ts}#${id}`, ...basePost },
      }));

      // 2. Write directly to ray's timeline (don't rely on stream fanout timing)
      const intro = {
        postId:       id,
        userId:       user.sub,
        userHandle:   user.handle,
        voiceMemoUrl: null,
        transcript:   postDef.comment,
        tags:         postDef.tags,
        createdAt,
      };
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: {
          pk:            `timeline#${RAY_SUB}`,
          sk:            `post#${ts}#${trackKey}`,
          groupId:       `post#${ts}#${trackKey}`,
          trackKey,
          track:         postDef.track,
          windowStart:   createdAt,
          lastUpdatedAt: createdAt,
          sharedBy:      [intro],
          likes:         0,
          location:      LOCATION,
          ttl:           TTL_7D,
        },
      }));

      // 3. Primary location item (for location feed)
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: { pk: `location#${LOCATION.hex}`, sk: `${ts}#${id}`, ...basePost, ttl: TTL_7D },
      }));

      // 4. Adjacent hex item (for nearby feed ring)
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: { pk: `location#${ADJACENT_HEX}`, sk: `${ts}#${id}`, ...basePost, nearby: true, ttl: TTL_3D },
      }));

      console.log(`   ✅ @${user.handle}: "${postDef.track.title}" (${postDef.hoursAgo}h ago)`);

      // Small delay between posts to avoid identical timestamps
      await new Promise(r => setTimeout(r, 10));
    }
  }
}

async function writeRayPosts(idToken) {
  console.log("\n🎵 Writing ray's own posts directly to timeline...");

  const TTL_7D = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60;
  const TTL_3D = Math.floor(Date.now() / 1000) + 3 * 24 * 60 * 60;

  for (const postDef of RAY_POSTS) {
    const ts        = Date.now() - postDef.hoursAgo * 60 * 60 * 1000;
    const id        = postId();
    const createdAt = new Date(ts).toISOString();
    const trackKey  = `${postDef.track.title.toLowerCase().replace(/[^a-z0-9]/g,'')}#${postDef.track.artist.toLowerCase().replace(/[^a-z0-9]/g,'')}`;

    const basePost = {
      postId:     id,
      userId:     RAY_SUB,
      userHandle: "ray",
      userName:   "Ray",
      track:      postDef.track,
      comment:    postDef.comment,
      tags:       postDef.tags,
      trackKey,
      createdAt,
      timestamp:  ts,
      likes:      0,
      reposts:    0,
      location:   LOCATION,
      gsi1pk:    `location#${LOCATION.hex}`,
      gsi1sk:    `${ts}#${id}`,
    };

    // User post item
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { pk: `user#${RAY_SUB}#posts`, sk: `post#${ts}#${id}`, ...basePost },
    }));

    // Write directly to ray's own timeline (he doesn't follow himself)
    const intro = {
      postId:       id,
      userId:       RAY_SUB,
      userHandle:   "ray",
      voiceMemoUrl: null,
      transcript:   postDef.comment,
      tags:         postDef.tags,
      createdAt,
    };
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: {
        pk:            `timeline#${RAY_SUB}`,
        sk:            `post#${ts}#${trackKey}`,
        groupId:       `post#${ts}#${trackKey}`,
        trackKey,
        track:         postDef.track,
        windowStart:   createdAt,
        lastUpdatedAt: createdAt,
        sharedBy:      [intro],
        likes:         0,
        location:      LOCATION,
        ttl:           TTL_7D,
      },
    }));

    // Location items
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { pk: `location#${LOCATION.hex}`, sk: `${ts}#${id}`, ...basePost, ttl: TTL_7D },
    }));
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { pk: `location#${ADJACENT_HEX}`, sk: `${ts}#${id}`, ...basePost, nearby: true, ttl: TTL_3D },
    }));

    console.log(`   ✅ @ray: "${postDef.track.title}" (${postDef.hoursAgo}h ago)`);
    await new Promise(r => setTimeout(r, 10));
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

  // Follows MUST be written before posts so the DDB stream fanout
  // finds follower edges when it fires.
  if (idToken) {
    await followFakeUsers(idToken);
  }

  await writeFakePosts();
  await writeRayPosts(idToken);

  console.log("🎉 Seed complete!");
  console.log("\n📊 Summary:");
  console.log(`   👤 ray's profile: updated`);
  console.log(`   👥 Fake users:    ${FAKE_USERS.length} (${FAKE_USERS.map(u => "@" + u.handle).join(", ")})`);
  console.log(`   🎵 Fake posts:    ${FAKE_USERS.length * 2}`);
  console.log(`   🎵 Ray's posts:   ${RAY_POSTS.length} (written directly to timeline)`);
  console.log(`   🤝 Follows:       ${idToken ? FAKE_USERS.length : "skipped (no idToken)"}`);
  console.log(`   📰 Timeline:      ${idToken ? "built via fanout Lambda + ray's direct posts" : "ray's posts only"}`);
}

main().catch(err => { console.error("\n❌", err.message); process.exit(1); });
