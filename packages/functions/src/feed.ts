import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);

export const following = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    // HTTP API v2 JWT authorizer exposes claims at authorizer.jwt.claims;
    // fall back to the v1 REST API shape just in case.
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

    // Get user's timeline (posts from people they follow)
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
    console.error("Feed following error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Failed to get feed" })
    };
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
