import csv
import json
import os
import urllib.parse
from io import StringIO

import boto3

s3_client = boto3.client("s3")
product_api_url = os.getenv("PRODUCT_API_URL", "http://api-gateway/products")


def handler(event, context):
    print(f"Event: {json.dumps(event)}")

    try:
        bucket = event["Records"][0]["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(event["Records"][0]["s3"]["object"]["key"])

        print(f"Processing file: s3://{bucket}/{key}")

        response = s3_client.get_object(Bucket=bucket, Key=key)
        csv_content = response["Body"].read().decode("utf-8")

        csv_file = StringIO(csv_content)
        csv_reader = csv.DictReader(csv_file)

        products_imported = 0
        errors = []

        for row in csv_reader:
            try:
                product = {
                    "name": row.get("name", ""),
                    "description": row.get("description", ""),
                    "price": float(row.get("price", 0)),
                    "category": row.get("category", ""),
                    "stock_quantity": int(row.get("stock_quantity", 0)),
                }

                import requests

                response = requests.post(product_api_url, json=product, timeout=5)

                if response.status_code in [200, 201]:
                    products_imported += 1
                    print(f"Imported product: {product['name']}")
                else:
                    errors.append(
                        f"Failed to import {product['name']}: {response.text}"
                    )

            except Exception as e:
                errors.append(f"Error processing row: {str(e)}")
                print(f"Error: {e}")

        result = {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "message": f"Processed {products_imported} products",
                    "errors": errors,
                    "file": key,
                }
            ),
        }

        print(f"Import complete: {products_imported} products, {len(errors)} errors")
        return result

    except Exception as e:
        print(f"Error processing file: {str(e)}")
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}
