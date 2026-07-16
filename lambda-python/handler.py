"""
Lambda function: nhận batch message từ SQS, gửi email qua SES.
Có throttle 1 email/giây (sleep) và retry với exponential backoff khi bị
SES trả lỗi Throttling.

Message body kỳ vọng dạng JSON:
{
    "to": "customer@example.com",
    "subject": "Xin chào",
    "body_text": "Nội dung email dạng text",
    "body_html": "<p>Nội dung email dạng HTML</p>"   (optional)
}
"""

import json
import os
import time

import boto3
from botocore.exceptions import ClientError

ses = boto3.client("ses", region_name=os.environ.get("AWS_REGION_SES", "us-east-1"))
SES_FROM_ADDRESS = os.environ["SES_FROM_ADDRESS"]

MAX_RETRIES = 3
RATE_LIMIT_DELAY_SECONDS = 1  # khớp với SES rate limit 1 email/giây


def send_single_email(payload: dict) -> None:
    """Gửi 1 email, tự retry nếu bị Throttling."""
    message = {
        "Subject": {"Data": payload["subject"]},
        "Body": {"Text": {"Data": payload.get("body_text", "")}},
    }
    if payload.get("body_html"):
        message["Body"]["Html"] = {"Data": payload["body_html"]}

    for attempt in range(MAX_RETRIES):
        try:
            ses.send_email(
                Source=SES_FROM_ADDRESS,
                Destination={"ToAddresses": [payload["to"]]},
                Message=message,
            )
            return
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            if error_code == "Throttling" and attempt < MAX_RETRIES - 1:
                backoff = 2 ** attempt  # 1s, 2s, 4s
                print(f"Bị throttle, chờ {backoff}s rồi thử lại...")
                time.sleep(backoff)
                continue
            # Lỗi khác (MessageRejected, domain chưa verify...) -> raise ngay
            # để SQS đưa message vào retry / DLQ theo redrive_policy
            raise


def handler(event, context):
    failures = []  # dùng cho partial batch failure (khuyến nghị bật trong event source mapping)

    for record in event["Records"]:
        try:
            payload = json.loads(record["body"])
            send_single_email(payload)
            print(f"Đã gửi email tới {payload['to']}")
        except Exception as e:
            print(f"Gửi email thất bại: {e}")
            failures.append({"itemIdentifier": record["messageId"]})

        # Throttle: đảm bảo không vượt quá 1 email/giây dù batch có nhiều message
        time.sleep(RATE_LIMIT_DELAY_SECONDS)

    # Trả về danh sách message fail để SQS chỉ retry đúng những cái đó
    # (yêu cầu bật "Report batch item failures" trong event source mapping)
    return {"batchItemFailures": failures}
