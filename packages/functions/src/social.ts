import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, DeleteCommand, GetCommand, QueryCommand, BatchWriteCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const following = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const sub = ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
              ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
    if (!sub) {
      return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };
    }

    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: { ":pk": `user#${sub}#following` },
      ScanIndexForward: false,
    }));

    const following = (result.Items || []).map(item => ({
      handle: item.targetHandle as string,
      userId: item.targetUserId as string,
      followedAt: item.createdAt as string,
    }));

    return {
      statusCode: 200,
      headers: { "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify({ following }),
    };
  } catch (error) {
    console.error("following error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Internal server error" }) };
  }
};

export const follow = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    // sub is the stable Cognito UUID for the authenticated user.
    // HTTP API v2 JWT authorizer exposes claims at authorizer.jwt.claims;
    // fall back to the v1 REST API shape just in case.
    const sub = ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
              ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
    if (!sub) {
      return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };
    }

    const { targetHandle, action } = JSON.parse(event.body || "{}");
    if (!targetHandle || !["follow", "unfollow"].includes(action)) {
      return { statusCode: 400, body: JSON.stringify({ error: "Invalid request" }) };
    }

    // Get current user's profile (need their handle for denormalization)
    const currentProfile = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${sub}`, sk: "profile" },
    }));
    if (!currentProfile.Item) {
      return { statusCode: 404, body: JSON.stringify({ error: "Your profile not found" }) };
    }
    const currentHandle = currentProfile.Item.handle as string;

    // Resolve target handle → userId
    const handleRecord = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `handle#${targetHandle}`, sk: "lookup" },
    }));
    if (!handleRecord.Item) {
      return { statusCode: 404, body: JSON.stringify({ error: "Target user not found" }) };
    }
    const targetSub = handleRecord.Item.userId as string;

    if (targetSub === sub) {
      return { statusCode: 400, body: JSON.stringify({ error: "Cannot follow yourself" }) };
    }

    const now = new Date().toISOString();

    if (action === "follow") {
      // Write both sides of the relationship in parallel
      await Promise.all([
        ddb.send(new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: {
            pk: `user#${sub}#following`,
            sk: `user#${targetSub}`,
            userId: sub,
            targetUserId: targetSub,
            targetHandle,
            createdAt: now,
          },
        })),
        ddb.send(new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: {
            pk: `user#${targetSub}#followers`,
            sk: `user#${sub}`,
            userId: targetSub,
            followerId: sub,
            followerHandle: currentHandle,
            createdAt: now,
          },
        })),
      ]);

      // Backfill the last 10 posts from target into current user's timeline
      const recentPosts = await ddb.send(new QueryCommand({
        TableName: process.env.TABLE_NAME,
        KeyConditionExpression: "pk = :pk AND begins_with(sk, :sk)",
        ExpressionAttributeValues: {
          ":pk": `user#${targetSub}#posts`,
          ":sk": "post#",
        },
        ScanIndexForward: false,
        Limit: 10,
      }));

      await Promise.all((recentPosts.Items || []).map(post =>
        ddb.send(new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: {
            ...post,
            pk: `timeline#${sub}`,
            ttl: Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
          },
        }))
      ));
    } else {
      // Unfollow — remove both follow edges and prune their posts from the timeline
      await Promise.all([
        ddb.send(new DeleteCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: `user#${sub}#following`, sk: `user#${targetSub}` },
        })),
        ddb.send(new DeleteCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: `user#${targetSub}#followers`, sk: `user#${sub}` },
        })),
      ]);

      // Prune all of the unfollowed user's posts from the timeline.
      // Query the timeline partition and delete any item whose userId matches targetSub.
      let lastKey: Record<string, any> | undefined;
      do {
        const page = await ddb.send(new QueryCommand({
          TableName: process.env.TABLE_NAME,
          KeyConditionExpression: "pk = :pk",
          FilterExpression: "userId = :uid",
          ExpressionAttributeValues: { ":pk": `timeline#${sub}`, ":uid": targetSub },
          ExclusiveStartKey: lastKey,
        }));

        const toDelete = page.Items || [];
        // BatchWrite accepts max 25 items per call
        for (let i = 0; i < toDelete.length; i += 25) {
          await ddb.send(new BatchWriteCommand({
            RequestItems: {
              [process.env.TABLE_NAME!]: toDelete.slice(i, i + 25).map(item => ({
                DeleteRequest: { Key: { pk: item.pk, sk: item.sk } },
              })),
            },
          }));
        }

        lastKey = page.LastEvaluatedKey;
      } while (lastKey);
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ success: true, action, target: targetHandle, targetUserId: targetSub }),
    };
  } catch (error) {
    console.error("follow error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Internal server error" }) };
  }
};
