/**
 * {
 *   "to": "customer@example.com",
 *   "subject": "",
 *   "body_text": "",
 *   "body_html": "<p>HTML</p>" (optional)
 * }
 */

import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";

// SES
const ses = new SESClient({ region: process.env.AWS_REGION_SES || "us-east-1" });
const SES_FROM_ADDRESS = process.env.SES_FROM_ADDRESS;

// DynamoDB
const client = new DynamoDBClient(
  {
    region: process.env.AWS_REGION,
  });
const ddb = DynamoDBDocumentClient.from(client);

const TABLE_NAME = process.env.TABLE_NAME;

const MAX_RETRIES = 3;
const RATE_LIMIT_DELAY_MS = 1200; 
const BOUNCE_COOLDOWN_MS = 5 * 60 * 1000;

//
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sendSingleEmail(payload) {
  const body = { Text: { Data: payload.body_text || "" } };
  if (payload.body_html) {
    body.Html = { Data: payload.body_html };
  }

  if (await isBouncedEmail(payload.to)) { 
    console.log(`Bounced email ${payload.to}, skip sending`);
    return;
  }

  const command = new SendEmailCommand({
    Source: SES_FROM_ADDRESS,
    Destination: { ToAddresses: [payload.to] },
    Message: {
      Subject: { Data: payload.subject },
      Body: body,
    },
  });

  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    try {
      await ses.send(command);
      console.log(`Send email success to: ${payload.to}`);
      return;
    } catch (err) {
      const isThrottling = err.name === "Throttling" || err.name === "ThrottlingException";
      if (isThrottling && attempt < MAX_RETRIES - 1) {
        const backoff = 2 ** attempt * 1000; 
        console.log(`Throttle..., wait ${backoff}ms...`);
        await sleep(backoff);
        continue;
      }
      throw err;
    }
  }
}

async function isBouncedEmail(email) {
  const result = await ddb.send(new GetCommand({
    TableName: TABLE_NAME,
    Key: { email }
  }));

  if (!!result.Item) {

    const addedAt = new Date(result.Item.timestamp).getTime();
	const elapsedMs = Date.now() - addedAt;
    if (elapsedMs > BOUNCE_COOLDOWN_MS) {	
		console.log(`BOUNCE FOUND, Allow to resend ${email} | elapsed ${elapsedMs}`);
		return false;
	}
    return true;

  }
  return false;
}

export const handler = async (event) => {
  const batchItemFailures = [];

  for (const record of event.Records) {
    try {
      const payload = JSON.parse(record.body);
      await sendSingleEmail(payload);
    } catch (err) {
      console.error(`Fail to send email: ${err}`);
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }

    await sleep(RATE_LIMIT_DELAY_MS);
  }

  return { batchItemFailures };
};
