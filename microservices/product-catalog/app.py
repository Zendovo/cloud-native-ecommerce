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
            CREATE TABLE IF NOT EXISTS products (
                id SERIAL PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                description TEXT,
                price DECIMAL(10, 2) NOT NULL,
                category VARCHAR(100),
                stock_quantity INTEGER DEFAULT 0,
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


@app.route("/products", methods=["POST"])
def create_product():
    try:
        data = request.json
        if not data or "name" not in data or "price" not in data:
            return jsonify({"error": "Name and price are required"}), 400

        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            INSERT INTO products (name, description, price, category, stock_quantity)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id, name, description, price, category, stock_quantity, created_at
        """,
            (
                data["name"],
                data.get("description"),
                data["price"],
                data.get("category"),
                data.get("stock_quantity", 0),
            ),
        )

        product = cur.fetchone()
        conn.commit()
        cur.close()
        conn.close()

        return jsonify(dict(product)), 201
    except Exception as e:
        logger.error(f"Error creating product: {e}")
        return jsonify({"error": f"Failed to create product. {e}"}), 500


@app.route("/products/<int:product_id>", methods=["GET"])
def get_product(product_id):
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            """
            SELECT id, name, description, price, category, stock_quantity, created_at
            FROM products WHERE id = %s
        """,
            (product_id,),
        )

        product = cur.fetchone()
        cur.close()
        conn.close()

        if product:
            return jsonify(dict(product)), 200
        else:
            return jsonify({"error": "Product not found"}), 404
    except Exception as e:
        logger.error(f"Error fetching product: {e}")
        return jsonify({"error": "Failed to fetch product"}), 500


@app.route("/products", methods=["GET"])
def list_products():
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        limit = request.args.get("limit", 100, type=int)
        offset = request.args.get("offset", 0, type=int)
        category = request.args.get("category")

        if category:
            cur.execute(
                """
                SELECT id, name, description, price, category, stock_quantity, created_at
                FROM products
                WHERE category = %s
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s
            """,
                (category, limit, offset),
            )
        else:
            cur.execute(
                """
                SELECT id, name, description, price, category, stock_quantity, created_at
                FROM products
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s
            """,
                (limit, offset),
            )

        products = cur.fetchall()
        cur.close()
        conn.close()

        return jsonify([dict(p) for p in products]), 200
    except Exception as e:
        logger.error(f"Error listing products: {e}")
        return jsonify({"error": "Failed to list products"}), 500


@app.route("/products/<int:product_id>", methods=["PUT"])
def update_product(product_id):
    try:
        data = request.json
        if not data:
            return jsonify({"error": "No data provided"}), 400

        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        update_fields = []
        values = []

        if "name" in data:
            update_fields.append("name = %s")
            values.append(data["name"])
        if "description" in data:
            update_fields.append("description = %s")
            values.append(data["description"])
        if "price" in data:
            update_fields.append("price = %s")
            values.append(data["price"])
        if "category" in data:
            update_fields.append("category = %s")
            values.append(data["category"])
        if "stock_quantity" in data:
            update_fields.append("stock_quantity = %s")
            values.append(data["stock_quantity"])

        if not update_fields:
            return jsonify({"error": "No valid fields to update"}), 400

        values.append(product_id)
        query = f"""
            UPDATE products
            SET {", ".join(update_fields)}
            WHERE id = %s
            RETURNING id, name, description, price, category, stock_quantity, created_at
        """

        cur.execute(query, values)
        product = cur.fetchone()

        if not product:
            conn.rollback()
            cur.close()
            conn.close()
            return jsonify({"error": "Product not found"}), 404

        conn.commit()
        cur.close()
        conn.close()

        return jsonify(dict(product)), 200
    except Exception as e:
        logger.error(f"Error updating product: {e}")
        return jsonify({"error": "Failed to update product"}), 500


if __name__ == "__main__":
    init_db()
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
