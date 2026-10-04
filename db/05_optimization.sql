-- UNIT V: Query optimization + EOD batch (run 01-03 first)
INSERT INTO orders(customer_id,restaurant_id,address_id,status,total,ordered_at)
SELECT c, 1+(random()*2)::int, c, 'DELIVERED', (random()*900+100)::numeric(10,2), now()-(random()*365||' days')::interval
FROM (SELECT 1+(random()*4)::int AS c FROM generate_series(1,50000)) s;
ANALYZE orders;
-- BEFORE index: expect Seq Scan + Sort
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 1 AND status = 'DELIVERED' ORDER BY ordered_at DESC LIMIT 10;
CREATE INDEX IF NOT EXISTS idx_orders_cust_status_time ON orders(customer_id, status, ordered_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_open ON orders(restaurant_id) WHERE status NOT IN ('DELIVERED','CANCELLED');
CREATE INDEX IF NOT EXISTS idx_items_item ON order_items(item_id);
-- AFTER index: expect Index Scan, no Sort
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 1 AND status = 'DELIVERED' ORDER BY ordered_at DESC LIMIT 10;
-- Heuristics: select early, project needed columns only, avoid SELECT *
EXPLAIN ANALYZE SELECT r.name, SUM(o.total) FROM orders o JOIN restaurants r USING (restaurant_id)
WHERE o.ordered_at >= now() - interval '30 days' GROUP BY r.name;
-- Join methods: SET enable_hashjoin = off; re-run to compare nested loop / merge join; then RESET ALL;

-- EOD batch: settlement with 10% commission per restaurant (explicit cursor)
CREATE OR REPLACE PROCEDURE sp_eod_settlement(p_date DATE DEFAULT CURRENT_DATE) AS $$
DECLARE cur CURSOR FOR SELECT restaurant_id FROM restaurants; rid INT; g NUMERIC;
BEGIN
  OPEN cur;
  LOOP FETCH cur INTO rid; EXIT WHEN NOT FOUND;
    SELECT COALESCE(SUM(total),0) INTO g FROM orders
    WHERE restaurant_id = rid AND status = 'DELIVERED' AND ordered_at::date = p_date;
    INSERT INTO daily_settlement VALUES (p_date, rid, g, ROUND(g*0.10,2), ROUND(g*0.90,2))
    ON CONFLICT (settle_date, restaurant_id) DO UPDATE
      SET gross = EXCLUDED.gross, commission = EXCLUDED.commission, payout = EXCLUDED.payout;
  END LOOP;
  CLOSE cur; REFRESH MATERIALIZED VIEW mv_restaurant_sales;
END $$ LANGUAGE plpgsql;
-- CALL sp_eod_settlement(CURRENT_DATE);
