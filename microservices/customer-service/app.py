import logging
import os
from datetime import datetime

import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
from prometheus_flask_exporter import PrometheusMetrics

metrics = PrometheusMetrics(app)
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
            CREATE TABLE IF NOT EXISTS customers (
                id SERIAL PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                email VARCHAR(255) UNIQUE NOT NULL,
                phone VARCHAR(50),
                address TEXT,
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


@app.route("/customers", methods=["POST"])
def create_customer():
    try:
        data = request.json
        if not data or "name" not in data or "email" not in data:
            return jsonify({"error": "Name and email are required"}), 400

        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            INSERT INTO customers (name, email, phone, address)
            VALUES (%s, %s, %s, %s)
            RETURNING id, name, email, phone, address, created_at
        """,
            (
                data["name"],
                data["email"],
                data.get("phone"),
                data.get("address"),
            ),
        )

        customer = cur.fetchone()
        conn.commit()
        cur.close()
        conn.close()

        return jsonify(dict(customer)), 201
    except psycopg2.IntegrityError:
        return jsonify({"error": "Customer with this email already exists"}), 409
    except Exception as e:
        logger.error(f"Error creating customer: {e}")
        return jsonify({"error": "Failed to create customer"}), 500


@app.route("/customers/<int:customer_id>", methods=["GET"])
def get_customer(customer_id):
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            SELECT id, name, email, phone, address, created_at
            FROM customers WHERE id = %s
        """,
            (customer_id,),
        )

        customer = cur.fetchone()
        cur.close()
        conn.close()

        if customer:
            return jsonify(dict(customer)), 200
        else:
            return jsonify({"error": "Customer not found"}), 404
    except Exception as e:
        logger.error(f"Error fetching customer: {e}")
        return jsonify({"error": "Failed to fetch customer"}), 500


@app.route("/customers", methods=["GET"])
def list_customers():
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        limit = request.args.get("limit", 100, type=int)
        offset = request.args.get("offset", 0, type=int)

        cur.execute(
            """
            SELECT id, name, email, phone, address, created_at
            FROM customers
            ORDER BY created_at DESC
            LIMIT %s OFFSET %s
        """,
            (limit, offset),
        )

        customers = cur.fetchall()
        cur.close()
        conn.close()

        return jsonify([dict(c) for c in customers]), 200
    except Exception as e:
        logger.error(f"Error listing customers: {e}")
        return jsonify({"error": "Failed to list customers"}), 500


if __name__ == "__main__":
    init_db()
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
