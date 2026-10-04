-- UPGRADE v2 (run after 01-05; safe to run again)
-- Adds: password login, payment status, order-status workflow table, reviews, new views,
--       and a deadlock-safe place_order. Existing data is kept.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. AUTHENTICATION (Unit II: constraints + functions). Passwords are stored as bcrypt hashes, never plain text.
ALTER TABLE customers ADD COLUMN IF NOT EXISTS password_hash TEXT;
UPDATE customers SET password_hash = crypt('demo123', gen_salt('bf')) WHERE password_hash IS NULL;  -- demo accounts: demo123
ALTER TABLE customers ALTER COLUMN password_hash SET NOT NULL;

CREATE OR REPLACE FUNCTION fn_register(p_name TEXT, p_email TEXT, p_phone TEXT, p_password TEXT,
                                       p_line1 TEXT, p_city TEXT, p_pincode TEXT) RETURNS INT AS $$
DECLARE v_id INT;
BEGIN
  IF length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'Please enter your name'; END IF;
  IF coalesce(p_email,'') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(p_email) > 120 THEN RAISE EXCEPTION 'Please enter a valid email'; END IF;
  IF nullif(trim(coalesce(p_phone,'')),'') IS NOT NULL AND trim(p_phone) !~ '^[0-9+ -]{7,15}$' THEN RAISE EXCEPTION 'Please enter a valid phone number'; END IF;
  IF length(coalesce(p_password,'')) < 6 THEN RAISE EXCEPTION 'Password must be at least 6 characters'; END IF;
  IF length(trim(coalesce(p_line1,''))) = 0 OR length(trim(coalesce(p_city,''))) = 0 THEN RAISE EXCEPTION 'Delivery address is required'; END IF;
  IF coalesce(p_pincode,'') !~ '^[0-9]{6}$' THEN RAISE EXCEPTION 'Pincode must be 6 digits'; END IF;
  INSERT INTO customers(name, email, phone, password_hash)
    VALUES (trim(p_name), lower(trim(p_email)), nullif(trim(p_phone),''), crypt(p_password, gen_salt('bf')))
    RETURNING customer_id INTO v_id;
  INSERT INTO addresses(customer_id, line1, city, pincode) VALUES (v_id, trim(p_line1), trim(p_city), p_pincode);
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'That email is already registered';
END $$ LANGUAGE plpgsql;

-- 2. PAYMENT STATUS: COD stays PENDING until delivery; cancelling refunds (PAID) or voids (PENDING)
ALTER TABLE payments ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'PAID';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payments_status_chk') THEN
    ALTER TABLE payments ADD CONSTRAINT payments_status_chk CHECK (status IN ('PENDING','PAID','REFUNDED','VOID'));
  END IF;
END $$;
UPDATE payments p SET status = 'PENDING', paid_at = NULL FROM orders o
 WHERE o.order_id = p.order_id AND p.method = 'COD' AND p.status = 'PAID' AND o.status NOT IN ('DELIVERED','CANCELLED');

-- 3. ORDER WORKFLOW AS DATA: the only legal status moves (replaces hard-coded IF rules)
CREATE TABLE IF NOT EXISTS status_flow(from_status order_status, to_status order_status, PRIMARY KEY (from_status, to_status));
INSERT INTO status_flow VALUES ('PLACED','CONFIRMED'),('PLACED','CANCELLED'),('CONFIRMED','PREPARING'),('CONFIRMED','CANCELLED'),
  ('PREPARING','OUT_FOR_DELIVERY'),('PREPARING','CANCELLED'),('OUT_FOR_DELIVERY','DELIVERED') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION fn_order_status() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM status_flow WHERE from_status = OLD.status AND to_status = NEW.status) THEN
    RAISE EXCEPTION 'Order % cannot move from % to %', OLD.order_id, OLD.status, NEW.status;
  END IF;
  -- a rider is picked when the kitchen confirms; dispatch is refused if nobody is free
  IF NEW.status IN ('CONFIRMED','OUT_FOR_DELIVERY') AND NEW.agent_id IS NULL THEN
    SELECT agent_id INTO NEW.agent_id FROM delivery_agents WHERE available ORDER BY agent_id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF NEW.agent_id IS NOT NULL THEN UPDATE delivery_agents SET available = false WHERE agent_id = NEW.agent_id;
    ELSIF NEW.status = 'OUT_FOR_DELIVERY' THEN RAISE EXCEPTION 'No delivery agent is free right now'; END IF;
  END IF;
  IF NEW.status IN ('DELIVERED','CANCELLED') THEN
    IF NEW.agent_id IS NOT NULL THEN UPDATE delivery_agents SET available = true WHERE agent_id = NEW.agent_id; END IF;
    UPDATE payments SET status = CASE WHEN NEW.status = 'DELIVERED' THEN 'PAID' WHEN status = 'PAID' THEN 'REFUNDED' ELSE 'VOID' END,
                        paid_at = CASE WHEN NEW.status = 'DELIVERED' THEN COALESCE(paid_at, now()) ELSE paid_at END
     WHERE order_id = NEW.order_id;
  END IF;
  IF NEW.status = 'CANCELLED' THEN
    UPDATE menu_items m SET stock = m.stock + oi.qty FROM order_items oi
     WHERE oi.order_id = NEW.order_id AND oi.item_id = m.item_id;
  END IF;
  INSERT INTO audit_log(order_id, old_status, new_status) VALUES (OLD.order_id, OLD.status, NEW.status);
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- 4. REVIEWS: one optional review per delivered order. Only (order_id, stars, comment) is stored; customer and
--    restaurant are found through the order, so there is no transitive dependency (stays in 3NF).
CREATE TABLE IF NOT EXISTS reviews(order_id INT PRIMARY KEY REFERENCES orders ON DELETE CASCADE,
  stars INT NOT NULL CHECK (stars BETWEEN 1 AND 5), comment VARCHAR(300), created_at TIMESTAMPTZ NOT NULL DEFAULT now());

CREATE OR REPLACE FUNCTION fn_review_guard() RETURNS trigger AS $$   -- Trigger 3: only delivered orders can be reviewed
BEGIN
  IF (SELECT status FROM orders WHERE order_id = NEW.order_id) IS DISTINCT FROM 'DELIVERED' THEN
    RAISE EXCEPTION 'You can only review delivered orders';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_review_guard ON reviews;
CREATE TRIGGER trg_review_guard BEFORE INSERT ON reviews FOR EACH ROW EXECUTE FUNCTION fn_review_guard();

CREATE OR REPLACE FUNCTION fn_add_review(p_cust INT, p_order INT, p_stars INT, p_comment TEXT) RETURNS VOID AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM orders WHERE order_id = p_order AND customer_id = p_cust) THEN RAISE EXCEPTION 'Order not found'; END IF;
  INSERT INTO reviews(order_id, stars, comment) VALUES (p_order, p_stars, left(nullif(trim(p_comment),''), 300));
EXCEPTION
  WHEN unique_violation THEN RAISE EXCEPTION 'You already reviewed this order';
  WHEN check_violation THEN RAISE EXCEPTION 'Rating must be between 1 and 5';
END $$ LANGUAGE plpgsql;

-- 5. VIEWS (Unit II)
CREATE OR REPLACE VIEW v_restaurant_rating AS     -- average of real reviews; falls back to the seeded rating until the first review
SELECT r.restaurant_id, r.name, COUNT(x.stars)::int AS reviews, COALESCE(ROUND(AVG(x.stars), 1), r.rating) AS rating
FROM restaurants r
LEFT JOIN (SELECT o.restaurant_id, rv.stars FROM reviews rv JOIN orders o USING (order_id)) x ON x.restaurant_id = r.restaurant_id
GROUP BY r.restaurant_id;

CREATE OR REPLACE VIEW v_order_summary AS         -- first 7 columns unchanged; new ones appended
SELECT o.order_id, c.name AS customer, r.name AS restaurant, o.status, o.total, o.ordered_at, a.name AS agent,
       o.customer_id, p.method, p.status AS payment_status, rv.stars
FROM orders o JOIN customers c USING (customer_id) JOIN restaurants r USING (restaurant_id)
LEFT JOIN delivery_agents a USING (agent_id)
LEFT JOIN payments p ON p.order_id = o.order_id
LEFT JOIN reviews rv ON rv.order_id = o.order_id;

CREATE OR REPLACE VIEW v_daily_sales AS
SELECT ordered_at::date AS day, COUNT(*)::int AS orders, SUM(total) AS revenue FROM orders WHERE status <> 'CANCELLED' GROUP BY 1;

CREATE OR REPLACE VIEW v_low_stock AS
SELECT i.item_id, i.name, r.name AS restaurant, i.stock FROM menu_items i JOIN restaurants r USING (restaurant_id)
WHERE i.stock < 30 ORDER BY i.stock;

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id, order_id DESC);

-- 6. PLACE_ORDER v2: validates payment method and address owner, merges duplicate lines, and locks rows in
--    item_id order so two customers ordering the same dishes can never deadlock (Unit IV).
CREATE OR REPLACE FUNCTION place_order(p_cust INT, p_rest INT, p_addr INT, p_items JSONB, p_method TEXT DEFAULT 'UPI')
RETURNS INT AS $$
DECLARE v_oid INT; r RECORD; v_price NUMERIC; v_stock INT;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Cart is empty'; END IF;
  IF p_method NOT IN ('UPI','CARD','COD') THEN RAISE EXCEPTION 'Unsupported payment method'; END IF;
  IF NOT EXISTS (SELECT 1 FROM addresses WHERE address_id = p_addr AND customer_id = p_cust) THEN RAISE EXCEPTION 'Invalid delivery address'; END IF;
  INSERT INTO orders(customer_id, restaurant_id, address_id) VALUES (p_cust, p_rest, p_addr) RETURNING order_id INTO v_oid;
  FOR r IN SELECT (e->>'item_id')::int AS item_id, SUM((e->>'qty')::int)::int AS qty
           FROM jsonb_array_elements(p_items) e GROUP BY 1 ORDER BY 1 LOOP
    SELECT price, stock INTO v_price, v_stock FROM menu_items WHERE item_id = r.item_id AND restaurant_id = p_rest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % is not on this restaurant menu', r.item_id; END IF;
    IF v_stock < r.qty THEN RAISE EXCEPTION 'Insufficient stock for item % (have %, need %)', r.item_id, v_stock, r.qty; END IF;
    INSERT INTO order_items VALUES (v_oid, r.item_id, r.qty, v_price);
    UPDATE menu_items SET stock = stock - r.qty WHERE item_id = r.item_id;
  END LOOP;
  INSERT INTO payments(order_id, amount, method, status, paid_at)
    SELECT v_oid, total, p_method, CASE WHEN p_method = 'COD' THEN 'PENDING' ELSE 'PAID' END,
           CASE WHEN p_method = 'COD' THEN NULL ELSE now() END FROM orders WHERE order_id = v_oid;
  RETURN v_oid;
EXCEPTION
  WHEN check_violation THEN RAISE EXCEPTION 'Invalid quantity or payment method';
END $$ LANGUAGE plpgsql;
