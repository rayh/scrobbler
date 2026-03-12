import { DynamoDBStreamEvent, DynamoDBRecord, SQSEvent } from "aws-lambda";
import { DynamoDBClient, AttributeValue } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  QueryCommand,
  GetCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sqs = new SQSClient({});

const GROUPING_WINDOW_DAYS = 14;
const TIMELINE_TTL_DAYS = 30;

// ── Enqueue (DynamoDB stream → SQS) ─────────────────────────────────────────
// Triggered by the DynamoDB stream on new post inserts.
// Sends one SQS message per post — worker handles the fan-out.

export const enqueue = async (event: DynamoDBStreamEvent): Promise<void> => {
  for (const record of event.Records) {
    try {
      await enqueueRecord(record);
    } catch (error) {
      console.error("Error enqueuing record:", error, record);
    }
  }
};

async function enqueueRecord(record: DynamoDBRecord): Promise<void> {
  if (record.eventName !== "INSERT") return;

  const newImage = record.dynamodb?.NewImage;
  if (!newImage) return;

  const pk = newImage.pk?.S;
  const sk = newImage.sk?.S;

  // Only fan out posts: pk = user#<sub>#posts, sk = post#<timestamp>#<id>
  if (!pk || !sk) return;
  if (!pk.match(/^user#.+#posts$/) || !sk.startsWith("post#")) return;

  const item = unmarshall(newImage as Record<string, AttributeValue>);

  await sqs.send(new SendMessageCommand({
    QueueUrl: process.env.FANOUT_QUEUE_URL!,
    MessageBody: JSON.stringify({
      postId:       item.postId,
      userId:       item.userId,
      userHandle:   item.userHandle,
      track:        item.track,
      trackKey:     item.trackKey,
      voiceMemoUrl: item.voiceMemoUrl ?? null,
      transcript:   item.transcript ?? null,
      tags:         item.tags ?? [],
      createdAt:    item.createdAt,
      timestamp:    item.timestamp,
      location:     item.location ?? null,
      sk:           item.sk,
    }),
  }));

  console.log(`Enqueued post ${item.postId} for fan-out`);
}

// ── Worker (SQS → per-follower timeline writes) ──────────────────────────────
// Processes batches of fan-out messages from SQS.
// For each message, fans out to all followers using the recenttrack lookup
// to merge into an existing timeline item or create a new one.

export const worker = async (event: SQSEvent): Promise<void> => {
  for (const message of event.Records) {
    try {
      const post = JSON.parse(message.body);
      await fanOutPost(post);
    } catch (error) {
      console.error("Error processing fanout message:", error, message.body);
      throw error; // rethrow so SQS retries / routes to DLQ
    }
  }
};

interface PostMessage {
  postId: string;
  userId: string;
  userHandle: string;
  track: Record<string, any>;
  trackKey: string;
  voiceMemoUrl: string | null;
  transcript: string | null;
  tags: string[];
  createdAt: string;
  timestamp: number;
  location: Record<string, any> | null;
  sk: string;
}

async function fanOutPost(post: PostMessage): Promise<void> {
  if (!post.trackKey) {
    console.warn(`Post ${post.postId} missing trackKey — skipping grouping fan-out`);
    return;
  }

  // Get all followers of this user
  const followersResult = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: { ":pk": `user#${post.userId}#followers` },
  }));

  const followers = followersResult.Items || [];
  if (!followers.length) return;

  const nowSeconds = Math.floor(Date.now() / 1000);
  const ttl = nowSeconds + TIMELINE_TTL_DAYS * 24 * 60 * 60;
  const recentTrackTtl = nowSeconds + GROUPING_WINDOW_DAYS * 24 * 60 * 60;

  const intro = {
    postId:       post.postId,
    userId:       post.userId,
    userHandle:   post.userHandle,
    voiceMemoUrl: post.voiceMemoUrl,
    transcript:   post.transcript,
    tags:         post.tags,
    createdAt:    post.createdAt,
  };

  await Promise.all(followers.map(follower => fanOutToFollower({
    followerId: follower.followerId as string,
    post,
    intro,
    ttl,
    recentTrackTtl,
  })));

  console.log(`Fanned out post ${post.postId} to ${followers.length} followers`);
}

async function fanOutToFollower({
  followerId,
  post,
  intro,
  ttl,
  recentTrackTtl,
}: {
  followerId: string;
  post: PostMessage;
  intro: Record<string, any>;
  ttl: number;
  recentTrackTtl: number;
}): Promise<void> {
  // 1. Check the recenttrack lookup — O(1) GetItem
  const recentTrackRecord = await ddb.send(new GetCommand({
    TableName: process.env.TABLE_NAME,
    Key: {
      pk: `recenttrack#${followerId}`,
      sk: post.trackKey,
    },
  }));

  if (recentTrackRecord.Item) {
    // 2a. A timeline item exists for this track within the window.
    //     Append this intro to the sharedBy array and bump lastUpdatedAt.
    const timelineSk = recentTrackRecord.Item.timelineSk as string;

    await ddb.send(new UpdateCommand({
      TableName: process.env.TABLE_NAME,
      Key: {
        pk: `timeline#${followerId}`,
        sk: timelineSk,
      },
      UpdateExpression:
        "SET sharedBy = list_append(sharedBy, :newIntro), lastUpdatedAt = :now, #ttl = :ttl",
      ExpressionAttributeNames: { "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":newIntro":  [intro],
        ":now":       post.createdAt,
        ":ttl":       ttl,
      },
    }));

    // Also extend the recenttrack TTL so the window stays open
    await ddb.send(new UpdateCommand({
      TableName: process.env.TABLE_NAME,
      Key: {
        pk: `recenttrack#${followerId}`,
        sk: post.trackKey,
      },
      UpdateExpression: "SET #ttl = :ttl",
      ExpressionAttributeNames: { "#ttl": "ttl" },
      ExpressionAttributeValues: { ":ttl": recentTrackTtl },
    }));
  } else {
    // 2b. No recent timeline item — create a new one.
    const timelineSk = `post#${post.timestamp}#${post.trackKey}`;

    await ddb.send(new PutCommand({
      TableName: process.env.TABLE_NAME,
      Item: {
        pk:            `timeline#${followerId}`,
        sk:            timelineSk,
        trackKey:      post.trackKey,
        track:         post.track,
        windowStart:   post.createdAt,
        lastUpdatedAt: post.createdAt,
        sharedBy:      [intro],
        location:      post.location,
        likes:         0,
        ttl,
      },
    }));

    // Write the recenttrack lookup record
    await ddb.send(new PutCommand({
      TableName: process.env.TABLE_NAME,
      Item: {
        pk:         `recenttrack#${followerId}`,
        sk:         post.trackKey,
        timelineSk,
        ttl:        recentTrackTtl,
      },
    }));
  }
}
