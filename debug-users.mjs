import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { Resource } from "sst";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const tableName = Resource.ScrobbledTable.name;

console.log(`\n🔍 Scanning table: ${tableName}`);
console.log(`   Looking for user profiles...\n`);

const result = await ddb.send(new ScanCommand({
  TableName: tableName,
  FilterExpression: "sk = :sk",
  ExpressionAttributeValues: {
    ":sk": "profile"
  }
}));

if (!result.Items || result.Items.length === 0) {
  console.log("❌ No user profiles found");
} else {
  console.log(`✓ Found ${result.Items.length} profile(s):\n`);
  result.Items.forEach((item, i) => {
    console.log(`${i + 1}.`, JSON.stringify(item, null, 2));
  });
}
