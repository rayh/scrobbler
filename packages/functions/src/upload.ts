import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, UpdateCommand, GetCommand } from "@aws-sdk/lib-dynamodb";
import {
  S3Client,
  PutObjectCommand,
  HeadObjectCommand,
  DeleteObjectCommand,
  ListObjectVersionsCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { APIGatewayProxyEvent, APIGatewayProxyResult, S3Event } from "aws-lambda";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});
const CORS = { "Access-Control-Allow-Origin": "*" };

type UploadType = "avatar" | "post-image" | "voice";

// Max sizes: 2MB for images, 10MB for voice
const MAX_BYTES: Record<UploadType, number> = {
  "avatar":     2 * 1024 * 1024,
  "post-image": 2 * 1024 * 1024,
  "voice":      10 * 1024 * 1024,
};

const ALLOWED_CONTENT_TYPES: Record<UploadType, string> = {
  "avatar":     "image/webp",
  "post-image": "image/webp",
  "voice":      "audio/m4a",
};

function getSub(event: APIGatewayProxyEvent): string | undefined {
  return ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
       ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
}

function s3Key(userId: string, type: UploadType, postId?: string): string {
  const ts = Date.now();
  switch (type) {
    case "avatar":
      return `uploads/${userId}/avatars/${ts}.webp`;
    case "post-image":
      if (!postId) throw new Error("postId required for post-image");
      return `uploads/${userId}/posts/${postId}/images/${ts}.webp`;
    case "voice":
      if (!postId) throw new Error("postId required for voice");
      return `uploads/${userId}/posts/${postId}/voice/${ts}.m4a`;
  }
}

// ── POST /upload/request ────────────────────────────────────────────────────
// Returns a pre-signed PUT URL and the deterministic CDN URL.
// The CDN URL is valid as soon as the client completes the upload.
export const request = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const userId = getSub(event);
    if (!userId) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: "Unauthorized" }) };

    const { type, postId } = JSON.parse(event.body || "{}") as { type?: UploadType; postId?: string };

    if (!type || !["avatar", "post-image", "voice"].includes(type)) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: "type must be avatar | post-image | voice" }) };
    }
    if ((type === "post-image" || type === "voice") && !postId) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: "postId required" }) };
    }

    // Verify user profile exists (so orphaned uploads can't be created for non-existent users)
    const profile = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${userId}`, sk: "profile" },
    }));
    if (!profile.Item) {
      return { statusCode: 403, headers: CORS, body: JSON.stringify({ error: "Profile not found" }) };
    }

    const contentType = ALLOWED_CONTENT_TYPES[type];
    const key = s3Key(userId, type, postId);
    const bucket = process.env.UPLOADS_BUCKET!;
    const cdnUrl = `${process.env.UPLOADS_CDN_URL}/${key}`;

    const uploadUrl = await getSignedUrl(
      s3,
      new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        ContentType: contentType,
        // Embed metadata so the validation Lambda can act without parsing the key
        Metadata: {
          userid: userId,
          uploadtype: type,
          ...(postId && { postid: postId }),
        },
      }),
      { expiresIn: 300 }, // 5 minutes
    );

    return {
      statusCode: 200,
      headers: CORS,
      body: JSON.stringify({ uploadUrl, cdnUrl, key }),
    };
  } catch (err) {
    console.error("POST /upload/request error:", err);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: "Failed to generate upload URL" }) };
  }
};

// ── S3 ObjectCreated → validate ─────────────────────────────────────────────
// Reads only object metadata (HeadObject — no bytes).
// Validates content-type and size, updates DynamoDB, cleans up old avatar versions.
export const validate = async (event: S3Event): Promise<void> => {
  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    // S3 keys in events are URL-encoded
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    console.log(`Validating upload: ${key}`);

    try {
      const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));

      const userId   = head.Metadata?.userid;
      const uploadType = head.Metadata?.uploadtype as UploadType | undefined;
      const postId   = head.Metadata?.postid;
      const size     = head.ContentLength ?? 0;
      const ct       = head.ContentType ?? "";

      if (!userId || !uploadType) {
        console.warn(`Missing metadata on ${key}, deleting`);
        await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
        continue;
      }

      const expectedCt = ALLOWED_CONTENT_TYPES[uploadType];
      const maxBytes   = MAX_BYTES[uploadType];

      if (ct !== expectedCt || size > maxBytes) {
        console.warn(`Invalid upload ${key}: ct=${ct} size=${size}, deleting`);
        await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
        continue;
      }

      const cdnUrl = `${process.env.UPLOADS_CDN_URL}/${key}`;

      // Update DynamoDB based on upload type
      if (uploadType === "avatar") {
        // Fetch old avatar URL before overwriting so we can expire the old version
        const profile = await ddb.send(new GetCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: `user#${userId}`, sk: "profile" },
        }));
        const oldAvatarUrl: string | undefined = profile.Item?.avatarUrl;

        await ddb.send(new UpdateCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: `user#${userId}`, sk: "profile" },
          UpdateExpression: "SET avatarUrl = :url, updatedAt = :now",
          ExpressionAttributeValues: { ":url": cdnUrl, ":now": new Date().toISOString() },
        }));

        // Delete all non-current versions of the old avatar key to free storage
        // (current version is retained by S3 versioning; lifecycle handles expiry)
        if (oldAvatarUrl) {
          const oldKey = oldAvatarUrl.replace(`${process.env.UPLOADS_CDN_URL}/`, "");
          if (oldKey !== key) {
            await deleteNonCurrentVersions(bucket, oldKey);
          }
        }
      } else if (uploadType === "post-image" && postId) {
        // Store image CDN URL on the post record
        await ddb.send(new UpdateCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: `user#${userId}#posts`, sk: `post#${postId}` },
          UpdateExpression: "SET imageUrl = :url, updatedAt = :now",
          ExpressionAttributeValues: { ":url": cdnUrl, ":now": new Date().toISOString() },
        }));
      } else if (uploadType === "voice" && postId) {
        // Store voice memo CDN URL on the post record
        await ddb.send(new UpdateCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: `user#${userId}#posts`, sk: `post#${postId}` },
          UpdateExpression: "SET voiceMemoUrl = :url, updatedAt = :now",
          ExpressionAttributeValues: { ":url": cdnUrl, ":now": new Date().toISOString() },
        }));
      }

      console.log(`Validated and recorded ${key} → ${cdnUrl}`);
    } catch (err) {
      console.error(`Error validating ${key}:`, err);
    }
  }
};

// Delete all non-current versions of a key (called after avatar replacement)
async function deleteNonCurrentVersions(bucket: string, key: string): Promise<void> {
  try {
    const versions = await s3.send(new ListObjectVersionsCommand({ Bucket: bucket, Prefix: key }));
    const toDelete = [
      ...(versions.Versions ?? []).filter(v => !v.IsLatest),
      ...(versions.DeleteMarkers ?? []),
    ];
    for (const v of toDelete) {
      if (v.VersionId) {
        await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key, VersionId: v.VersionId }));
      }
    }
  } catch (err) {
    console.warn(`Failed to clean old versions for ${key}:`, err);
  }
}
