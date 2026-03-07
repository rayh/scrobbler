/// <reference path="./.sst/platform/config.d.ts" />

export default $config({
  app(input) {
    return {
      name: "scrobbled-at",
      removal: input?.stage === "production" ? "retain" : "remove",
      home: "aws",
      providers: {
        aws: {
          profile: "scrobbler",
          region: "eu-west-1",
        },
      },
    };
  },
  async run() {
    // Single DynamoDB table for all data
    const table = new sst.aws.Dynamo("ScrobbledTable", {
      fields: {
        pk: "string",
        sk: "string",
        gsi1pk: "string",
        gsi1sk: "string",
      },
      primaryIndex: { hashKey: "pk", rangeKey: "sk" },
      globalIndexes: {
        GSI1: { hashKey: "gsi1pk", rangeKey: "gsi1sk" },
      },
      stream: "new-and-old-images",
      ttl: "ttl",
    });

    // Cognito User Pool.
    // usernameAttributes is intentionally NOT set — Apple Sign In uses an opaque user ID
    // (e.g. 000436.abc...0107) as the Cognito username, not an email address.
    // Identity is keyed on the Cognito sub UUID. Provider mappings live in DynamoDB.
    //
    // Note: post-Nov-2024 all new Cognito pools have SignInPolicy: { AllowedFirstAuthFactors: ["PASSWORD"] }
    // which blocks CUSTOM_AUTH via AdminInitiateAuth. We use ADMIN_USER_PASSWORD_AUTH instead —
    // Apple tokens are verified server-side before calling Cognito, so a server-stored random
    // password is equivalent in security to a custom challenge flow.
    const userPool = new aws.cognito.UserPool("ScrobbledUserPool", {
      userPoolTier: "LITE",
      schemas: [
        {
          name: "email",
          attributeDataType: "String",
          required: false,
          mutable: true,
        },
        {
          name: "handle",
          attributeDataType: "String",
          mutable: true,
          stringAttributeConstraints: { minLength: "1", maxLength: "50" },
        },
      ],
    });

    // User Pool Client — password auth (ADMIN_USER_PASSWORD_AUTH) + refresh tokens
    const userPoolClient = new aws.cognito.UserPoolClient("ScrobbledUserPoolClient", {
      userPoolId: userPool.id,
      explicitAuthFlows: ["ALLOW_ADMIN_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
      generateSecret: false,
    });

    const isProd = $app.stage === "production";

    // ── Domains ───────────────────────────────────────────────────────────────
    // All DNS lives in the slctr.io hosted zone.
    // prod:     slctr.io (apex) + www.slctr.io  |  api.slctr.io  |  cdn.slctr.io
    // non-prod: <stage>.slctr.io                |  api-<stage>.slctr.io  |  cdn-<stage>.slctr.io
    const hostedZoneId = "Z0818360ZWA5GI8CXX9Q";
    const dns = sst.aws.dns({ zone: hostedZoneId });

    const siteDomain = isProd ? "slctr.io"                       : `${$app.stage}.slctr.io`;
    const apiDomain  = isProd ? "api.slctr.io"                   : `api-${$app.stage}.slctr.io`;
    const cdnDomain  = isProd ? "cdn.slctr.io"                   : `cdn-${$app.stage}.slctr.io`;

    // Read APNS credentials from Secrets Manager (set via set-apple-credentials.sh)
    const appleCredentials = await aws.secretsmanager.getSecretVersion({
      secretId: "scrobbled-at/apple-credentials",
    });
    const { teamId, keyId, privateKey } = JSON.parse(appleCredentials.secretString);

    // Production uses APNS (real devices / TestFlight / App Store).
    // All other stages use APNS_SANDBOX (Xcode debug builds).
    const snsPlatformAppIos = new aws.sns.PlatformApplication("ScrobbledPushIos", {
      name: $interpolate`scrobbled-push-ios-${$app.stage}`,
      platform: isProd ? "APNS" : "APNS_SANDBOX",
      platformCredential: privateKey,
      platformPrincipal: keyId,
      applePlatformTeamId: teamId,
      applePlatformBundleId: "net.wirestorm.scrobbler",
    });

    // Uploads bucket — all user-generated content
    // Path structure:
    //   uploads/<userId>/avatars/<timestamp>.webp
    //   uploads/<userId>/posts/<postId>/images/<timestamp>.webp
    //   uploads/<userId>/posts/<postId>/voice/<timestamp>.m4a
    // Versioning enabled so old avatars are retained and can be restored if needed.
    // Lifecycle rule expires non-current versions after 30 days.
    const uploadsBucket = new sst.aws.Bucket("UploadsBucket", {
      access: "cloudfront",
      versioning: true,
    });

    // Expire non-current object versions after 30 days
    new aws.s3.BucketLifecycleConfigurationV2("UploadsBucketLifecycle", {
      bucket: uploadsBucket.name,
      rules: [{
        id: "expire-noncurrent",
        status: "Enabled",
        noncurrentVersionExpiration: { noncurrentDays: 30 },
      }],
    });

    const uploadsCdn = new sst.aws.Router("UploadsCdn", {
      domain: {
        name: cdnDomain,
        dns,
      },
      routes: { "/*": { bucket: uploadsBucket } },
    });

    // Landing site — serves:
    //   /.well-known/apple-app-site-association  (Universal Links)
    //   /u/{handle}                              (invite/profile deep link page)
    //   /                                        (marketing / download page)
    // prod: slctr.io + www.slctr.io
    // non-prod: dev-<stage>.slctr.io
    const landingSite = new sst.aws.StaticSite("LandingSite", {
      path: "packages/landing",
      domain: {
        name: siteDomain,
        aliases: isProd ? ["www.slctr.io"] : [],
        dns,
      },
      environment: {
        SLCTR_API_URL: $interpolate`https://${apiDomain}`,
      },
      // Rewrite /u/* to /user.html so CloudFront serves the invite page shell
      edge: {
        viewerRequest: {
          injection: `
            if (request.uri.startsWith('/u/')) {
              request.uri = '/user.html';
            }
          `,
        },
      },
    });


    table.subscribe(
      {
        handler: "packages/functions/src/messaging.handler",
        environment: {
          TABLE_NAME: table.name,
          IS_PROD: isProd ? "true" : "false",
        },
        permissions: [
          { actions: ["sns:Publish", "sns:PublishBatch"], resources: ["*"] },
          { actions: ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:DeleteItem"], resources: [table.arn, $interpolate`${table.arn}/index/GSI1`] },
        ],
      },
      {
        filters: [
          { dynamodb: { NewImage: { pk: { S: [{ prefix: "user#" }] } } } },
          { dynamodb: { NewImage: { pk: { S: [{ prefix: "like#" }] } } } },
        ],
      },
    );

    // Fan-out: copy new posts to follower timelines
    table.subscribe(
      {
        handler: "packages/functions/src/fanout.handler",
        environment: { TABLE_NAME: table.name },
        permissions: [
          { actions: ["dynamodb:Query", "dynamodb:PutItem"], resources: [table.arn] },
        ],
      },
      {
        filters: [{
          dynamodb: {
            NewImage: { pk: { S: [{ prefix: "user#" }] }, sk: { S: [{ prefix: "post#" }] } },
          },
        }],
      },
    );

    // API Gateway
    const api = new sst.aws.ApiGatewayV2("ScrobbledApi", {
      domain: {
        name: apiDomain,
        dns: sst.aws.dns({ zone: hostedZoneId }),
      },
      cors: {
        allowOrigins: ["*"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
      },
    });

    // JWT authorizer backed by the Cognito User Pool
    const jwtAuthorizer = api.addAuthorizer({
      name: "CognitoJwtAuthorizer",
      jwt: {
        issuer: $interpolate`https://cognito-idp.eu-west-1.amazonaws.com/${userPool.id}`,
        audiences: [userPoolClient.id],
      },
    });
    const auth = { jwt: { authorizer: jwtAuthorizer.id } };

    // ── Unauthenticated routes ────────────────────────────────────────────────

    // Apple Sign In: verify token, resolve/create user via provider mapping, issue Cognito tokens
    api.route("POST /auth/apple", {
      handler: "packages/functions/src/auth.apple",
      environment: {
        TABLE_NAME: table.name,
        USER_POOL_ID: userPool.id,
        USER_POOL_CLIENT_ID: userPoolClient.id,
      },
      permissions: [
        { actions: ["dynamodb:PutItem", "dynamodb:GetItem"], resources: [table.arn] },
        {
          actions: [
            "cognito-idp:AdminCreateUser",
            "cognito-idp:AdminGetUser",
            "cognito-idp:AdminSetUserPassword",
            "cognito-idp:AdminInitiateAuth",
          ],
          resources: [userPool.arn],
        },
      ],
    });

    api.route("GET /location/feed", {
      handler: "packages/functions/src/music.getLocationFeed",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:Query"], resources: [table.arn] },
      ],
    });

    // ── Authenticated routes ──────────────────────────────────────────────────

    // Set handle on first sign-in (sub comes from JWT)
    api.route("POST /me/handle", {
      handler: "packages/functions/src/auth.setHandle",
      environment: {
        TABLE_NAME: table.name,
        USER_POOL_ID: userPool.id,
      },
      permissions: [
        { actions: ["dynamodb:PutItem", "dynamodb:GetItem"], resources: [table.arn] },
        { actions: ["cognito-idp:AdminUpdateUserAttributes"], resources: [userPool.arn] },
      ],
    }, { auth });

    api.route("GET /me", {
      handler: "packages/functions/src/me.get",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:GetItem"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("PUT /me", {
      handler: "packages/functions/src/me.update",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:UpdateItem"], resources: [table.arn] },
      ],
    }, { auth });

    // Unified upload request — returns pre-signed PUT URL + deterministic CDN URL
    api.route("POST /upload/request", {
      handler: "packages/functions/src/upload.request",
      environment: {
        TABLE_NAME: table.name,
        UPLOADS_BUCKET: uploadsBucket.name,
        UPLOADS_CDN_URL: uploadsCdn.url,
      },
      permissions: [
        { actions: ["s3:PutObject"], resources: [$interpolate`${uploadsBucket.arn}/*`] },
        { actions: ["dynamodb:GetItem"], resources: [table.arn] },
      ],
    }, { auth });

    // Keep /me/avatar as an alias for backwards compat — points to same handler
    api.route("POST /me/avatar", {
      handler: "packages/functions/src/upload.request",
      environment: {
        TABLE_NAME: table.name,
        UPLOADS_BUCKET: uploadsBucket.name,
        UPLOADS_CDN_URL: uploadsCdn.url,
      },
      permissions: [
        { actions: ["s3:PutObject"], resources: [$interpolate`${uploadsBucket.arn}/*`] },
        { actions: ["dynamodb:GetItem"], resources: [table.arn] },
      ],
    }, { auth });

    // Public: fetch any user's profile + posts by handle
    api.route("GET /users/{handle}", {
      handler: "packages/functions/src/users.getProfile",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:GetItem", "dynamodb:Query"], resources: [table.arn] },
      ],
    });

    api.route("GET /me/posts", {
      handler: "packages/functions/src/me.getPosts",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:GetItem", "dynamodb:Query"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("GET /feed/following", {
      handler: "packages/functions/src/feed.following",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:Query"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("GET /feed/nearby", {
      handler: "packages/functions/src/feed.nearby",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:Query"], resources: [table.arn, $interpolate`${table.arn}/index/GSI1`] },
      ],
    }, { auth });

    // Share a track — userId comes from JWT sub, handle looked up from profile
    api.route("POST /music/share", {
      handler: "packages/functions/src/music.share",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:PutItem", "dynamodb:GetItem"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("POST /music/like", {
      handler: "packages/functions/src/music.like",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("POST /follow", {
      handler: "packages/functions/src/social.follow",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:GetItem", "dynamodb:Query"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("GET /me/following", {
      handler: "packages/functions/src/social.following",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:Query"], resources: [table.arn] },
      ],
    }, { auth });

    api.route("POST /push/register", {
      handler: "packages/functions/src/push.register",
      environment: {
        TABLE_NAME: table.name,
        SNS_PLATFORM_APP_ARN_IOS: snsPlatformAppIos.arn,
        IS_PROD: isProd ? "true" : "false",
      },
      permissions: [
        { actions: ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:DeleteItem"], resources: [table.arn] },
        { actions: ["sns:CreatePlatformEndpoint", "sns:GetEndpointAttributes", "sns:SetEndpointAttributes", "sns:DeleteEndpoint"], resources: ["*"] },
      ],
    }, { auth });

    api.route("GET /events/{userId}", {
      handler: "packages/functions/src/events.stream",
      environment: { TABLE_NAME: table.name },
      permissions: [
        { actions: ["dynamodb:Query"], resources: [table.arn] },
      ],
    }, { auth });

    // S3 ObjectCreated → validation Lambda
    // Validates content-type and size, updates DynamoDB with CDN URL, cleans up old avatar versions
    uploadsBucket.subscribe({
      handler: "packages/functions/src/upload.validate",
      environment: {
        TABLE_NAME: table.name,
        UPLOADS_BUCKET: uploadsBucket.name,
        UPLOADS_CDN_URL: uploadsCdn.url,
      },
      permissions: [
        { actions: ["s3:HeadObject", "s3:DeleteObject", "s3:ListObjectVersions", "s3:DeleteObjectVersion"], resources: [$interpolate`${uploadsBucket.arn}/*`] },
        { actions: ["dynamodb:UpdateItem", "dynamodb:GetItem"], resources: [table.arn] },
      ],
    }, {
      events: ["s3:ObjectCreated:*"],
    });

    return {
      api: api.url,
      apiDomain,
      siteDomain,
      cdnDomain,
      userPoolId: userPool.id,
      userPoolClientId: userPoolClient.id,
      userPoolRegion: "eu-west-1",
      tableName: table.name,
      uploadsBucketName: uploadsBucket.name,
      uploadsCdnUrl: uploadsCdn.url,
    };
  },
});
