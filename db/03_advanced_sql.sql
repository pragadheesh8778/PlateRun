-- UNIT II: SQL, views, cursors, procedures, functions, triggers, exceptions, dynamic SQL
-- DML + TCL basics
BEGIN; UPDATE menu_items SET price = price * 1.05 WHERE category_id = 3; SAVEPOINT s1;
DELETE FROM menu_items WHERE item_id = 9; ROLLBACK TO s1; COMMIT;

-- Queries: simple, nested, subquery, joins, aggregates, window
SELECT name, price FROM menu_items WHERE price > (SELECT AVG(price) FROM menu_items) ORDER BY price DESC;
SELECT name FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id);
SELECT c.name, COUNT(o.order_id) AS orders, COALESCE(SUM(o.total),0) AS spent
FROM customers c LEFT JOIN orders o USING (customer_id) GROUP BY c.name ORDER BY spent DESC;
SELECT r.name, m.name, m.price, RANK() OVER (PARTITION BY r.restaurant_id ORDER BY m.price DESC) AS price_rank
FROM menu_items m JOIN restaurants r USING (restaurant_id);
SELECT name FROM menu_items WHERE item_id NOT IN (SELECT item_id FROM order_items);

-- Function
CREATE OR REPLACE FUNCTION fn_order_tax(p_amount NUMERIC) RETURNS NUMERIC AS $$
BEGIN RETURN ROUND(p_amount * 0.05, 2); END $$ LANGUAGE plpgsql IMMUTABLE;

-- Dynamic SQL
CREATE OR REPLACE FUNCTION fn_row_count(p_table TEXT) RETURNS BIGINT AS $$
DECLARE n BIGINT; BEGIN EXECUTE format('SELECT COUNT(*) FROM %I', p_table) INTO n; RETURN n; END $$ LANGUAGE plpgsql;

-- Procedure with exception handling
CREATE OR REPLACE PROCEDURE sp_restock(p_item INT, p_qty INT) AS $$
BEGIN
  IF p_qty <= 0 THEN RAISE EXCEPTION 'Restock quantity must be positive'; END IF;
  UPDATE menu_items SET stock = stock + p_qty WHERE item_id = p_item;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item % not found', p_item; END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Restock failed: %', SQLERRM; RAISE;
END $$ LANGUAGE plpgsql;

-- Explicit cursor
DO $$ DECLARE cur CURSOR FOR SELECT name, stock FROM menu_items WHERE stock < 30 ORDER BY stock; rec RECORD;
BEGIN OPEN cur; LOOP FETCH cur INTO rec; EXIT WHEN NOT FOUND;
  RAISE NOTICE 'Low stock: % (%)', rec.name, rec.stock; END LOOP; CLOSE cur; END $$;

-- Trigger 1: keep order total in sync with order_items
CREATE OR REPLACE FUNCTION fn_recalc_total() RETURNS trigger AS $$
DECLARE oid INT := COALESCE(NEW.order_id, OLD.order_id);
BEGIN UPDATE orders SET total = (SELECT COALESCE(SUM(qty*unit_price),0) FROM order_items WHERE order_id = oid)
      WHERE order_id = oid; RETURN NULL; END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_recalc ON order_items;
CREATE TRIGGER trg_recalc AFTER INSERT OR UPDATE OR DELETE ON order_items FOR EACH ROW EXECUTE FUNCTION fn_recalc_total();

-- Trigger 2: status workflow, agent assignment, stock restore on cancel, audit
CREATE OR REPLACE FUNCTION fn_order_status() RETURNS trigger AS $$
BEGIN
  IF OLD.status IN ('DELIVERED','CANCELLED') THEN RAISE EXCEPTION 'Order % is already closed', OLD.order_id; END IF;
  IF NEW.status = 'CONFIRMED' AND NEW.agent_id IS NULL THEN
    SELECT agent_id INTO NEW.agent_id FROM delivery_agents WHERE available ORDER BY agent_id LIMIT 1 FOR UPDATE SKIP LOCKED;
    UPDATE delivery_agents SET available = false WHERE agent_id = NEW.agent_id;
  END IF;
  IF NEW.status IN ('DELIVERED','CANCELLED') AND NEW.agent_id IS NOT NULL THEN
    UPDATE delivery_agents SET available = true WHERE agent_id = NEW.agent_id; END IF;
  IF NEW.status = 'CANCELLED' THEN
    UPDATE menu_items m SET stock = m.stock + oi.qty FROM order_items oi
    WHERE oi.order_id = NEW.order_id AND oi.item_id = m.item_id; END IF;
  INSERT INTO audit_log(order_id, old_status, new_status) VALUES (OLD.order_id, OLD.status, NEW.status);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_status ON orders;
CREATE TRIGGER trg_status BEFORE UPDATE OF status ON orders FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION fn_order_status();
