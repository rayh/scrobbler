import { DynamoDBStreamEvent, DynamoDBRecord } from "aws-lambda";
import { DynamoDBClient, AttributeValue } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = async (event: DynamoDBStreamEvent): Promise<void> => {
  for (const record of event.Records) {
    try {
      await processRecord(record);
    } catch (error) {
      console.error("Error processing record:", error, record);
    }
  }
};

async function processRecord(record: DynamoDBRecord): Promise<void> {
  if (record.eventName !== "INSERT") return;

  const newImage = record.dynamodb?.NewImage;
  if (!newImage) return;

  const pk = newImage.pk?.S;
  const sk = newImage.sk?.S;

  // Only fan out posts: pk = user#<sub>#posts, sk = post#<timestamp>#<id>
  if (!pk || !sk) return;
  if (!pk.match(/^user#.+#posts$/) || !sk.startsWith("post#")) return;

  // Unmarshall the stream image from DynamoDB wire format to plain JS object.
  // This correctly handles all DynamoDB types (M for maps, L for lists, S for strings, N for numbers).
  const item = unmarshall(newImage as Record<string, AttributeValue>);

  // userId is the cognitoSub — middle segment of pk (e.g. user#<uuid>#posts)
  const userId = item.pk.replace(/^user#/, "").replace(/#posts$/, "");

  // Get all followers of this user
  const followersResult = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: { ":pk": `user#${userId}#followers` },
  }));

  const followers = followersResult.Items || [];
  if (!followers.length) return;

  const ttl = Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60; // 30 days

  // Fan-out: copy post to each follower's timeline
  await Promise.all(followers.map(follower =>
    ddb.send(new PutCommand({
      TableName: process.env.TABLE_NAME,
      Item: {
        pk: `timeline#${follower.followerId}`,
        sk: item.sk,
        postId: item.postId,
        userId: item.userId,
        userHandle: item.userHandle,
        userName: item.userName,
        track: item.track,       // correctly deserialized Map via unmarshall
        comment: item.comment,
        tags: item.tags ?? [],   // correctly deserialized List via unmarshall
        createdAt: item.createdAt,
        timestamp: item.timestamp,
        ttl,
      },
    }))
  ));

  console.log(`Fanned out post ${item.postId} to ${followers.length} followers`);
}
