-- UNIT IV: Transactions, ACID, concurrency (run 03 first)
-- Atomicity: place_order is one unit; any RAISE rolls back order, items, stock and payment.
-- Consistency: CHECK/FK/PK + triggers. Isolation: FOR UPDATE row locks. Durability: WAL.
CREATE OR REPLACE FUNCTION place_order(p_cust INT, p_rest INT, p_addr INT, p_items JSONB, p_method TEXT DEFAULT 'UPI')
RETURNS INT AS $$
DECLARE v_oid INT; r RECORD; v_price NUMERIC; v_stock INT;
BEGIN
  IF jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Cart is empty'; END IF;
  INSERT INTO orders(customer_id, restaurant_id, address_id) VALUES (p_cust, p_rest, p_addr) RETURNING order_id INTO v_oid;
  FOR r IN SELECT (e->>'item_id')::int AS item_id, (e->>'qty')::int AS qty FROM jsonb_array_elements(p_items) e LOOP
    SELECT price, stock INTO v_price, v_stock FROM menu_items WHERE item_id = r.item_id AND restaurant_id = p_rest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % is not on this restaurant menu', r.item_id; END IF;
    IF v_stock < r.qty THEN RAISE EXCEPTION 'Insufficient stock for item % (have %, need %)', r.item_id, v_stock, r.qty; END IF;
    INSERT INTO order_items VALUES (v_oid, r.item_id, r.qty, v_price);
    UPDATE menu_items SET stock = stock - r.qty WHERE item_id = r.item_id;
  END LOOP;
  INSERT INTO payments(order_id, amount, method) SELECT v_oid, total, p_method FROM orders WHERE order_id = v_oid;
  RETURN v_oid;
EXCEPTION
  WHEN unique_violation THEN RAISE EXCEPTION 'Duplicate item in cart; merge quantities';
  WHEN check_violation THEN RAISE EXCEPTION 'Invalid quantity or payment method';
END $$ LANGUAGE plpgsql;

-- Atomicity demo (fails, nothing persists):  SELECT place_order(1,1,1,'[{"item_id":1,"qty":999}]');
-- Success demo: SELECT place_order(1,1,1,'[{"item_id":1,"qty":2},{"item_id":3,"qty":1}]','UPI');

-- Savepoints
BEGIN; SELECT place_order(2,2,2,'[{"item_id":4,"qty":1}]'); SAVEPOINT after_first;
SELECT place_order(2,2,2,'[{"item_id":5,"qty":1}]'); ROLLBACK TO after_first; COMMIT;

-- Concurrency (two psql sessions; row locks give Two-Phase Locking):
-- S1: BEGIN; SELECT stock FROM menu_items WHERE item_id=1 FOR UPDATE;  -- S2's UPDATE of item 1 blocks until S1 commits
-- Serializable: BEGIN ISOLATION LEVEL SERIALIZABLE; ... (retry on SQLSTATE 40001)
-- Deadlock: S1 locks item 1 then 2, S2 locks 2 then 1 -> Postgres aborts one (40P01)
-- Recovery: committed history in audit_log; WAL + PITR (Supabase) provides redo/undo
-- Deferred update: ALTER TABLE order_items ALTER CONSTRAINT order_items_item_id_fkey DEFERRABLE INITIALLY DEFERRED;
