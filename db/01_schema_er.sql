-- UNIT I: ER -> Relational mapping (PostgreSQL / Supabase)
-- Entities: customers, restaurants, menu_items, delivery_agents, orders, payments
-- 1:N  customers-orders | restaurants-menu_items | restaurants-orders
-- M:N  orders-menu_items  -> resolved by order_items (associative entity)
-- 1:1  orders-payments (UNIQUE FK) | Multivalued attr customers.address -> addresses table
DROP TABLE IF EXISTS daily_settlement, audit_log, payments, order_items, orders, delivery_agents,
  menu_items, categories, restaurants, addresses, customers CASCADE;
DROP TYPE IF EXISTS order_status;
CREATE TYPE order_status AS ENUM ('PLACED','CONFIRMED','PREPARING','OUT_FOR_DELIVERY','DELIVERED','CANCELLED');
CREATE SEQUENCE IF NOT EXISTS order_no_seq START 1000;

CREATE TABLE customers(customer_id SERIAL PRIMARY KEY, name VARCHAR(80) NOT NULL,
  email VARCHAR(120) UNIQUE NOT NULL, phone VARCHAR(15), created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE addresses(address_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers ON DELETE CASCADE,
  line1 TEXT NOT NULL, city VARCHAR(50) NOT NULL, pincode CHAR(6) CHECK (pincode ~ '^[0-9]{6}$'));
CREATE TABLE restaurants(restaurant_id SERIAL PRIMARY KEY, name VARCHAR(80) NOT NULL, city VARCHAR(50),
  rating NUMERIC(2,1) CHECK (rating BETWEEN 0 AND 5));
CREATE TABLE categories(category_id SERIAL PRIMARY KEY, name VARCHAR(40) UNIQUE NOT NULL);
CREATE TABLE menu_items(item_id SERIAL PRIMARY KEY,
  restaurant_id INT NOT NULL REFERENCES restaurants ON DELETE CASCADE,
  category_id INT NOT NULL REFERENCES categories,
  name VARCHAR(80) NOT NULL, price NUMERIC(8,2) NOT NULL CHECK (price > 0),
  stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0), UNIQUE (restaurant_id, name));
CREATE TABLE delivery_agents(agent_id SERIAL PRIMARY KEY, name VARCHAR(80) NOT NULL, phone VARCHAR(15),
  available BOOLEAN NOT NULL DEFAULT true);
CREATE TABLE orders(order_id INT PRIMARY KEY DEFAULT nextval('order_no_seq'),
  customer_id INT NOT NULL REFERENCES customers, restaurant_id INT NOT NULL REFERENCES restaurants,
  address_id INT NOT NULL REFERENCES addresses, agent_id INT REFERENCES delivery_agents,
  status order_status NOT NULL DEFAULT 'PLACED', total NUMERIC(10,2) NOT NULL DEFAULT 0,
  ordered_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE order_items(order_id INT REFERENCES orders ON DELETE CASCADE, item_id INT REFERENCES menu_items,
  qty INT NOT NULL CHECK (qty > 0), unit_price NUMERIC(8,2) NOT NULL, PRIMARY KEY (order_id, item_id));
CREATE TABLE payments(payment_id SERIAL PRIMARY KEY, order_id INT UNIQUE NOT NULL REFERENCES orders ON DELETE CASCADE,
  amount NUMERIC(10,2) NOT NULL CHECK (amount >= 0), method VARCHAR(10) CHECK (method IN ('UPI','CARD','COD')),
  paid_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE audit_log(log_id SERIAL PRIMARY KEY, order_id INT, old_status order_status, new_status order_status,
  changed_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE daily_settlement(settle_date DATE, restaurant_id INT REFERENCES restaurants,
  gross NUMERIC(12,2), commission NUMERIC(12,2), payout NUMERIC(12,2), PRIMARY KEY (settle_date, restaurant_id));

-- Views (Unit II). Postgres has no SYNONYM; a view alias serves the same purpose.
CREATE OR REPLACE VIEW v_order_summary AS
SELECT o.order_id, c.name AS customer, r.name AS restaurant, o.status, o.total, o.ordered_at, a.name AS agent
FROM orders o JOIN customers c USING (customer_id) JOIN restaurants r USING (restaurant_id)
LEFT JOIN delivery_agents a USING (agent_id);
CREATE OR REPLACE VIEW syn_menu AS SELECT * FROM menu_items;

-- Seed data
INSERT INTO customers(name,email,phone) VALUES ('Asha','asha@x.com','9000000001'),('Ravi','ravi@x.com','9000000002'),
 ('Meena','meena@x.com','9000000003'),('Karan','karan@x.com','9000000004'),('Divya','divya@x.com','9000000005');
INSERT INTO addresses(customer_id,line1,city,pincode) SELECT customer_id,'12 Main Road','Chennai','600001' FROM customers;
INSERT INTO restaurants(name,city,rating) VALUES ('Spice Route','Chennai',4.4),('Pasta Pier','Chennai',4.1),('Green Bowl','Chennai',4.6);
INSERT INTO categories(name) VALUES ('Mains'),('Starters'),('Drinks');
INSERT INTO menu_items(restaurant_id,category_id,name,price,stock) VALUES
 (1,1,'Chicken Biryani',220,40),(1,2,'Paneer Tikka',180,25),(1,3,'Mango Lassi',70,50),
 (2,1,'Penne Arrabbiata',240,30),(2,2,'Garlic Bread',110,35),(2,3,'Iced Tea',80,60),
 (3,1,'Quinoa Bowl',260,20),(3,2,'Hummus Plate',150,20),(3,3,'Cold Brew',120,45);
INSERT INTO delivery_agents(name,phone) VALUES ('Sam','9111111111'),('Priya','9222222222'),('Jo','9333333333');
