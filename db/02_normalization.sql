-- UNIT III: Normalization walk-through (UNF -> 1NF -> 2NF -> 3NF/BCNF -> 4NF) and de-normalization
-- UNF: ORDER_FLAT(order_id, order_date, cust_name, cust_email, cust_city, restaurant, rest_city,
--                 {item_name, category, price, qty})   -- repeating group on items
-- 1NF : atomic values, one row per (order, item); key = (order_id, item_name)
-- FDs : order_id -> order_date, cust_*, restaurant ; cust_email -> cust_name, cust_city
--       item_name -> category, price ; restaurant -> rest_city
-- 2NF : remove partial deps on (order_id,item_name): split ORDERS and ITEMS from ORDER_LINES
-- 3NF : remove transitive deps (order_id -> cust_email -> cust_name): CUSTOMERS, RESTAURANTS, CATEGORIES
-- BCNF: every determinant is a candidate key; menu_items has (restaurant_id,name) UNIQUE and item_id PK.
-- 4NF : a customer's addresses are an independent multivalued fact -> own table (addresses).
-- 5NF : order_items is the only 3-way relationship (order, item, qty) and is join-dependency free.
-- Final schema = db/01_schema_er.sql

-- Lossless-join check: rebuild the flat table from normalized tables
SELECT o.order_id, o.ordered_at, c.name, c.email, r.name AS restaurant, m.name AS item,
       cat.name AS category, oi.unit_price, oi.qty
FROM orders o JOIN customers c USING (customer_id) JOIN restaurants r USING (restaurant_id)
JOIN order_items oi USING (order_id) JOIN menu_items m USING (item_id) JOIN categories cat USING (category_id);

-- De-normalization for read-heavy reporting (trade redundancy for speed)
DROP MATERIALIZED VIEW IF EXISTS mv_restaurant_sales;
CREATE MATERIALIZED VIEW mv_restaurant_sales AS
SELECT r.restaurant_id, r.name, COUNT(DISTINCT o.order_id) AS orders, COALESCE(SUM(o.total),0) AS revenue
FROM restaurants r LEFT JOIN orders o ON o.restaurant_id = r.restaurant_id AND o.status <> 'CANCELLED'
GROUP BY r.restaurant_id, r.name;
