import logging
import os
from datetime import datetime

import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "ecommerce")
DB_USER = os.getenv("DB_USER", "admin")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
    )


def init_db():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS orders (
                id SERIAL PRIMARY KEY,
                customer_id INTEGER NOT NULL,
                product_id INTEGER NOT NULL,
                quantity INTEGER NOT NULL,
                total_price DECIMAL(10, 2) NOT NULL,
                status VARCHAR(50) DEFAULT 'PENDING',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )
        conn.commit()
        cur.close()
        conn.close()
        logger.info("Database initialized successfully")
    except Exception as e:
        logger.error(f"Error initializing database: {e}")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/ready", methods=["GET"])
def ready():
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify({"status": "ready"}), 200
    except Exception as e:
        logger.error(f"Database not ready: {e}")
        return jsonify({"status": "not ready"}), 503


@app.route("/orders", methods=["POST"])
def create_order():
    try:
        data = request.json
        required_fields = ["customer_id", "product_id", "quantity", "total_price"]

        if not data or not all(field in data for field in required_fields):
            return jsonify({"error": "Missing required fields"}), 400

        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            INSERT INTO orders (customer_id, product_id, quantity, total_price, status)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id, customer_id, product_id, quantity, total_price, status, created_at
        """,
            (
                data["customer_id"],
                data["product_id"],
                data["quantity"],
                data["total_price"],
                data.get("status", "PENDING"),
            ),
        )

        order = cur.fetchone()
        conn.commit()
        cur.close()
        conn.close()

        logger.info(f"Order created: {order['id']}")
        return jsonify(dict(order)), 201
    except Exception as e:
        logger.error(f"Error creating order: {e}")
        return jsonify({"error": "Failed to create order"}), 500


@app.route("/orders/<int:order_id>", methods=["GET"])
def get_order(order_id):
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            SELECT id, customer_id, product_id, quantity, total_price, status, created_at
            FROM orders WHERE id = %s
        """,
            (order_id,),
        )

        order = cur.fetchone()
        cur.close()
        conn.close()

        if order:
            return jsonify(dict(order)), 200
        else:
            return jsonify({"error": "Order not found"}), 404
    except Exception as e:
        logger.error(f"Error fetching order: {e}")
        return jsonify({"error": "Failed to fetch order"}), 500


@app.route("/orders", methods=["GET"])
def list_orders():
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        limit = request.args.get("limit", 100, type=int)
        offset = request.args.get("offset", 0, type=int)
        customer_id = request.args.get("customer_id", type=int)

        if customer_id:
            cur.execute(
                """
                SELECT id, customer_id, product_id, quantity, total_price, status, created_at
                FROM orders
                WHERE customer_id = %s
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s
            """,
                (customer_id, limit, offset),
            )
        else:
            cur.execute(
                """
                SELECT id, customer_id, product_id, quantity, total_price, status, created_at
                FROM orders
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s
            """,
                (limit, offset),
            )

        orders = cur.fetchall()
        cur.close()
        conn.close()

        return jsonify([dict(o) for o in orders]), 200
    except Exception as e:
        logger.error(f"Error listing orders: {e}")
        return jsonify({"error": "Failed to list orders"}), 500


@app.route("/orders/<int:order_id>/status", methods=["PUT"])
def update_order_status(order_id):
    try:
        data = request.json
        if not data or "status" not in data:
            return jsonify({"error": "Status is required"}), 400

        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            UPDATE orders
            SET status = %s
            WHERE id = %s
            RETURNING id, customer_id, product_id, quantity, total_price, status, created_at
        """,
            (data["status"], order_id),
        )

        order = cur.fetchone()

        if not order:
            conn.rollback()
            cur.close()
            conn.close()
            return jsonify({"error": "Order not found"}), 404

        conn.commit()
        cur.close()
        conn.close()

        return jsonify(dict(order)), 200
    except Exception as e:
        logger.error(f"Error updating order status: {e}")
        return jsonify({"error": "Failed to update order status"}), 500


if __name__ == "__main__":
    init_db()
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
