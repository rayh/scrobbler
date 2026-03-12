import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand, GetCommand } from "@aws-sdk/lib-dynamodb";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";
import { removeEndpoint } from "./push";

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);
const sns = new SNSClient({});

const BATCH_SIZE = 100;

export const handler = async (event: any) => {
  console.log("Messaging service triggered:", JSON.stringify(event, null, 2));
  
  try {
    for (const record of event.Records) {
      if (record.eventName !== "INSERT" || !record.dynamodb?.NewImage) continue;
      const newItem = record.dynamodb.NewImage;
      const pk: string = newItem.pk?.S ?? "";

      if (pk.includes("#posts")) {
        await sendNewPostNotification(newItem);
      } else if (pk.includes("#followers")) {
        await sendFollowNotification(newItem);
      } else if (pk.startsWith("like#")) {
        await sendLikeNotification(newItem);
      }
    }
  } catch (error) {
    console.error("Messaging handler error:", error);
  }
};

// ── New post → notify followers ───────────────────────────────────────────────

async function sendNewPostNotification(postItem: any) {
  try {
    const userId = postItem.userId?.S;
    const userHandle = postItem.userHandle?.S;
    const trackTitle = postItem.track?.M?.title?.S;
    const trackArtist = postItem.track?.M?.artist?.S;
    const locationHex = postItem.location?.M?.hex?.S;
    const postId = postItem.postId?.S;
    
    if (!userId || !userHandle || !trackTitle || !postId) return;
    
    // Fire alert push and silent background-sync push in parallel
    await Promise.all([
      sendToFollowers(userId, userHandle, trackTitle, trackArtist, postId),
      sendBackgroundSyncToFollowers(userId),
      locationHex
        ? sendLocationBasedNotifications(locationHex, userId, userHandle, trackTitle, trackArtist, postId)
        : Promise.resolve(),
    ]);
  } catch (error) {
    console.error("Send new post notification error:", error);
  }
}

async function sendToFollowers(userId: string, userHandle: string, trackTitle: string, trackArtist: string | undefined, postId: string) {
  const followers = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: {
      ":pk": `user#${userId}#followers`
    }
  }));
  
  if (!followers.Items?.length) return;
  
  for (const follower of followers.Items) {
    await sendNotificationToUser(
      follower.followerId,
      `@${userHandle} shared a track`,
      `${trackTitle}${trackArtist ? ` by ${trackArtist}` : ""}`,
      { type: "new_post", userId, postId }
    );
  }
}

/**
 * Send a silent background push (content-available: 1, no alert) to all followers
 * so the app can wake in the background and sync the Apple Music playlist.
 */
async function sendBackgroundSyncToFollowers(userId: string) {
  const result = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: { ":pk": `user#${userId}#followers` },
  }));

  const followers = result.Items || [];
  if (!followers.length) return;

  await Promise.all(followers.map(follower =>
    sendBackgroundSyncToUser(follower.followerId)
  ));
}

async function sendBackgroundSyncToUser(userId: string) {
  const endpoints = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: { ":pk": `user#${userId}#endpoints` },
  }));

  if (!endpoints.Items?.length) return;

  const apnsKey = process.env.IS_PROD === "true" ? "APNS" : "APNS_SANDBOX";

  // Silent background push: aps has content-available=1 and NO alert/sound/badge.
  // iOS will wake the app (or a suspended instance) to call the background fetch handler.
  const message = JSON.stringify({
    default: "",
    [apnsKey]: JSON.stringify({
      aps: { "content-available": 1 },
      data: { type: "feed_sync" },
    }),
  });

  await Promise.allSettled(endpoints.Items.map(async (endpoint) => {
    try {
      await sns.send(new PublishCommand({
        TargetArn: endpoint.endpointArn,
        Message: message,
        MessageStructure: "json",
      }));
    } catch (err: any) {
      if (err.name === "EndpointDisabled" || err.message?.includes("Unregistered")) {
        await removeEndpoint(endpoint.pk, endpoint.sk);
      } else {
        console.error("Failed to send background sync to endpoint:", endpoint.endpointArn, err);
      }
    }
  }));
}

async function sendLocationBasedNotifications(locationHex: string, posterId: string, userHandle: string, trackTitle: string, trackArtist: string | undefined, postId: string) {
  const oneDayAgo = Date.now() - (24 * 60 * 60 * 1000);
  
  const nearbyUsers = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    IndexName: "GSI1",
    KeyConditionExpression: "gsi1pk = :pk",
    FilterExpression: "createdAt > :timestamp AND userId <> :posterId",
    ExpressionAttributeValues: {
      ":pk": `location#${locationHex}`,
      ":timestamp": new Date(oneDayAgo).toISOString(),
      ":posterId": posterId
    }
  }));
  
  if (nearbyUsers.Items) {
    for (const userLocation of nearbyUsers.Items) {
      await sendNotificationToUser(
        userLocation.userId,
        `Music shared nearby`,
        `@${userHandle} shared "${trackTitle}"${trackArtist ? ` by ${trackArtist}` : ""} in your area`,
        { type: "location_post", locationHex, posterId, postId }
      );
    }
  }
}

// ── New follower → notify target user ────────────────────────────────────────

async function sendFollowNotification(item: any) {
  try {
    // pk = user#<targetUserId>#followers, followerHandle is denormalized in
    const targetUserId: string = item.pk?.S?.split("#")[1];
    const followerHandle: string = item.followerHandle?.S;
    const followerId: string = item.followerId?.S;

    if (!targetUserId || !followerHandle || !followerId) return;

    await sendNotificationToUser(
      targetUserId,
      `@${followerHandle} followed you`,
      "Tap to see their profile",
      { type: "new_follower", followerId, followerHandle }
    );
  } catch (error) {
    console.error("Send follow notification error:", error);
  }
}

// ── Like → notify post owner ──────────────────────────────────────────────────

async function sendLikeNotification(item: any) {
  try {
    const postOwnerId: string = item.postOwnerId?.S;
    const likerId: string = item.likerId?.S;
    const postId: string = item.postId?.S;

    if (!postOwnerId || !likerId || !postId) return;

    // Don't notify someone who liked their own post
    if (postOwnerId === likerId) return;

    // Fetch the liker's handle for a meaningful message
    const likerHandle = await getHandle(likerId);
    if (!likerHandle) return;

    await sendNotificationToUser(
      postOwnerId,
      `@${likerHandle} liked your share`,
      "Tap to see your post",
      { type: "like", likerId, postId }
    );
  } catch (error) {
    console.error("Send like notification error:", error);
  }
}

async function getHandle(userId: string): Promise<string | undefined> {
  const result = await ddb.send(new GetCommand({
    TableName: process.env.TABLE_NAME,
    Key: { pk: `user#${userId}`, sk: "profile" },
  }));
  return result.Item?.handle as string | undefined;
}

// ── Shared send helpers ───────────────────────────────────────────────────────

async function sendNotificationToUser(userId: string, title: string, body: string, data: any) {
  const endpoints = await ddb.send(new QueryCommand({
    TableName: process.env.TABLE_NAME,
    KeyConditionExpression: "pk = :pk",
    ExpressionAttributeValues: {
      ":pk": `user#${userId}#endpoints`
    }
  }));
  
  if (!endpoints.Items?.length) return;
  
  for (let i = 0; i < endpoints.Items.length; i += BATCH_SIZE) {
    const batch = endpoints.Items.slice(i, i + BATCH_SIZE);
    await sendBatch(batch, title, body, data);
  }
}

async function sendBatch(endpoints: any[], title: string, body: string, data: any) {
  const apnsKey = process.env.IS_PROD === "true" ? "APNS" : "APNS_SANDBOX";
  const message = JSON.stringify({
    default: body,
    [apnsKey]: JSON.stringify({
      aps: { alert: { title, body }, sound: "default", badge: 1 },
      data,
    }),
    GCM: JSON.stringify({
      notification: { title, body },
      data,
    }),
  });

  await Promise.allSettled(endpoints.map(async (endpoint) => {
    try {
      await sns.send(new PublishCommand({
        TargetArn: endpoint.endpointArn,
        Message: message,
        MessageStructure: "json",
      }));
    } catch (err: any) {
      if (err.name === "EndpointDisabled" || err.message?.includes("Unregistered")) {
        await removeEndpoint(endpoint.pk, endpoint.sk);
      } else {
        console.error("Failed to send to endpoint:", endpoint.endpointArn, err);
      }
    }
  }));
}
