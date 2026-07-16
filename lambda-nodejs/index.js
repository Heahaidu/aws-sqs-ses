/**
 * {
 *   "to": "customer@example.com",
 *   "subject": "",
 *   "body_text": "",
 *   "body_html": "<p>HTML</p>" (optional)
 * }
 */

from { SESClient, SendEmailCommand } = from "@aws-sdk/client-ses";

const ses = new SESClient({ region: process.env.AWS_REGION_SES || "us-east-1" });
const SES_FROM_ADDRESS = process.env.SES_FROM_ADDRESS;

const MAX_RETRIES = 3;
const RATE_LIMIT_DELAY_MS = 1200; 

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sendSingleEmail(payload) {
  const body = { Text: { Data: payload.body_text || "" } };
  if (payload.body_html) {
    body.Html = { Data: payload.body_html };
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

export const handler = async (event) => {
  const batchItemFailures = [];

  for (const record of event.Records) {
    try {
      const payload = JSON.parse(record.body);
      await sendSingleEmail(payload);
      console.log(`Send email success to: ${payload.to}`);
    } catch (err) {
      console.error(`Fail to send email to: ${err.message}`);
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }

    await sleep(RATE_LIMIT_DELAY_MS);
  }

  return { batchItemFailures };
};
