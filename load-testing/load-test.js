import http from "k6/http";
import { check, sleep } from "k6";
import { Rate } from "k6/metrics";

const errorRate = new Rate("errors");

export const options = {
  stages: [
    { duration: "2m", target: 50 },
    { duration: "5m", target: 100 },
    { duration: "2m", target: 200 },
    { duration: "5m", target: 200 },
    { duration: "2m", target: 0 },
  ],
  thresholds: {
    http_req_duration: ["p(95)<300"],
    errors: ["rate<0.1"],
    http_req_failed: ["rate<0.05"],
  },
};

const BASE_URL = __ENV.API_GATEWAY_URL || "http://localhost";

const products = [];
const customers = [];
const orders = [];

export function setup() {
  console.log("Starting load test setup...");

  const productData = [
    {
      name: "Laptop",
      description: "High-performance laptop",
      price: 1299.99,
      category: "Electronics",
      stock_quantity: 100,
    },
    {
      name: "Phone",
      description: "Smartphone",
      price: 799.99,
      category: "Electronics",
      stock_quantity: 200,
    },
    {
      name: "Headphones",
      description: "Wireless headphones",
      price: 199.99,
      category: "Audio",
      stock_quantity: 150,
    },
    {
      name: "Tablet",
      description: "Tablet computer",
      price: 499.99,
      category: "Electronics",
      stock_quantity: 80,
    },
    {
      name: "Smartwatch",
      description: "Fitness smartwatch",
      price: 299.99,
      category: "Wearables",
      stock_quantity: 120,
    },
  ];

  const createdProducts = [];
  productData.forEach((product) => {
    const res = http.post(`${BASE_URL}/products`, JSON.stringify(product), {
      headers: { "Content-Type": "application/json" },
    });
    if (res.status === 201) {
      createdProducts.push(res.json());
    }
  });

  console.log(`Setup complete: Created ${createdProducts.length} products`);
  return { products: createdProducts };
}

export default function (data) {
  const userId = `user_${__VU}_${__ITER}`;
  const randomProduct =
    data.products[Math.floor(Math.random() * data.products.length)];

  let res = http.get(`${BASE_URL}/products`);
  check(res, {
    "list products status 200": (r) => r.status === 200,
    "list products response time < 300ms": (r) => r.timings.duration < 300,
  }) || errorRate.add(1);

  sleep(1);

  if (randomProduct && randomProduct.id) {
    res = http.get(`${BASE_URL}/products/${randomProduct.id}`);
    check(res, {
      "get product status 200": (r) => r.status === 200,
      "get product response time < 200ms": (r) => r.timings.duration < 200,
    }) || errorRate.add(1);

    sleep(0.5);

    const activityPayload = JSON.stringify({
      user_id: userId,
      product_id: String(randomProduct.id),
      event_type: "VIEW_PRODUCT",
      timestamp: new Date().toISOString(),
      metadata: {
        session_id: "sess_456",
        duration: Math.floor(Math.random() * 60) + 10,
      },
    });

    res = http.post(`${BASE_URL}/activity/event`, activityPayload, {
      headers: { "Content-Type": "application/json" },
    });
    check(res, {
      "log activity status 201": (r) => r.status === 201,
      "log activity response time < 400ms": (r) => r.timings.duration < 400,
    }) || errorRate.add(1);
  }

  sleep(2);

  if (Math.random() < 0.3) {
    const customerPayload = JSON.stringify({
      name: `Customer ${userId}`,
      email: `${userId}@example.com`,
      phone: "+1234567890",
      address: "123 Test Street",
    });

    res = http.post(`${BASE_URL}/customers`, customerPayload, {
      headers: { "Content-Type": "application/json" },
    });
    check(res, {
      "create customer success": (r) => r.status === 201 || r.status === 409,
    }) || errorRate.add(1);

    sleep(1);
  }

  if (Math.random() < 0.2 && randomProduct && randomProduct.id) {
    const orderPayload = JSON.stringify({
      customer_id: Math.floor(Math.random() * 1000) + 1,
      product_id: randomProduct.id,
      quantity: Math.floor(Math.random() * 3) + 1,
      total_price:
        parseFloat(randomProduct.price) * (Math.floor(Math.random() * 3) + 1),
      status: "PENDING",
    });

    res = http.post(`${BASE_URL}/orders`, orderPayload, {
      headers: { "Content-Type": "application/json" },
    });
    check(res, {
      "create order status 201": (r) => r.status === 201,
      "create order response time < 500ms": (r) => r.timings.duration < 500,
    }) || errorRate.add(1);

    sleep(1);
  }

  if (Math.random() < 0.15 && randomProduct && randomProduct.id) {
    res = http.get(`${BASE_URL}/analytics/product/${randomProduct.id}`);
    check(res, {
      "get analytics success": (r) => r.status === 200,
    }) || errorRate.add(1);
  }

  sleep(Math.random() * 2 + 1);
}

export function teardown(data) {
  console.log("Load test complete!");
  console.log(`Tested with ${data.products.length} products`);
}
