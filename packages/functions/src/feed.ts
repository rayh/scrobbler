import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);

export const following = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const userId = (event.requestContext.authorizer as any)?.jwt?.claims?.sub
                ?? event.requestContext.authorizer?.claims?.sub;
    
    if (!userId) {
      return {
        statusCode: 401,
        body: JSON.stringify({ error: "Unauthorized" })
      };
    }

    const limit = parseInt(event.queryStringParameters?.limit || "20");
    const cursor = event.queryStringParameters?.cursor;

    // Query the user's materialized timeline — pre-grouped by fanout worker
    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: {
        ":pk": `timeline#${userId}`
      },
      ScanIndexForward: false,
      Limit: limit,
      ...(cursor && { ExclusiveStartKey: JSON.parse(Buffer.from(cursor, 'base64').toString()) })
    }));

    const groups = (result.Items || []).map(item => {
      // New grouped format: sk starts with "post#<timestamp>#<trackKey>" and has sharedBy[]
      const isGrouped = Array.isArray(item.sharedBy);

      if (isGrouped) {
        return {
          groupId:       item.sk,
          trackKey:      item.trackKey,
          track: {
            id:           item.track?.id,
            title:        item.track?.title,
            artist:       item.track?.artist,
            album:        item.track?.album,
            artwork:      item.track?.artworkUrl || item.track?.artwork,
            appleMusicUrl: item.track?.appleMusicUrl,
          },
          windowStart:   item.windowStart,
          lastUpdatedAt: item.lastUpdatedAt,
          sharedBy: (item.sharedBy as any[]).map(s => ({
            postId:       s.postId,
            userId:       s.userId,
            userHandle:   s.userHandle,
            voiceMemoUrl: s.voiceMemoUrl ?? null,
            transcript:   s.transcript ?? null,
            tags:         s.tags ?? [],
            createdAt:    s.createdAt,
          })),
          likes:    item.likes || 0,
          location: item.location ?? null,
        };
      }

      // Legacy flat post format (old timeline items, TTL 30 days — handled gracefully)
      return {
        groupId:       item.sk,
        trackKey:      item.trackKey ?? null,
        track: {
          id:           item.track?.id,
          title:        item.track?.title,
          artist:       item.track?.artist,
          album:        item.track?.album,
          artwork:      item.track?.artworkUrl || item.track?.artwork,
          appleMusicUrl: item.track?.appleMusicUrl,
        },
        windowStart:   item.createdAt,
        lastUpdatedAt: item.createdAt,
        sharedBy: [{
          postId:       item.postId,
          userId:       item.userId,
          userHandle:   item.userHandle,
          voiceMemoUrl: item.voiceMemoUrl ?? null,
          transcript:   item.comment ?? item.transcript ?? null,
          tags:         item.tags ?? [],
          createdAt:    item.createdAt,
        }],
        likes:    item.likes || 0,
        location: item.location ?? null,
      };
    });

    return {
      statusCode: 200,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*"
      },
      body: JSON.stringify({ 
        groups,
        cursor: result.LastEvaluatedKey ? Buffer.from(JSON.stringify(result.LastEvaluatedKey)).toString('base64') : null
      })
    };

  } catch (error) {
    console.error("Feed following error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Failed to get feed" })
    };
  }
};

/**
 * GET /feed/public — unauthenticated global recent posts, newest first.
 * Used by the landing page for the live feed display.
 * Queries GSI1 on gsi1pk = "global#feed".
 */
export const publicFeed = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
  };
  try {
    const limit = Math.min(parseInt(event.queryStringParameters?.limit || "20"), 50);
    const cursor = event.queryStringParameters?.cursor;

    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      IndexName: "GSI1",
      KeyConditionExpression: "gsi1pk = :pk",
      ExpressionAttributeValues: { ":pk": "global#feed" },
      ScanIndexForward: false,
      Limit: limit,
      ...(cursor && { ExclusiveStartKey: JSON.parse(Buffer.from(cursor, "base64").toString()) }),
    }));

    const posts = (result.Items || []).map(item => ({
      postId: item.postId,
      userId: item.userId,
      userHandle: item.userHandle,
      userName: item.userName,
      track: {
        id: item.track?.id,
        title: item.track?.title,
        artist: item.track?.artist,
        album: item.track?.album,
        artwork: item.track?.artworkUrl || item.track?.artwork,
        appleMusicUrl: item.track?.appleMusicUrl,
      },
      comment: item.comment,
      tags: item.tags || [],
      createdAt: item.createdAt,
      likes: item.likes || 0,
    }));

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        posts,
        cursor: result.LastEvaluatedKey
          ? Buffer.from(JSON.stringify(result.LastEvaluatedKey)).toString("base64")
          : null,
      }),
    };
  } catch (error) {
    console.error("Public feed error:", error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Failed to get feed" }) };
  }
};

export const nearby = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const userId = (event.requestContext.authorizer as any)?.jwt?.claims?.sub
                ?? event.requestContext.authorizer?.claims?.sub;
    
    if (!userId) {
      return {
        statusCode: 401,
        body: JSON.stringify({ error: "Unauthorized" })
      };
    }

    const limit = parseInt(event.queryStringParameters?.limit || "20");
    const cursor = event.queryStringParameters?.cursor;
    const h3Index = event.queryStringParameters?.h3Index;

    if (!h3Index) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "Missing h3Index" })
      };
    }

    // Get posts from nearby location
    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      IndexName: "GSI1",
      KeyConditionExpression: "gsi1pk = :pk",
      ExpressionAttributeValues: {
        ":pk": `location#${h3Index}`
      },
      ScanIndexForward: false,
      Limit: limit,
      ...(cursor && { ExclusiveStartKey: JSON.parse(Buffer.from(cursor, 'base64').toString()) })
    }));

    const posts = result.Items?.map(item => ({
      postId: item.postId,
      userId: item.userId,
      userHandle: item.userHandle,
      userName: item.userName,
      track: {
        id: item.track?.id,
        title: item.track?.title,
        artist: item.track?.artist,
        album: item.track?.album,
        artwork: item.track?.artworkUrl || item.track?.artwork,
        appleMusicUrl: item.track?.appleMusicUrl
      },
      comment: item.comment,
      tags: item.tags || [],
      createdAt: item.createdAt,
      likes: item.likes || 0,
      reposts: item.reposts || 0
    })) || [];

    return {
      statusCode: 200,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*"
      },
      body: JSON.stringify({ 
        posts,
        cursor: result.LastEvaluatedKey ? Buffer.from(JSON.stringify(result.LastEvaluatedKey)).toString('base64') : null
      })
    };

  } catch (error) {
    console.error("Feed nearby error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Failed to get nearby feed" })
    };
  }
};
