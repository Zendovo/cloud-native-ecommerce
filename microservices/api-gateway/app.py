import logging
import os

import requests
from flask import Flask, jsonify, request

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

CUSTOMER_SERVICE_URL = os.getenv("CUSTOMER_SERVICE_URL", "http://customer-service:8080")
PRODUCT_SERVICE_URL = os.getenv("PRODUCT_SERVICE_URL", "http://product-catalog:8080")
ORDER_SERVICE_URL = os.getenv("ORDER_SERVICE_URL", "http://order-service:8080")
ACTIVITY_SERVICE_URL = os.getenv("ACTIVITY_SERVICE_URL", "http://activity-service:8080")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/ready", methods=["GET"])
def ready():
    return jsonify({"status": "ready"}), 200


@app.route("/products", methods=["GET"])
def get_products():
    try:
        response = requests.get(f"{PRODUCT_SERVICE_URL}/products", timeout=5)
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error fetching products: {e}")
        return jsonify({"error": "Failed to fetch products"}), 500


@app.route("/products/<product_id>", methods=["GET"])
def get_product(product_id):
    try:
        response = requests.get(
            f"{PRODUCT_SERVICE_URL}/products/{product_id}", timeout=5
        )
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error fetching product {product_id}: {e}")
        return jsonify({"error": "Failed to fetch product"}), 500


@app.route("/products", methods=["POST"])
def create_product():
    try:
        response = requests.post(
            f"{PRODUCT_SERVICE_URL}/products", json=request.json, timeout=5
        )
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error creating product: {e}")
        return jsonify({"error": "Failed to create product"}), 500


@app.route("/customers", methods=["POST"])
def create_customer():
    try:
        response = requests.post(
            f"{CUSTOMER_SERVICE_URL}/customers", json=request.json, timeout=5
        )
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error creating customer: {e}")
        return jsonify({"error": "Failed to create customer"}), 500


@app.route("/customers/<customer_id>", methods=["GET"])
def get_customer(customer_id):
    try:
        response = requests.get(
            f"{CUSTOMER_SERVICE_URL}/customers/{customer_id}", timeout=5
        )
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error fetching customer {customer_id}: {e}")
        return jsonify({"error": "Failed to fetch customer"}), 500


@app.route("/orders", methods=["POST"])
def create_order():
    try:
        response = requests.post(
            f"{ORDER_SERVICE_URL}/orders", json=request.json, timeout=5
        )
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error creating order: {e}")
        return jsonify({"error": "Failed to create order"}), 500


@app.route("/orders/<order_id>", methods=["GET"])
def get_order(order_id):
    try:
        response = requests.get(f"{ORDER_SERVICE_URL}/orders/{order_id}", timeout=5)
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error fetching order {order_id}: {e}")
        return jsonify({"error": "Failed to fetch order"}), 500


@app.route("/activity/event", methods=["POST"])
def log_activity():
    try:
        response = requests.post(
            f"{ACTIVITY_SERVICE_URL}/event", json=request.json, timeout=5
        )
        return jsonify(response.json()), response.status_code
    except Exception as e:
        logger.error(f"Error logging activity: {e}")
        return jsonify({"error": "Failed to log activity"}), 500


@app.route("/analytics/product/<product_id>", methods=["GET"])
def get_analytics(product_id):
    try:
        from datetime import datetime, timedelta

        import boto3

        dynamodb = boto3.resource(
            "dynamodb", region_name=os.getenv("AWS_REGION", "us-east-1")
        )
        table = dynamodb.Table(os.getenv("DYNAMODB_TABLE", "ecommerce-analytics"))

        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=5)

        response = table.query(
            KeyConditionExpression="product_id = :pid AND window_start >= :start",
            ExpressionAttributeValues={
                ":pid": product_id,
                ":start": start_time.isoformat(),
            },
            ScanIndexForward=False,
            Limit=10,
        )

        return jsonify(
            {"product_id": product_id, "analytics": response.get("Items", [])}
        ), 200
    except Exception as e:
        logger.error(f"Error fetching analytics for product {product_id}: {e}")
        return jsonify({"error": "Failed to fetch analytics"}), 500


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
