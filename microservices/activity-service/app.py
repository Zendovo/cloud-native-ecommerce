import json
import logging
import os
from datetime import datetime

from flask import Flask, jsonify, request
from kafka import KafkaProducer

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

from prometheus_flask_exporter import PrometheusMetrics

metrics = PrometheusMetrics(app)

KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "ecom-raw-events")

producer = None


def get_kafka_producer():
    global producer
    if producer is None:
        try:
            producer = KafkaProducer(
                bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS.split(","),
                value_serializer=lambda v: json.dumps(v).encode("utf-8"),
                acks="all",
                retries=3,
            )
            logger.info(f"Kafka producer initialized: {KAFKA_BOOTSTRAP_SERVERS}")
        except Exception as e:
            logger.error(f"Failed to initialize Kafka producer: {e}")
            producer = None
    return producer


@app.route("/event", methods=["POST"])
def log_event():
    try:
        data = request.json
        required_fields = ["user_id", "product_id", "event_type"]

        if not data or not all(field in data for field in required_fields):
            return jsonify({"error": "Missing required fields"}), 400

        if "timestamp" not in data:
            data["timestamp"] = datetime.utcnow().isoformat() + "Z"

        kafka_producer = get_kafka_producer()
        if kafka_producer is None:
            return jsonify({"error": "Kafka producer not available"}), 503

        event = {
            "user_id": data["user_id"],
            "product_id": data["product_id"],
            "event_type": data["event_type"],
            "timestamp": data["timestamp"],
            "metadata": data.get("metadata", {}),
        }

        future = kafka_producer.send(KAFKA_TOPIC, value=event)
        future.get(timeout=10)

        logger.info(
            f"Event published: {event['event_type']} for user {event['user_id']} on product {event['product_id']}"
        )

        return jsonify({"status": "success", "event": event}), 201
    except Exception as e:
        logger.error(f"Error publishing event: {e}")
        return jsonify({"error": "Failed to publish event"}), 500


@app.route("/events/batch", methods=["POST"])
def log_events_batch():
    try:
        data = request.json
        if not data or "events" not in data or not isinstance(data["events"], list):
            return jsonify({"error": "Invalid batch format"}), 400

        kafka_producer = get_kafka_producer()
        if kafka_producer is None:
            return jsonify({"error": "Kafka producer not available"}), 503

        published_count = 0
        for event_data in data["events"]:
            required_fields = ["user_id", "product_id", "event_type"]
            if not all(field in event_data for field in required_fields):
                continue

            if "timestamp" not in event_data:
                event_data["timestamp"] = datetime.utcnow().isoformat() + "Z"

            event = {
                "user_id": event_data["user_id"],
                "product_id": event_data["product_id"],
                "event_type": event_data["event_type"],
                "timestamp": event_data["timestamp"],
                "metadata": event_data.get("metadata", {}),
            }

            kafka_producer.send(KAFKA_TOPIC, value=event)
            published_count += 1

        kafka_producer.flush()

        logger.info(f"Batch published: {published_count} events")
        return jsonify({"status": "success", "published": published_count}), 201
    except Exception as e:
        logger.error(f"Error publishing batch events: {e}")
        return jsonify({"error": "Failed to publish batch events"}), 500


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
