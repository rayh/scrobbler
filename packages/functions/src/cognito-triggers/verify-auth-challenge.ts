import { VerifyAuthChallengeResponseTriggerHandler } from "aws-lambda";
import * as jwt from "jsonwebtoken";
import jwksClient from "jwks-rsa";

const client = jwksClient({
  jwksUri: "https://appleid.apple.com/auth/keys",
  cache: true,
  cacheMaxAge: 86400000,
});

// When auth is initiated via AdminInitiateAuth (server-side, already verified),
// auth.ts passes the sentinel "ADMIN_VERIFIED" as the challenge answer.
// We approve it directly — the Apple token was already verified before Cognito was called.
const ADMIN_VERIFIED_SENTINEL = "ADMIN_VERIFIED";

export const handler: VerifyAuthChallengeResponseTriggerHandler = async (event) => {
  console.log("VerifyAuthChallenge event:", JSON.stringify({
    triggerSource: event.triggerSource,
    userName: event.userName,
    answer: event.request.challengeAnswer,
  }));

  event.response.answerCorrect = false;

  try {
    const answer = event.request.challengeAnswer;

    if (answer === ADMIN_VERIFIED_SENTINEL) {
      // Server-side flow: trust it, Apple JWT was already verified in auth.ts
      event.response.answerCorrect = true;
      return event;
    }

    // Client-side fallback: verify a raw Apple identity token
    // (kept for completeness, not used in the current flow)
    let payload: Record<string, any>;
    try {
      payload = JSON.parse(answer);
    } catch {
      console.log("Challenge answer is not JSON and not the sentinel — rejecting");
      return event;
    }

    const { token, identifier } = payload;

    if (!token || identifier !== event.userName) {
      console.log("Identifier mismatch or missing token", { expected: event.userName, actual: identifier });
      return event;
    }

    const decoded = jwt.decode(token, { complete: true });
    if (!decoded || typeof decoded === "string" || !decoded.header.kid) {
      console.log("Invalid Apple token format");
      return event;
    }

    const signingKey = await client.getSigningKey(decoded.header.kid);
    jwt.verify(token, signingKey.getPublicKey(), {
      algorithms: ["RS256"],
      issuer: "https://appleid.apple.com",
      subject: identifier,
    });

    event.response.answerCorrect = true;
  } catch (error) {
    console.error("Verify challenge error:", error);
  }

  return event;
};
