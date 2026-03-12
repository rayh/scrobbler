import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, DeleteCommand, QueryCommand, GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import { latLngToCell, cellToBoundary, gridDisk } from "h3-js";

const GROUPING_WINDOW_DAYS = 14;

/**
 * Compute a stable, normalised key for a track.
 * Prefers ISRC (globally unique per recording) when available.
 * Falls back to slug(title)#slug(artist) — lowercase, alphanumeric only.
 */
function computeTrackKey(track: { isrc?: string; title: string; artist: string }): string {
  if (track.isrc) return `isrc#${track.isrc.toLowerCase()}`;
  const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  return `${slug(track.title)}#${slug(track.artist)}`;
}

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);

// H3 resolution: ~1.2km hex (neighborhoods)
const LOCATION_RESOLUTION = 8;

export const share = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    // userId (cognitoSub) comes from the verified JWT — never trust the request body
    // HTTP API v2 JWT authorizer exposes claims at authorizer.jwt.claims;
    // fall back to the v1 REST API shape just in case.
    const userId = ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
                 ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
    if (!userId) {
      return {
        statusCode: 401,
        headers: { "Access-Control-Allow-Origin": "*" },
        body: JSON.stringify({ error: "Unauthorized" }),
      };
    }

    const { track, tags, location, voiceMemoUrl, transcript } = JSON.parse(event.body || "{}");

    if (!track) {
      return {
        statusCode: 400,
        headers: { "Access-Control-Allow-Origin": "*" },
        body: JSON.stringify({ error: "Missing track" }),
      };
    }

    // Look up the user's handle and name — denormalize into every post so feed
    // reads need no extra joins. Handles are immutable so this is always accurate.
    const profileRecord = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${userId}`, sk: "profile" },
    }));

    const userHandle = profileRecord.Item?.handle as string | undefined;
    const userName = profileRecord.Item?.name as string | undefined;

    if (!userHandle) {
      return {
        statusCode: 400,
        headers: { "Access-Control-Allow-Origin": "*" },
        body: JSON.stringify({ error: "Handle not set — complete onboarding first" }),
      };
    }

    // Compute stable track key for grouping / duplicate detection
    const trackKey = computeTrackKey(track);

    // Duplicate share guard: reject if this user shared the same track within the window
    const windowStart = new Date(Date.now() - GROUPING_WINDOW_DAYS * 24 * 60 * 60 * 1000).toISOString();
    const recentCheck = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk AND sk > :minSk",
      FilterExpression: "trackKey = :trackKey",
      ExpressionAttributeValues: {
        ":pk": `user#${userId}#posts`,
        ":minSk": `post#${new Date(Date.now() - GROUPING_WINDOW_DAYS * 24 * 60 * 60 * 1000).getTime()}`,
        ":trackKey": trackKey,
      },
      Limit: 1,
    }));

    if (recentCheck.Items && recentCheck.Items.length > 0) {
      const existing = recentCheck.Items[0];
      const sharedAt = new Date(existing.createdAt as string);
      const daysSince = Math.floor((Date.now() - sharedAt.getTime()) / (1000 * 60 * 60 * 24));
      return {
        statusCode: 409,
        headers: { "Access-Control-Allow-Origin": "*" },
        body: JSON.stringify({
          error: `You shared this track ${daysSince === 0 ? "today" : `${daysSince} day${daysSince === 1 ? "" : "s"} ago`}`,
          daysSince,
          existingPostId: existing.postId,
        }),
      };
    }

    const timestamp = Date.now();
    const postId = `post-${timestamp}-${Math.random().toString(36).substr(2, 9)}`;

    const postBase = {
      pk: `user#${userId}#posts`,
      sk: `post#${timestamp}#${postId}`,
      postId,
      userId,
      userHandle,
      userName,
      track,
      trackKey,
      voiceMemoUrl: voiceMemoUrl || null,
      transcript: transcript || null,
      tags: tags || [],
      createdAt: new Date().toISOString(),
      timestamp,
      likes: 0,
      reposts: 0,
      // Global feed index — every post is queryable as a reverse-chron global feed
      gsi1pk: "global#feed",
      gsi1sk: `${timestamp}#${postId}`,
    };

    let locationHex: string | undefined;
    const post =
      location?.latitude && location?.longitude
        ? {
            ...postBase,
            location: {
              latitude: location.latitude as number,
              longitude: location.longitude as number,
              hex: (locationHex = latLngToCell(location.latitude, location.longitude, LOCATION_RESOLUTION)),
              resolution: LOCATION_RESOLUTION,
            },
          }
        : postBase;

    await ddb.send(new PutCommand({ TableName: process.env.TABLE_NAME, Item: post }));

    // Also write to the location-keyed records for nearby discovery
    if (locationHex) {
      const locationData = (post as any).location;
      const locationBase = {
        postId,
        userId,
        userHandle,
        userName,
        track,
        trackKey,
        voiceMemoUrl: voiceMemoUrl || null,
        transcript: transcript || null,
        tags: tags || [],
        createdAt: post.createdAt,
        location: locationData,
      };

      // Primary hex
      await ddb.send(new PutCommand({
        TableName: process.env.TABLE_NAME,
        Item: {
          pk: `location#${locationHex}`,
          sk: `${timestamp}#${postId}`,
          gsi1pk: `location#${locationHex}`,
          gsi1sk: `${timestamp}#${postId}`,
          ...locationBase,
          ttl: Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
        },
      }));

      // Adjacent hexes for discovery
      for (const hex of gridDisk(locationHex, 1)) {
        if (hex === locationHex) continue;
        await ddb.send(new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: {
            pk: `location#${hex}`,
            sk: `${timestamp}#${postId}`,
            gsi1pk: `location#${hex}`,
            gsi1sk: `${timestamp}#${postId}`,
            ...locationBase,
            nearby: true,
            ttl: Math.floor(Date.now() / 1000) + 3 * 24 * 60 * 60,
          },
        }));
      }
    }

    return {
      statusCode: 200,
      headers: { "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify({ status: "success", postId, locationHex }),
    };
  } catch (error) {
    console.error("Music share error:", error);
    return {
      statusCode: 500,
      headers: { "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify({ error: "Failed to share track" }),
    };
  }
};

export const like = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  const headers = { "Access-Control-Allow-Origin": "*" };
  try {
    const likerId = ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
                  ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
    if (!likerId) return { statusCode: 401, headers, body: JSON.stringify({ error: "Unauthorized" }) };

    const { postId, postOwnerId, action } = JSON.parse(event.body || "{}");
    if (!postId || !postOwnerId || !["like", "unlike"].includes(action)) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: "Missing postId, postOwnerId or action" }) };
    }

    if (action === "like") {
      // Write a like record — the stream picks this up to send a push to the post owner
      await ddb.send(new PutCommand({
        TableName: process.env.TABLE_NAME,
        Item: {
          pk: `like#${postId}`,
          sk: `user#${likerId}`,
          postId,
          postOwnerId,
          likerId,
          createdAt: new Date().toISOString(),
        },
        ConditionExpression: "attribute_not_exists(pk)", // idempotent — ignore duplicate likes
      })).catch(e => { if (e.name !== "ConditionalCheckFailedException") throw e; });

      // Increment likes counter on the post
      await ddb.send(new UpdateCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: `user#${postOwnerId}#posts`, sk: postId },
        UpdateExpression: "ADD likes :one",
        ExpressionAttributeValues: { ":one": 1 },
      }));
    } else {
      // Remove like record
      await ddb.send(new DeleteCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: `like#${postId}`, sk: `user#${likerId}` },
      }));

      // Decrement likes counter (floor at 0)
      await ddb.send(new UpdateCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: `user#${postOwnerId}#posts`, sk: postId },
        UpdateExpression: "ADD likes :neg",
        ConditionExpression: "likes > :zero",
        ExpressionAttributeValues: { ":neg": -1, ":zero": 0 },
      })).catch(e => { if (e.name !== "ConditionalCheckFailedException") throw e; });
    }

    return { statusCode: 200, headers, body: JSON.stringify({ success: true, action }) };
  } catch (error) {
    console.error("Like error:", error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Failed to process like" }) };
  }
};

export const getLocationFeed = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const { latitude, longitude } = event.queryStringParameters || {};

    if (!latitude || !longitude) {
      return { statusCode: 400, body: JSON.stringify({ error: "Missing latitude or longitude" }) };
    }

    const locationHex = latLngToCell(parseFloat(latitude), parseFloat(longitude), LOCATION_RESOLUTION);

    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: { ":pk": `location#${locationHex}` },
      ScanIndexForward: false,
      Limit: 50,
    }));

    const posts = (result.Items || []).map(item => ({
      postId: item.postId,
      userId: item.userId,
      userHandle: item.userHandle,
      userName: item.userName,
      track: item.track,
      comment: item.comment,
      tags: item.tags || [],
      createdAt: item.createdAt,
      location: item.location,
      nearby: item.nearby || false,
    }));

    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify({ posts, locationHex, hexBoundary: cellToBoundary(locationHex, true) }),
    };
  } catch (error) {
    console.error("Location feed error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Failed to get location feed" }) };
  }
};
