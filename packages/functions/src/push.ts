import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, DeleteCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { SNSClient, CreatePlatformEndpointCommand, DeleteEndpointCommand, GetEndpointAttributesCommand, SetEndpointAttributesCommand } from "@aws-sdk/client-sns";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);
const sns = new SNSClient({});

export const register = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    // Extract userId from Authorization header (Cognito identity)
    // HTTP API v2 JWT authorizer exposes claims at authorizer.jwt.claims;
    // fall back to the v1 REST API shape just in case.
    const userId = (event.requestContext.authorizer as any)?.jwt?.claims?.sub
                ?? event.requestContext.authorizer?.claims?.sub
                ?? (event.requestContext as any)?.identity?.cognitoIdentityId;
    
    if (!userId) {
      return {
        statusCode: 401,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Headers": "Content-Type,Authorization",
          "Access-Control-Allow-Methods": "POST, OPTIONS"
        },
        body: JSON.stringify({ error: "Unauthorized" })
      };
    }

    const { deviceToken, platform } = JSON.parse(event.body || "{}");
    
    if (!deviceToken || !platform) {
      return {
        statusCode: 400,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Headers": "Content-Type,Authorization",
          "Access-Control-Allow-Methods": "POST, OPTIONS"
        },
        body: JSON.stringify({ error: "Missing deviceToken or platform" })
      };
    }

    const platformAppArn = platform === "ios" 
      ? process.env.SNS_PLATFORM_APP_ARN_IOS 
      : process.env.SNS_PLATFORM_APP_ARN_ANDROID;

    if (!platformAppArn) {
      throw new Error(`No platform app ARN configured for ${platform}`);
    }

    // Create SNS endpoint (idempotent — returns existing ARN if token already registered)
    const createResult = await sns.send(new CreatePlatformEndpointCommand({
      PlatformApplicationArn: platformAppArn,
      Token: deviceToken,
      CustomUserData: userId
    }));

    if (!createResult.EndpointArn) {
      throw new Error("Failed to create SNS endpoint");
    }

    const endpointArn = createResult.EndpointArn;

    // Check if the existing endpoint is enabled and has the correct token.
    // SNS disables endpoints when APNS rejects a push (stale/rotated token).
    // Re-enable it and update the token if needed.
    const attrs = await sns.send(new GetEndpointAttributesCommand({ EndpointArn: endpointArn }));
    const needsUpdate = attrs.Attributes?.Enabled === "false" || attrs.Attributes?.Token !== deviceToken;
    if (needsUpdate) {
      await sns.send(new SetEndpointAttributesCommand({
        EndpointArn: endpointArn,
        Attributes: { Enabled: "true", Token: deviceToken }
      }));
    }

    // Remove any stale endpoints for this user+platform that have a different device token.
    // This handles the case where APNS rotated the token — the old endpoint is defunct
    // and would just accumulate and fail on send.
    const existing = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: { ":pk": `user#${userId}#endpoints` }
    }));
    const stale = (existing.Items ?? []).filter(
      item => item.platform === platform && item.deviceToken !== deviceToken
    );
    await Promise.all(stale.map(async item => {
      await sns.send(new DeleteEndpointCommand({ EndpointArn: item.endpointArn })).catch(() => {});
      await ddb.send(new DeleteCommand({
        TableName: process.env.TABLE_NAME!,
        Key: { pk: item.pk, sk: item.sk }
      }));
    }));

    // Store endpoint in DynamoDB
    await ddb.send(new PutCommand({
      TableName: process.env.TABLE_NAME,
      Item: {
        pk: `user#${userId}#endpoints`,
        sk: endpointArn,
        endpointArn: endpointArn,
        platform,
        deviceToken,
        registeredAt: new Date().toISOString()
      }
    }));

    return {
      statusCode: 200,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,Authorization",
        "Access-Control-Allow-Methods": "POST, OPTIONS"
      },
      body: JSON.stringify({ 
        status: "success",
        endpointArn: endpointArn
      })
    };

  } catch (error) {
    console.error("Push registration error:", error);
    return {
      statusCode: 500,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,Authorization",
        "Access-Control-Allow-Methods": "POST, OPTIONS"
      },
      body: JSON.stringify({ error: "Registration failed" })
    };
  }
};

export async function removeEndpoint(pk: string, sk: string) {
  await ddb.send(new DeleteCommand({
    TableName: process.env.TABLE_NAME!,
    Key: { pk, sk },
  }));
}
