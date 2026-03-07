#!/usr/bin/env node
// Clears all items from the ScrobbledTable.
// Run via: npx sst shell -- node clear-data.mjs

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand, BatchWriteCommand } from "@aws-sdk/lib-dynamodb";
import { Resource } from "sst";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = Resource.ScrobbledTable.name;

/**
 * Clears all items from the table.
 *
 * @param {object}   [opts]
 * @param {string[]} [opts.preservePks]  Items whose `pk` matches one of these
 *                                       values will be skipped (not deleted).
 */
export async function clearAll({ preservePks = [] } = {}) {
  const preserveSet = new Set(preservePks);
  console.log(`\n🧹 Clearing table: ${TABLE}`);
  if (preserveSet.size > 0) {
    console.log(`   Preserving ${preserveSet.size} pk(s): ${[...preserveSet].join(", ")}`);
  }

  let totalDeleted = 0;
  let totalSkipped = 0;
  let lastEvaluatedKey;

  do {
    const scan = await ddb.send(new ScanCommand({
      TableName: TABLE,
      ExclusiveStartKey: lastEvaluatedKey,
      ProjectionExpression: "pk, sk",
    }));

    const items = scan.Items ?? [];
    lastEvaluatedKey = scan.LastEvaluatedKey;

    if (items.length === 0) continue;

    const toDelete = items.filter(item => !preserveSet.has(item.pk));
    totalSkipped += items.length - toDelete.length;

    // BatchWriteItem accepts max 25 per call
    for (let i = 0; i < toDelete.length; i += 25) {
      const batch = toDelete.slice(i, i + 25).map(item => ({
        DeleteRequest: { Key: { pk: item.pk, sk: item.sk } },
      }));

      await ddb.send(new BatchWriteCommand({
        RequestItems: { [TABLE]: batch },
      }));
    }

    totalDeleted += toDelete.length;
    process.stdout.write(`   deleted ${totalDeleted} items...\r`);
  } while (lastEvaluatedKey);

  console.log(`✅ Cleared ${totalDeleted} items${totalSkipped > 0 ? ` (preserved ${totalSkipped})` : ""}         `);
}

// Run directly
if (process.argv[1] === new URL(import.meta.url).pathname) {
  clearAll().catch(err => { console.error(err); process.exit(1); });
}
