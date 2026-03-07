import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminSetUserPasswordCommand,
  AdminInitiateAuthCommand,
  AdminUpdateUserAttributesCommand,
  AuthFlowType,
} from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import * as jwt from "jsonwebtoken";
import jwksClient from "jwks-rsa";
import crypto from "crypto";

const cognito = new CognitoIdentityProviderClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const appleJwksClient = jwksClient({
  jwksUri: "https://appleid.apple.com/auth/keys",
  cache: true,
  cacheMaxAge: 86400000,
});

// ── Helpers ───────────────────────────────────────────────────────────────────

async function verifyAppleToken(identityToken: string, expectedSub: string): Promise<Record<string, any>> {
  const decoded = jwt.decode(identityToken, { complete: true });
  if (!decoded || typeof decoded === "string" || !decoded.header.kid) {
    throw new Error("Invalid Apple identity token format");
  }

  const signingKey = await appleJwksClient.getSigningKey(decoded.header.kid);
  const publicKey = signingKey.getPublicKey();

  const payload = jwt.verify(identityToken, publicKey, {
    algorithms: ["RS256"],
    issuer: "https://appleid.apple.com",
    subject: expectedSub,
  }) as Record<string, any>;

  return payload;
}

function extractEmailFromAppleToken(identityToken: string): string | undefined {
  try {
    const decoded = jwt.decode(identityToken) as Record<string, any> | null;
    const email = decoded?.email as string | undefined;
    // Treat private relay emails as valid — they're stable per app per user
    return email || undefined;
  } catch {
    return undefined;
  }
}

async function issueTokens(userPoolId: string, clientId: string, username: string, password: string) {
  // Post-Nov-2024, all new Cognito pools have SignInPolicy: { AllowedFirstAuthFactors: ["PASSWORD"] }
  // which blocks CUSTOM_AUTH via AdminInitiateAuth regardless of tier or client ExplicitAuthFlows.
  // ADMIN_USER_PASSWORD_AUTH satisfies the PASSWORD policy and works correctly.
  // Apple token verification already happened server-side before this is called, so
  // using a server-stored password is equivalent in security to a custom challenge.
  const result = await cognito.send(new AdminInitiateAuthCommand({
    UserPoolId: userPoolId,
    ClientId: clientId,
    AuthFlow: AuthFlowType.ADMIN_USER_PASSWORD_AUTH,
    AuthParameters: { USERNAME: username, PASSWORD: password },
  }));

  return result.AuthenticationResult;
}

// ── POST /auth/apple ──────────────────────────────────────────────────────────
//
// Identity flow:
//   1. Verify Apple JWT signature
//   2. Look up provider#apple#<appleUserId> → cognitoSub
//   3a. Existing user → issue tokens
//   3b. New user → AdminCreateUser, write provider + profile records, issue tokens

export const apple = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const { identityToken, user: appleUserId, email: bodyEmail, name } = JSON.parse(event.body || "{}");

    if (!identityToken || !appleUserId) {
      return { statusCode: 400, body: JSON.stringify({ error: "Missing identityToken or user" }) };
    }

    const userPoolId = process.env.USER_POOL_ID!;
    const clientId = process.env.USER_POOL_CLIENT_ID!;

    // Step 1 — verify the Apple JWT
    let tokenPayload: Record<string, any>;
    try {
      tokenPayload = await verifyAppleToken(identityToken, appleUserId);
    } catch (err) {
      console.error("Apple token verification failed:", err);
      return { statusCode: 401, body: JSON.stringify({ error: "Invalid Apple identity token" }) };
    }

    // Email: prefer body (first sign-in), fall back to token claim (private relay on repeat sign-ins)
    const email = (bodyEmail as string) || extractEmailFromAppleToken(identityToken);

    // Step 2 — look up existing provider mapping
    const providerKey = { pk: `provider#apple#${appleUserId}`, sk: "lookup" };
    const providerRecord = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: providerKey,
    }));

    let cognitoSub: string;
    let existingUser = false;
    let handle: string | undefined;
    let password: string;

    if (providerRecord.Item) {
      // ── Existing user ──────────────────────────────────────────────────────
      cognitoSub = providerRecord.Item.userId as string;
      existingUser = true;

      if (providerRecord.Item.password) {
        password = providerRecord.Item.password as string;
      } else {
        // Migration path: old provider record has no password field.
        // Generate one, set it on Cognito, and save it back to DynamoDB.
        password = crypto.randomBytes(64).toString("hex") + "aB1!";
        await cognito.send(new AdminSetUserPasswordCommand({
          UserPoolId: userPoolId,
          Username: appleUserId,
          Password: password,
          Permanent: true,
        }));
        await ddb.send(new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: { ...providerRecord.Item, password },
        }));
      }

      // Fetch profile to return handle in response
      const profileRecord = await ddb.send(new GetCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: `user#${cognitoSub}`, sk: "profile" },
      }));
      handle = profileRecord.Item?.handle as string | undefined;
    } else {
      // ── New user (or orphaned: Cognito user exists but DDB provider record was cleared) ──
      // Create a Cognito user. Username = appleUserId (opaque, never shown to users).
      // The stable internal ID is the Cognito sub UUID assigned by Cognito.
      password = crypto.randomBytes(64).toString("hex") + "aB1!";

      const emailAttrs: { Name: string; Value: string }[] = email
        ? [{ Name: "email", Value: email }]
        : [];

      let createSub: string;

      try {
        const createResult = await cognito.send(new AdminCreateUserCommand({
          UserPoolId: userPoolId,
          Username: appleUserId,
          MessageAction: "SUPPRESS", // don't send welcome email
          TemporaryPassword: password,
          UserAttributes: [
            ...emailAttrs,
            { Name: "email_verified", Value: "true" },
          ],
        }));

        const subAttr = createResult.User?.Attributes?.find(a => a.Name === "sub");
        if (!subAttr?.Value) throw new Error("Cognito did not return sub for new user");
        createSub = subAttr.Value;
      } catch (err: any) {
        if (err.name !== "UsernameExistsException") throw err;

        // Recovery: Cognito user exists but DDB provider record was wiped (e.g. seed:clear).
        // Fetch the existing user's sub, generate a new password, and re-create the provider record.
        console.log(`UsernameExistsException for ${appleUserId} — recovering orphaned Cognito user`);
        const existing = await cognito.send(new AdminGetUserCommand({
          UserPoolId: userPoolId,
          Username: appleUserId,
        }));
        const subAttr = existing.UserAttributes?.find(a => a.Name === "sub");
        if (!subAttr?.Value) throw new Error("Could not retrieve sub for existing Cognito user");
        createSub = subAttr.Value;
        existingUser = true; // Cognito user exists — treat as returning user
      }

      cognitoSub = createSub;

      // Set permanent password — ADMIN_USER_PASSWORD_AUTH requires CONFIRMED status
      await cognito.send(new AdminSetUserPasswordCommand({
        UserPoolId: userPoolId,
        Username: appleUserId,
        Password: password,
        Permanent: true,
      }));

      const now = new Date().toISOString();

      // Write provider mapping — includes password so future sign-ins can authenticate
      await ddb.send(new PutCommand({
        TableName: process.env.TABLE_NAME,
        Item: {
          pk: `provider#apple#${appleUserId}`,
          sk: "lookup",
          userId: cognitoSub,
          password,
          createdAt: now,
        },
      }));

      // Write user profile only if it doesn't already exist (recovery case may have a profile)
      const existingProfile = await ddb.send(new GetCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: `user#${cognitoSub}`, sk: "profile" },
      }));
      if (!existingProfile.Item) {
        await ddb.send(new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: {
            pk: `user#${cognitoSub}`,
            sk: "profile",
            userId: cognitoSub,
            email: email || null,
            name: name || null,
            providers: ["apple"],
            createdAt: now,
            updatedAt: now,
          },
        }));
      } else {
        handle = existingProfile.Item.handle as string | undefined;
      }
    }

    // Step 3 — issue Cognito tokens
    const tokens = await issueTokens(userPoolId, clientId, appleUserId, password);
    if (!tokens) {
      throw new Error("Failed to issue tokens");
    }

    return {
      statusCode: 200,
      body: JSON.stringify({
        idToken: tokens.IdToken,
        accessToken: tokens.AccessToken,
        refreshToken: tokens.RefreshToken,
        existingUser,
        hasHandle: !!handle,
      }),
    };
  } catch (error) {
    console.error("Apple Sign In error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Internal server error" }) };
  }
};

// ── POST /me/handle ───────────────────────────────────────────────────────────
//
// Called once after first sign-in to set the user's public handle.
// sub comes from the verified JWT — no body field needed.
// Handles are permanent (no rename) to keep denormalized post data consistent.

const HANDLE_RE = /^[a-z0-9_]{3,20}$/;

export const setHandle = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    // HTTP API v2 JWT authorizer exposes claims at authorizer.jwt.claims;
    // fall back to the v1 REST API shape just in case.
    const sub = ((event.requestContext.authorizer as any)?.jwt?.claims?.sub
              ?? event.requestContext.authorizer?.claims?.sub) as string | undefined;
    if (!sub) {
      return { statusCode: 401, body: JSON.stringify({ error: "Unauthorized" }) };
    }

    const { handle } = JSON.parse(event.body || "{}");
    if (!handle || !HANDLE_RE.test(handle)) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "Handle must be 3–20 chars: lowercase letters, numbers, underscores" }),
      };
    }

    // Check the user doesn't already have a handle
    const profileRecord = await ddb.send(new GetCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${sub}`, sk: "profile" },
    }));

    if (profileRecord.Item?.handle) {
      return {
        statusCode: 409,
        body: JSON.stringify({ error: "Handle already set", handle: profileRecord.Item.handle }),
      };
    }

    // Reserve the handle — conditional write so two concurrent requests can't both claim it
    try {
      await ddb.send(new PutCommand({
        TableName: process.env.TABLE_NAME,
        Item: {
          pk: `handle#${handle}`,
          sk: "lookup",
          userId: sub,
          createdAt: new Date().toISOString(),
        },
        ConditionExpression: "attribute_not_exists(pk)",
      }));
    } catch (err: any) {
      if (err.name === "ConditionalCheckFailedException") {
        return { statusCode: 409, body: JSON.stringify({ error: "Handle already taken" }) };
      }
      throw err;
    }

    // Update the user profile with the handle
    await ddb.send(new UpdateCommand({
      TableName: process.env.TABLE_NAME,
      Key: { pk: `user#${sub}`, sk: "profile" },
      UpdateExpression: "SET #h = :h, updatedAt = :now",
      ExpressionAttributeNames: { "#h": "handle" },
      ExpressionAttributeValues: { ":h": handle, ":now": new Date().toISOString() },
    }));

    // Mirror handle onto Cognito user attribute (optional but useful for admin visibility)
    try {
      await cognito.send(new AdminUpdateUserAttributesCommand({
        UserPoolId: process.env.USER_POOL_ID!,
        Username: sub, // Cognito allows lookup by sub
        UserAttributes: [{ Name: "custom:handle", Value: handle }],
      }));
    } catch {
      // Non-fatal — profile is the source of truth
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ handle }),
    };
  } catch (error) {
    console.error("setHandle error:", error);
    return { statusCode: 500, body: JSON.stringify({ error: "Internal server error" }) };
  }
};
