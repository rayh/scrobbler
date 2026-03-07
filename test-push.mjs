import { SNSClient, PublishCommand, GetEndpointAttributesCommand, DeleteEndpointCommand } from "@aws-sdk/client-sns";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand, GetCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { Resource } from "sst";

const sns = new SNSClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const userInput = process.argv[2];
const title = process.argv[3] || "Test Notification";
const body = process.argv[4] || "This is a test push notification";

if (!userInput) {
  console.error("Usage: npx sst shell node test-push.mjs <username|userId> [title] [body]");
  process.exit(1);
}

const tableName = Resource.ScrobbledTable.name;

console.log(`\n📱 Looking up user: ${userInput}`);

// Try to resolve username via handle lookup table
let userId = userInput;
const handleLookup = await ddb.send(new GetCommand({
  TableName: tableName,
  Key: {
    pk: `handle#${userInput}`,
    sk: "lookup"
  }
}));

if (handleLookup.Item?.userId) {
  userId = handleLookup.Item.userId;
  console.log(`   Resolved handle to userId: ${userId}`);
} else {
  console.log(`   Using as userId directly: ${userId}`);
}

console.log(`\n📱 Looking up endpoints for user: ${userId}`);
console.log(`   Table: ${tableName}`);

// Query DynamoDB for registered endpoints
const result = await ddb.send(new QueryCommand({
  TableName: tableName,
  KeyConditionExpression: "pk = :pk",
  ExpressionAttributeValues: {
    ":pk": `user#${userId}#endpoints`
  }
}));

if (!result.Items || result.Items.length === 0) {
  console.error(`❌ No endpoints registered for user: ${userId}`);
  process.exit(1);
}

console.log(`\n✓ Found ${result.Items.length} endpoint(s):`);
result.Items.forEach((item, i) => {
  console.log(`  ${i + 1}. ARN: ${item.endpointArn}`);
  console.log(`     Platform: ${item.platform}`);
  console.log(`     Registered: ${item.registeredAt}`);
});

console.log(`\n📤 Sending push notification...`);
console.log(`   Title: ${title}`);
console.log(`   Body: ${body}`);

let sent = 0;
let removed = 0;

for (const endpoint of result.Items) {
  // Check live SNS state — DynamoDB may have stale enabled endpoints
  const attrs = await sns.send(new GetEndpointAttributesCommand({ EndpointArn: endpoint.endpointArn }));

  if (attrs.Attributes?.Enabled !== "true") {
    console.log(`   ⚠️  Disabled — removing ${endpoint.endpointArn.split('/').pop()}`);
    await sns.send(new DeleteEndpointCommand({ EndpointArn: endpoint.endpointArn })).catch(() => {});
    await ddb.send(new DeleteCommand({
      TableName: tableName,
      Key: { pk: endpoint.pk, sk: endpoint.sk }
    }));
    removed++;
    continue;
  }

  // Derive the correct message key from the endpoint ARN —
  // sandbox endpoints contain "APNS_SANDBOX", production ones contain "APNS/"
  const apnsKey = endpoint.endpointArn.includes("APNS_SANDBOX") ? "APNS_SANDBOX" : "APNS";
  try {
    await sns.send(new PublishCommand({
      TargetArn: endpoint.endpointArn,
      Message: JSON.stringify({
        default: body,
        [apnsKey]: JSON.stringify({
          aps: {
            alert: { title, body },
            sound: "default",
            badge: 1
          }
        })
      }),
      MessageStructure: "json"
    }));
    console.log(`   ✓ Sent to ${endpoint.endpointArn.split('/').pop()}`);
    sent++;
  } catch (error) {
    console.error(`   ❌ Failed to send to ${endpoint.endpointArn.split('/').pop()}: ${error.message}`);
  }
}

if (removed > 0) console.log(`\n🧹 Removed ${removed} defunct endpoint(s)`);
if (sent > 0) {
  console.log(`\n✅ Push notification sent to ${sent} endpoint(s)`);
} else {
  console.error(`\n❌ No enabled endpoints to send to`);
  process.exit(1);
}
