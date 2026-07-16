"""
Script test: gửi 1 message vào SQS để kích hoạt Lambda gửi email.
Chạy: python send_test_message.py <queue_url>
"""

import json
import sys

import boto3

sqs = boto3.client("sqs")

queue_url = sys.argv[1] if len(sys.argv) > 1 else "PASTE_QUEUE_URL_HERE"

message = {
    "to": "test@example.com",
    "subject": "Test email từ SQS + Lambda + SES",
    "body_text": "Đây là email test.",
    "body_html": "<h1>Xin chào</h1><p>Đây là email test.</p>",
}

response = sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message))
print(f"Đã gửi message, MessageId: {response['MessageId']}")
