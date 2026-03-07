import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, QueryCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import crypto from "crypto";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

function getSub(event: APIGatewayProxyEvent): string | undefined {
  return ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
       ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
}

const CORS = { "Access-Control-Allow-Origin": "*" };

export const get = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const sub = getSub(event);
    if (!sub) return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };

    const result = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${sub}`, sk: "profile" },
    }));

    return {
      statusCode: 200,
      headers: CORS,
      body: JSON.stringify({
        userId: sub,
        handle: result.Item?.handle ?? null,
        name: result.Item?.name ?? null,
        email: result.Item?.email ?? null,
        bio: result.Item?.bio ?? null,
        avatarUrl: result.Item?.avatarUrl ?? null,
        location: result.Item?.location ?? null,
        providers: result.Item?.providers ?? [],
        createdAt: result.Item?.createdAt ?? null,
      }),
    };
  } catch (error) {
    console.error("GET /me error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Failed to get profile" }) };
  }
};

// PUT /me — update bio and/or location (city-level, supplied by client after reverse geocode)
export const update = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const sub = getSub(event);
    if (!sub) return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };

    const { bio, location } = JSON.parse(event.body || "{}") as {
      bio?: string;
      location?: { city?: string; country?: string };
    };

    const expressions: string[] = ["updatedAt = :now"];
    const names: Record<string, string> = {};
    const values: Record<string, any> = { ":now": new Date().toISOString() };

    if (bio !== undefined) {
      expressions.push("#bio = :bio");
      names["#bio"] = "bio";
      values[":bio"] = bio.slice(0, 160);
    }
    if (location !== undefined) {
      expressions.push("#loc = :loc");
      names["#loc"] = "location";
      values[":loc"] = location;
    }

    await ddb.send(new UpdateCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${sub}`, sk: "profile" },
      UpdateExpression: `SET ${expressions.join(", ")}`,
      ...(Object.keys(names).length && { ExpressionAttributeNames: names }),
      ExpressionAttributeValues: values,
    }));

    return { statusCode: 200, headers: CORS, body: JSON.stringify({ success: true }) };
  } catch (error) {
    console.error("PUT /me error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Failed to update profile" }) };
  }
};

// POST /me/avatar — return a presigned S3 PUT URL; client uploads directly then we store the CDN URL
export const avatarUploadUrl = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const sub = getSub(event);
    if (!sub) return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };

    const { contentType = "image/jpeg" } = JSON.parse(event.body || "{}");
    const allowed = ["image/jpeg", "image/png", "image/webp", "image/heic"];
    if (!allowed.includes(contentType)) {
      return { statusCode: 400, body: JSON.stringify({ error: "Unsupported content type" }) };
    }

    const ext = contentType.split("/")[1].replace("jpeg", "jpg");
    const key = `avatars/${sub}/${crypto.randomUUID()}.${ext}`;

    const presignedUrl = await getSignedUrl(
      s3,
      new PutObjectCommand({
        Bucket: process.env.AVATAR_BUCKET,
        Key: key,
        ContentType: contentType,
      }),
      { expiresIn: 300 }, // 5 minutes
    );

    // The public URL via CloudFront
    const avatarUrl = `${process.env.AVATAR_CDN_URL}/${key}`;

    // Persist the CDN URL to the profile immediately so it's ready after upload
    await ddb.send(new UpdateCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${sub}`, sk: "profile" },
      UpdateExpression: "SET avatarUrl = :url, updatedAt = :now",
      ExpressionAttributeValues: { ":url": avatarUrl, ":now": new Date().toISOString() },
    }));

    return {
      statusCode: 200,
      headers: CORS,
      body: JSON.stringify({ uploadUrl: presignedUrl, avatarUrl }),
    };
  } catch (error) {
    console.error("POST /me/avatar error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Failed to generate upload URL" }) };
  }
};

export const getPosts = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const sub = getSub(event);
    if (!sub) return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };

    const limit = parseInt(event.queryStringParameters?.limit || "20");
    const cursor = event.queryStringParameters?.cursor;

    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk AND begins_with(sk, :sk)",
      ExpressionAttributeValues: {
        ":pk": `user#${sub}#posts`,
        ":sk": "post#",
      },
      ScanIndexForward: false,
      Limit: limit,
      ...(cursor && { ExclusiveStartKey: JSON.parse(Buffer.from(cursor, "base64").toString()) }),
    }));

    return {
      statusCode: 200,
      headers: CORS,
      body: JSON.stringify({
        posts: result.Items || [],
        cursor: result.LastEvaluatedKey
          ? Buffer.from(JSON.stringify(result.LastEvaluatedKey)).toString("base64")
          : null,
      }),
    };
  } catch (error) {
    console.error("GET /me/posts error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Failed to get posts" }) };
  }
};
