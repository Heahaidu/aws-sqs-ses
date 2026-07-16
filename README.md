# SQS + Lambda + SES — Gửi email bất đồng bộ với rate limit

Kiến trúc: `App → SQS → Lambda (poll + throttle) → SES`

## Cấu trúc project

```
sqs-ses-project/
├── terraform/
│   └── main.tf              # SQS, DLQ, IAM, Lambda, Event Source Mapping
├── lambda-python/
│   └── handler.py            # Lambda code (Python)
├── lambda-nodejs/
│   ├── index.js               # Lambda code (Node.js)
│   └── package.json
├── lambda-python.zip          # Đã đóng gói sẵn
├── lambda-nodejs.zip          # Đã đóng gói sẵn (chưa gồm node_modules)
├── send_test_message.py       # Script gửi message test
└── README.md
```

## 1. Chọn runtime (Python hoặc Node.js)

Trong `terraform/main.tf`, sửa biến `runtime`:

```hcl
variable "runtime" {
  default = "python3.14"   # hoặc "nodejs24.x"
}
```

## 2. Nếu dùng Node.js — cài dependency trước khi deploy

```bash
cd lambda-nodejs
npm install
zip -r ../lambda-nodejs.zip . -x "*.git*"
cd ..
```

> Với Python, `boto3` đã có sẵn trong Lambda runtime — không cần đóng gói thêm gì, file zip hiện tại đã đủ dùng.

## 3. Sửa email người gửi

Trong `terraform/main.tf`:

```hcl
variable "ses_from_address" {
  default = "noreply@yourdomain.com"   # phải là identity đã verify trên SES
}
```

## 4. Deploy

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Sau khi apply xong, lấy `queue_url` từ output:

```bash
terraform output queue_url
```

## 5. Test gửi thử

```bash
python send_test_message.py "<queue_url_vừa_lấy_được>"
```

Sau ~1-2 giây, kiểm tra log Lambda:

```bash
aws logs tail /aws/lambda/ses-email-sender --follow
```

## 6. (Khuyến nghị) Bật Partial Batch Response

Code Lambda ở trên đã return `batchItemFailures` để chỉ retry đúng message bị lỗi, thay vì retry cả batch. Cần bật thêm setting này trong Event Source Mapping — thêm vào `main.tf`:

```hcl
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.email_queue.arn
  function_name    = aws_lambda_function.send_email.arn
  batch_size       = 5

  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 2
  }
}
```

## Cách hoạt động (tóm tắt)

1. App đẩy message (JSON chứa `to`, `subject`, `body_text`, `body_html`) vào **SQS**.
2. AWS tự động **poll** SQS thay bạn (Event Source Mapping) và invoke **Lambda** khi có message.
3. `reserved_concurrent_executions = 1` đảm bảo **chỉ 1 Lambda chạy tại 1 thời điểm** — không có 2 luồng gửi email song song.
4. Trong code, `sleep(1)` giữa mỗi email đảm bảo đúng nhịp **1 email/giây** khớp rate limit SES.
5. Nếu SES trả lỗi `Throttling`, code tự **retry với exponential backoff** (1s → 2s → 4s).
6. Nếu vẫn fail sau 3 lần, message được đưa vào **DLQ** để không bị mất, có thể xử lý lại thủ công sau.

## Khi cần tăng tốc độ gửi (SES quota tăng)

Nếu SES đã được tăng quota (VD: 14 email/s trở lên sau khi ra khỏi Sandbox), chỉ cần:

- Giảm `RATE_LIMIT_DELAY_SECONDS` (Python) / `RATE_LIMIT_DELAY_MS` (Node.js) tương ứng
- Tăng `reserved_concurrent_executions` lên (VD: 5 nếu SES cho phép ~5-10 email/s)
- Kiểm tra quota hiện tại: `aws sesv2 get-account --region us-east-1` → xem `SendQuota.MaxSendRate`

## Dọn dẹp

```bash
cd terraform
terraform destroy
```
