import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const CORS = { "Access-Control-Allow-Origin": "*" };

export const getProfile = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const handle = event.pathParameters?.handle?.toLowerCase();
    if (!handle) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: "Missing handle" }) };
    }

    // Resolve handle → userId
    const handleRecord = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `handle#${handle}`, sk: "lookup" },
    }));
    if (!handleRecord.Item) {
      return { statusCode: 404, headers: CORS, body: JSON.stringify({ error: "User not found" }) };
    }
    const userId = handleRecord.Item.userId as string;

    // Fetch profile + posts in parallel
    const [profileResult, postsResult] = await Promise.all([
      ddb.send(new GetCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: `user#${userId}`, sk: "profile" },
      })),
      ddb.send(new QueryCommand({
        TableName: process.env.TABLE_NAME,
        KeyConditionExpression: "pk = :pk AND begins_with(sk, :sk)",
        ExpressionAttributeValues: {
          ":pk": `user#${userId}#posts`,
          ":sk": "post#",
        },
        ScanIndexForward: false,
        Limit: 20,
      })),
    ]);

    if (!profileResult.Item) {
      return { statusCode: 404, headers: CORS, body: JSON.stringify({ error: "Profile not found" }) };
    }

    const profile = profileResult.Item;
    const posts = (postsResult.Items || []).map(item => ({
      postId: item.postId,
      userId: item.userId,
      userHandle: item.userHandle,
      userName: item.userName,
      track: item.track,
      comment: item.comment,
      tags: item.tags || [],
      createdAt: item.createdAt,
    }));

    return {
      statusCode: 200,
      headers: CORS,
      body: JSON.stringify({
        userId,
        handle: profile.handle,
        name: profile.name ?? null,
        bio: profile.bio ?? null,
        avatarUrl: profile.avatarUrl ?? null,
        location: profile.location ?? null,
        createdAt: profile.createdAt ?? null,
        posts,
      }),
    };
  } catch (error) {
    console.error("GET /users/:handle error:", error);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: "Failed to get profile" }) };
  }
};
