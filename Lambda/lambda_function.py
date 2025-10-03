import boto3
import json
import os
from datetime import datetime

# Initialize DynamoDB
dynamodb = boto3.resource("dynamodb")
# Get table name from environment variable (set in Terraform)
table_name = os.environ["DDB_TABLE"]
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    timestamp = datetime.utcnow().isoformat()

    # Extract SNS message if present, else fallback
    message = event.get("Records", [{}])[0].get("Sns", {}).get("Message", "Test alert")

    # Put log entry into DynamoDB
    table.put_item(Item={
        "id": timestamp,   # matches DynamoDB "id" key from Terraform
        "message": message
    })

    return {"statusCode": 200, "body": "Log stored"}
