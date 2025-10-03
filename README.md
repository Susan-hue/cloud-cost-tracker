# 🌩️ Cloud Cost Tracker & Alert System (Terraform-Only)

A fully-infrastructure-as-code (IaC) project that deploys a **serverless cloud cost tracker** on AWS.  
It monitors billing, records alerts and periodic cost samples into **DynamoDB**, and exposes them to a **static dashboard** hosted on **S3 + CloudFront**.  
An **API Gateway + Lambda** (optional extension I implemented) returns the latest logs to the frontend.

> **Core goals**
> - Detect cost thresholds and notify via **SNS**  
> - Persist alerts/usage samples in **DynamoDB**  
> - Periodically log using **EventBridge → Lambda**  
> - Serve a simple web dashboard from **S3 + CloudFront**  
> - (Extension) Provide a **/logs** endpoint via **API Gateway** for the UI

---

## 🧩 Architecture & How Components Connect

![Architecture](./Screenshots/Architecture%20diagram.png)

**Flow (top to bottom):**

The diagram is arranged in **three horizontal lanes** that match how the system works in production:

### 1 **Alerting Lane (Top) — Billing → SNS → Lambda → DynamoDB**
- **CloudWatch Billing Alarm** monitors `AWS/Billing :: EstimatedCharges (USD)`.  
  When the configured threshold is crossed, **CloudWatch publishes to SNS**.
- **SNS Topic (`billing-alerts`)** has two subscribers:
  - **Email**: sends the alert to a human.
  - **Lambda (Log-Writer)**: invokes the Lambda with the SNS payload.
- **Log-Writer Lambda** extracts the message, stamps UTC time (`id`), and **stores a row in DynamoDB** (table: `CostUsageLogs`).

### 2 **Sampling Lane (Middle) — EventBridge → Lambda → DynamoDB**
- **EventBridge Rule** runs on a **schedule** (e.g., hourly).
- It invokes a **Scheduled Logger Lambda** that writes a synthetic “usage sample” to **DynamoDB**.  
  This guarantees you have test data even when real spend is too low to trip the Billing Alarm.

### 3 **Frontend/Data Lane (Bottom) — CloudFront → S3 → API Gateway → Lambda → DynamoDB**
- **CloudFront** serves the **static dashboard** from **S3** for global performance.
- The **S3 bucket** stores `index.html` (and any static assets).
- When a user clicks **“Refresh Logs”**, the page calls **API Gateway (GET /logs)**.
- **API Gateway** invokes the **Reader Lambda**, which **scans DynamoDB** (limited N rows) and returns JSON to the UI.

> This bottom lane is exactly what your diagram shows:  
> **CloudFront → S3** (serving frontend), and **API Gateway → Lambda → DynamoDB** for read-path data.

**Security & Permissions (high-level):**
- **IAM Role for Lambdas**:  
  - `AWSLambdaBasicExecutionRole` (logs).  
  - `AmazonDynamoDBFullAccess` (demo-friendly; could be narrowed to GetItem/PutItem/Scan on one table).
- **Lambda permissions**:  
  - `lambda:InvokeFunction` from **events.amazonaws.com** (EventBridge).  
  - `lambda:InvokeFunction` from **sns.amazonaws.com** (SNS).
- **S3 bucket policy + CloudFront OAI/Origin Access Control**:  
  - Bucket is private; CloudFront reads it.  
  - (If you only used public-read for simplicity, note that as a trade-off.)

---

## 🗂️ Repository Structure

cloud-cost-tracker/
├─ Terraform/
│ └─ main.tf # Single-file IaC (providers, IAM, DDB, SNS, CW Alarm, EventBridge, Lambdas, API GW, S3, CloudFront)
├─ Lambda/
│ └─ lambda_function.py # SNS/EventBridge writer Lambda (PutItem into DynamoDB)
├─ API_Integration/
│ └─ api_lambda.py # API Lambda (Scan DynamoDB → JSON)
├─ Frontend/
│ └─ index.html # Static dashboard; fetches API GW /logs
├─ Screenshots/
│ ├─ architecture.png # Architecture diagram exported from draw.io
│ ├─ dashboard.png # CloudFront dashboard screenshot
│ ├─ terraform-apply.png # Terraform plan/apply evidence
│ ├─ sns-email.png # SNS email confirmation / received alert
│ └─ dynamodb-entries.png # DynamoDB table showing stored logs
└─ README.md
> **.gitignore** excludes: `.terraform/`, `*.tfstate*`, `*.zip`, caches, OS/editor files.  
> This keeps the repo clean and avoids pushing 100MB+ provider binaries.

---

## 💡 My Build Journey (Narrative)

> This is **not** a how-to. It’s what I actually did, in my words.

1. **Started with Terraform**  
   I wrote a single `main.tf` to keep it approachable as a beginner. I declared:
   - Provider (AWS, `us-east-1`)
   - DynamoDB table (`CostUsageLogs`)
   - SNS topic with email subscription
   - CloudWatch billing alarm (very low threshold so I could test)
   - EventBridge rule to trigger a writer Lambda on a schedule
   - IAM role/policies for Lambda
   - Lambdas: one to write to DDB (SNS + schedule), later another to read from DDB (API)
   - (Extension) API Gateway HTTP API (`/logs`) that invokes the reader Lambda
   - S3 bucket for the UI + CloudFront distribution for global delivery

2. **Wrote the Lambdas**  
   - **Writer Lambda**: tiny Python function using `boto3`. It extracts the SNS message (or a default “Test alert”), gets `DDB_TABLE` from env, and `put_item`s `{ id: ISO-UTC, message: text }`.
   - **Reader Lambda (API)**: scans DynamoDB (with a `Limit`, sorted client-side) and returns JSON for the UI.

3. **Zipping & Wiring**  
   - I zipped each Python file into a package (Windows: “Send to → Compressed (zipped) folder”).  
   - In Terraform, I pointed `aws_lambda_function.filename` at the `.zip` path and made sure the **handler** matched the Python file (`lambda_function.lambda_handler`, and `api_lambda.lambda_handler` for the API Lambda).  
   - I set `environment { variables = { DDB_TABLE = aws_dynamodb_table.cost_logs.name } }`.

4. **S3 + CloudFront + Frontend**  
   - I wrote a minimal `index.html` with a “Refresh Logs” button.  
   - Initially it was static; later I added `fetch('https://<api-id>.execute-api.us-east-1.amazonaws.com/logs')`.  
   - Pushed the HTML to the S3 bucket and set CloudFront to use that bucket as origin.

5. **API Gateway (Extension)**  
   - After the static version worked, I added API Gateway to enable live data.  
   - I declared: `aws_apigatewayv2_api` → `aws_apigatewayv2_integration` → `aws_apigatewayv2_route` (`GET /logs`) → `aws_apigatewayv2_stage` (`$default`).  
   - I also created an `aws_lambda_permission` to allow API Gateway to invoke the API Lambda.  
   - Updated the frontend to use the real API URL, then invalidated CloudFront so the new HTML was served.

6. **Validation**  
   - I manually published to SNS via CLI to test the end-to-end path:
     ```
     aws sns publish \
       --topic-arn <sns-topic-arn> \
       --message "Test SNS Billing Alert"
     ```
   - Verified the Lambda CloudWatch logs and checked DynamoDB: items were inserted.  
   - Hit the API Gateway `/logs` endpoint in the browser to see JSON.  
   - Opened the CloudFront URL and saw the dashboard render the list.

7. **Version Control & Cleanup**  
   - I added a **.gitignore** up front.  
   - At one point I accidentally tracked `.terraform` (which includes a 700MB provider). GitHub rejected the push.  
   - I learned to reinit the repo cleanly and keep heavy, generated content out of Git forever.

---

## ⚠️ Challenges I Hit (And How I Solved Them)

1. **API returns `{ "message": "Not Found" }`**  
   - Cause: I opened the base URL, but my route was `/logs`.  
   - Fix: Navigated to `/logs` or added the route in Terraform correctly (`GET /logs`).

2. **500 “Internal Server Error” on `/logs`**  
   - Cause: Lambda couldn’t read the table (missing policy) or handler name/package mismatch.  
   - Fix: Attached `AmazonDynamoDBFullAccess` (for demo) to the Lambda role, verified handler names, re-zipped, re-applied.

3. **`Unable to import module 'lambda_function'`**  
   - Cause: The zip contained a folder, not the `.py` at the root, or wrong `handler` string.  
   - Fix: Zip only the `.py` file (so it sits at the root of the archive) and set `handler = "file_name.lambda_handler"`.

4. **CloudFront shows old HTML**  
   - Cause: CDN cache.  
   - Fix:
     ```
     aws cloudfront create-invalidation \
       --distribution-id <DIST_ID> \
       --paths "/*"
     ```

5. **GitHub push rejected (file > 100 MB)**  
   - Cause: `.terraform/providers/.../terraform-provider-aws*.exe` was included.  
   - Fix: Add `.terraform/` to `.gitignore`, reinitialize, and push clean. Never commit state or providers.

6. **Terraform “duplicate resource name” errors**  
   - Cause: I tried to define the same `aws_apigatewayv2_route` names twice while iterating.  
   - Fix: Keep resource names unique; if refactoring, `terraform destroy -target` or rename resources to avoid collisions.

7. **Billing Alarm doesn’t fire (low activity)**  
   - Cause: Test account spend was below threshold.  
   - Fix: Set the threshold to `$0.01` for testing and/or trigger Lambda manually and publish to SNS directly.

---

## 📘 Key Lessons Learned

- **Terraform fundamentals**  
  - Keep state and providers **out of Git**.  
  - Start from smallest deployable, then iterate (one region, one table, one lambda).  
  - Name resources clearly; API GW V2 needs API → Integration → Route → Stage.

- **Serverless patterns**  
  - **SNS → Lambda → DynamoDB** is a reliable eventing pattern.  
  - **EventBridge** is ideal for scheduled writes (keeping your logs non-empty during demos).

- **Observability**  
  - **CloudWatch Logs** are your best friend. The error strings (“module not found”, “AccessDenied”) point directly to handler paths or missing IAM.

- **Frontend & CDN**  
  - CloudFront caches aggressively; always invalidate after UI updates.  
  - Keep the frontend minimal and **fetch** from API GW using HTTPS.

- **Cost monitoring mindset**  
  - Even without real spend, you can simulate the alert flow (lower alarm threshold, publish to SNS manually, or write scheduled logs).

---

## 🔧 How I’d Run/Operate This (High-Level)

- **Apply:** `terraform init && terraform apply`  
- **Upload UI:** Put `Frontend/index.html` into the S3 bucket.  
- **Invalidate cache:** `aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/*"`  
- **Trigger test:**  
  - SNS publish to simulate an alert  
  - or invoke the scheduled writer Lambda manually.  
- **Verify:**  
  - DynamoDB contains recent items  
  - API Gateway `/logs` returns JSON  
  - CloudFront page renders and refreshes logs

---

## 🪜 Future Improvements (If I had more time)

- Least-privilege IAM policies (table-scoped actions instead of full access).  
- Replace `Scan` with `Query` on a **GSI** or sort key to efficiently fetch “latest N logs”.  
- Add **Cost Explorer** API integration to fetch real aggregated costs.  
- CI/CD (GitHub Actions) to build Lambda zips and run `terraform plan` on PRs.  
- Add **WAF** in front of CloudFront for hardening.  
- Store alarms & samples in different tables or with item `type` for clarity.

---

## 🔗 Useful Link:

- **CloudFront Dashboard URL:** `https://d1oflhfo6az01s.cloudfront.net/`  

---