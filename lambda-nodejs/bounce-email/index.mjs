import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

const client = new DynamoDBClient(
  {
    region: process.env.AWS_REGION,
  });
const ddb = DynamoDBDocumentClient.from(client);

const TABLE_NAME = process.env.TABLE_NAME;

async function handlerBounce(snsMessage, messageId) {
  const bounce = snsMessage.bounce;
  for (const recipient of bounce.bouncedRecipients) {
    await ddb.send(new PutCommand({
      TableName: TABLE_NAME,
      Item: {
        email: recipient.emailAddress,
        event_type: "Bounce",
        bounce_type: bounce.bounceType,
        timestamp: bounce.timestamp
      }
    }));
    console.log(`The bounce ${messageId} has append to dynamodb ${TABLE_NAME}`) 
  }
} 

// async function handlerComplaint(snsMessage, messageId) {
//   const complaint = snsMessage.complaint;
//   const timestamp = complaint.timestamp || "";

//   for (const recipient of complaint.complainedRecipients) {
//     await ddb.send(
//       new PutCommand({
//         TableName: TABLE_NAME,
//         Item: {
//           email: recipient.emailAddress,
//           event_type: "Complaint",
//           complaint_feedback_type: complaint.complaintFeedbackType || "",
//           timestamp,
//         },
//       })
//     );
//     console.log(`The complaint ${messageId} has append to dynamodb ${TABLE_NAME}`)
//   }
// }

export const handler = async (event) => {
  for (const record of event.Records) {
    if (record.EventSource === "aws:sns") {
      const snsMessage = JSON.parse(record.Sns.Message);
      if (snsMessage.eventType === "Bounce") {
        console.log(snsMessage.eventType);
        await handlerBounce(snsMessage, record.Sns.MessageId);
      } else if (snsMessage.eventType === "Complaint") {

      } else {
        console.log("Unknown notification type", snsMessage.notificationType);

      }
    }
  }

};
