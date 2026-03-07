#!/usr/bin/env node
// Sends a test push notification to ray's registered SNS endpoints.
//
// Usage:
//   npm run push:test
//   npm run push:test -- --title "Hello" --body "World"
//   npm run push:test -- --user <sub>     (defaults to ray's sub)
//
// Run via: npm run push:test

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";
import { Resource } from "sst";

// ── Config ─────────────────────────────────────────────────────────────────────

const TABLE = Resource.ScrobbledTable.name;
const RAY_SUB = "02954444-00a1-7056-ad7b-c1a948b7d30b";

// ── CLI args ───────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);

function getArg(name) {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 ? args[idx + 1] : undefined;
}

const userId = getArg("user") ?? RAY_SUB;
const title  = getArg("title") ?? "Test notification";
const body   = getArg("body")  ?? `Sent at ${new Date().toLocaleTimeString()}`;

// ── AWS clients ────────────────────────────────────────────────────────────────

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sns = new SNSClient({ region: "eu-west-1" });

// ── Main ───────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n📲 Sending test push notification`);
  console.log(`   Table:  ${TABLE}`);
  console.log(`   User:   ${userId}`);
  console.log(`   Title:  ${title}`);
  console.log(`   Body:   ${body}\n`);

  // Fetch registered endpoints for this user
  const result = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: { ":pk": `user#${userId}#endpoints` },
  }));

  const endpoints = result.Items ?? [];

  if (endpoints.length === 0) {
    console.log("⚠️  No registered push endpoints found for this user.");
    console.log("   Sign in on device and register a push token first (POST /push/register).");
    process.exit(0);
  }

  console.log(`   Found ${endpoints.length} endpoint(s):\n`);

  const message = JSON.stringify({
    default: body,
    APNS: JSON.stringify({
      aps: { alert: { title, body }, sound: "default", badge: 1 },
      data: { type: "test" },
    }),
    APNS_SANDBOX: JSON.stringify({
      aps: { alert: { title, body }, sound: "default", badge: 1 },
      data: { type: "test" },
    }),
  });

  let sent = 0;
  let failed = 0;

  for (const endpoint of endpoints) {
    const arn = endpoint.endpointArn ?? endpoint.sk;
    const platform = endpoint.platform ?? "unknown";
    const registered = endpoint.registeredAt ?? "unknown";

    process.stdout.write(`   [${platform}] ${arn.slice(-40)}... `);

    try {
      await sns.send(new PublishCommand({
        TargetArn: arn,
        Message:   message,
        MessageStructure: "json",
      }));
      console.log("✅ sent");
      sent++;
    } catch (err) {
      console.log(`❌ ${err.message}`);
      failed++;
    }
  }

  console.log(`\n📊 Result: ${sent} sent, ${failed} failed`);
}

main().catch(err => { console.error("\n❌", err.message); process.exit(1); });
