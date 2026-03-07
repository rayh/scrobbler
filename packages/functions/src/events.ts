import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);

export const stream = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  const userId = event.pathParameters?.userId;
  
  if (!userId) {
    return {
      statusCode: 400,
      body: JSON.stringify({ error: "Missing userId" })
    };
  }

  // Set up SSE headers
  const headers = {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
  };

  try {
    // Get recent timeline updates for the user
    const result = await ddb.send(new QueryCommand({
      TableName: process.env.TABLE_NAME,
      KeyConditionExpression: "pk = :pk",
      ExpressionAttributeValues: {
        ":pk": `timeline#${userId}`
      },
      ScanIndexForward: false, // Most recent first
      Limit: 10
    }));

    // Format as SSE events
    let sseData = "";
    
    if (result.Items) {
      for (const item of result.Items) {
        const eventData = {
          type: "new_post",
          post: {
            postId: item.postId,
            userId: item.userId,
            userHandle: item.userHandle,
            userName: item.userName,
            track: item.track,
            comment: item.comment,
            tags: item.tags,
            createdAt: item.createdAt
          }
        };
        
        sseData += `data: ${JSON.stringify(eventData)}\n\n`;
      }
    }

    // Send initial data and keep connection alive
    sseData += `data: {"type": "connected", "userId": "${userId}"}\n\n`;

    return {
      statusCode: 200,
      headers,
      body: sseData
    };

  } catch (error) {
    console.error("SSE stream error:", error);
    return {
      statusCode: 500,
      headers,
      body: `data: {"type": "error", "message": "Stream failed"}\n\n`
    };
  }
};
