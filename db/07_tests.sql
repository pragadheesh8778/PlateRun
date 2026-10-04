-- TEST CASES (run after 06). Usage:  SELECT * FROM fn_run_tests();
-- Every change the tests make is rolled back at the end, so your demo data is untouched
-- (sequence numbers still advance, so order ids may skip a few values).
CREATE OR REPLACE FUNCTION fn_test_add(acc JSONB, n TEXT, exp TEXT, act TEXT) RETURNS JSONB AS $$
  SELECT acc || jsonb_build_array(jsonb_build_object('t', n, 'e', exp, 'a', act, 'p', exp IS NOT DISTINCT FROM act))
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_run_tests() RETURNS TABLE(no INT, test TEXT, expected TEXT, actual TEXT, passed BOOLEAN) AS $$
DECLARE
  res JSONB := '[]'; c1 INT; c2 INT; a1 INT; a2 INT; o1 INT; o2 INT; o3 INT;
  s0 INT; s1 INT; n0 BIGINT; n1 BIGINT; msg TEXT; st TEXT; ag INT; v NUMERIC;
BEGIN
  BEGIN  -- all work happens in this block and is undone by the final RAISE
    UPDATE menu_items SET stock = 100 WHERE item_id IN (1,2,3,4);
    UPDATE delivery_agents SET available = true;
    c1 := fn_register('Test One','t1@test.com','9000000091','secret1','1 Test St','Chennai','600001');
    c2 := fn_register('Test Two','t2@test.com','9000000092','secret2','2 Test St','Chennai','600002');
    SELECT address_id INTO a1 FROM addresses WHERE customer_id = c1;
    SELECT address_id INTO a2 FROM addresses WHERE customer_id = c2;

    -- Authentication
    SELECT password_hash INTO msg FROM customers WHERE customer_id = c1;
    res := fn_test_add(res, 'Password is stored as a bcrypt hash, not plain text', 'hash', CASE WHEN msg LIKE '$2%' THEN 'hash' ELSE msg END);
    BEGIN PERFORM fn_register('Dup','T1@TEST.com',NULL,'secret1','x','y','600001'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Duplicate email is rejected (case-insensitive)', 'That email is already registered', msg);
    BEGIN PERFORM fn_register('Short','s@test.com',NULL,'123','x','y','600001'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Short password is rejected', 'Password must be at least 6 characters', msg);
    SELECT count(*) INTO n0 FROM customers WHERE email = 't1@test.com' AND password_hash = crypt('secret1', password_hash);
    SELECT count(*) INTO n1 FROM customers WHERE email = 't1@test.com' AND password_hash = crypt('wrong', password_hash);
    res := fn_test_add(res, 'Login accepts the right password and rejects a wrong one', '1 / 0', n0 || ' / ' || n1);

    -- Ordering, triggers, payments
    v := 2 * (SELECT price FROM menu_items WHERE item_id = 1) + (SELECT price FROM menu_items WHERE item_id = 3);
    SELECT stock INTO s0 FROM menu_items WHERE item_id = 1;
    o1 := place_order(c1, 1, a1, '[{"item_id":1,"qty":2},{"item_id":3,"qty":1}]', 'COD');
    res := fn_test_add(res, 'Order total is computed by trigger (2 x item 1 + item 3)', v::text, (SELECT total::text FROM orders WHERE order_id = o1));
    SELECT stock INTO s1 FROM menu_items WHERE item_id = 1;
    res := fn_test_add(res, 'Stock is reduced by the ordered quantity', '2', (s0 - s1)::text);
    res := fn_test_add(res, 'Cash on delivery payment starts as PENDING', 'PENDING', (SELECT status FROM payments WHERE order_id = o1));
    o2 := place_order(c2, 2, a2, '[{"item_id":4,"qty":1}]', 'UPI');
    res := fn_test_add(res, 'UPI payment is PAID immediately', 'PAID', (SELECT status FROM payments WHERE order_id = o2));
    o3 := place_order(c1, 1, a1, '[{"item_id":2,"qty":1},{"item_id":2,"qty":2}]', 'UPI');
    res := fn_test_add(res, 'Duplicate cart lines are merged into one', '1 line, qty 3',
      (SELECT count(*) FROM order_items WHERE order_id = o3) || ' line, qty ' || (SELECT qty FROM order_items WHERE order_id = o3 AND item_id = 2));

    -- Atomicity and validation
    SELECT stock INTO s0 FROM menu_items WHERE item_id = 1; SELECT count(*) INTO n0 FROM orders;
    BEGIN PERFORM place_order(c1, 1, a1, '[{"item_id":1,"qty":1},{"item_id":2,"qty":100000}]'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    SELECT stock INTO s1 FROM menu_items WHERE item_id = 1; SELECT count(*) INTO n1 FROM orders;
    res := fn_test_add(res, 'Insufficient stock is rejected with a clear message', 'Insufficient stock for item', left(msg, 27));
    res := fn_test_add(res, 'Atomicity: a failed order leaves no partial data', '0 orders, 0 stock change', (n1 - n0) || ' orders, ' || (s0 - s1) || ' stock change');
    BEGIN PERFORM place_order(c1, 1, a1, '[{"item_id":4,"qty":1}]'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Item from another restaurant is rejected', 'Item 4 is not on this restaurant menu', msg);
    BEGIN PERFORM place_order(c1, 1, a2, '[{"item_id":1,"qty":1}]'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Another customer''s address cannot be used', 'Invalid delivery address', msg);

    -- Order workflow
    BEGIN UPDATE orders SET status = 'DELIVERED' WHERE order_id = o1; msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Skipping steps (PLACED to DELIVERED) is blocked', format('Order %s cannot move from PLACED to DELIVERED', o1), msg);
    UPDATE orders SET status = 'CONFIRMED' WHERE order_id = o1;
    SELECT agent_id INTO ag FROM orders WHERE order_id = o1;
    res := fn_test_add(res, 'CONFIRMED assigns a free delivery agent', 'assigned', CASE WHEN ag IS NOT NULL THEN 'assigned' ELSE 'none' END);
    UPDATE orders SET status = 'PREPARING' WHERE order_id = o1;
    UPDATE orders SET status = 'OUT_FOR_DELIVERY' WHERE order_id = o1;
    UPDATE orders SET status = 'DELIVERED' WHERE order_id = o1;
    res := fn_test_add(res, 'Delivered cash order marks payment PAID', 'PAID', (SELECT status FROM payments WHERE order_id = o1));
    res := fn_test_add(res, 'Agent is free again after delivery', 'true', (SELECT available::text FROM delivery_agents WHERE agent_id = ag));
    res := fn_test_add(res, 'Every status change is written to audit_log', '4', (SELECT count(*) FROM audit_log WHERE order_id = o1)::text);
    BEGIN UPDATE orders SET status = 'CANCELLED' WHERE order_id = o1; msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'A delivered order cannot be cancelled', format('Order %s cannot move from DELIVERED to CANCELLED', o1), msg);
    SELECT stock INTO s0 FROM menu_items WHERE item_id = 4;
    UPDATE orders SET status = 'CANCELLED' WHERE order_id = o2;
    SELECT stock INTO s1 FROM menu_items WHERE item_id = 4;
    res := fn_test_add(res, 'Cancelling an order puts stock back', '1', (s1 - s0)::text);
    res := fn_test_add(res, 'Cancelling a paid order marks payment REFUNDED', 'REFUNDED', (SELECT status FROM payments WHERE order_id = o2));

    -- Reviews
    BEGIN PERFORM fn_add_review(c1, o3, 5, 'too early'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Only delivered orders can be reviewed', 'You can only review delivered orders', msg);
    BEGIN PERFORM fn_add_review(c2, o1, 5, 'not mine'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'A customer cannot review someone else''s order', 'Order not found', msg);
    BEGIN PERFORM fn_add_review(c1, o1, 9, NULL); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'Rating outside 1 to 5 is rejected', 'Rating must be between 1 and 5', msg);
    PERFORM fn_add_review(c1, o1, 4, 'Great food');
    res := fn_test_add(res, 'Review is stored and shows on the order summary', '4', (SELECT stars::text FROM v_order_summary WHERE order_id = o1));
    res := fn_test_add(res, 'Restaurant rating view counts the review', 'true', (SELECT (reviews >= 1)::text FROM v_restaurant_rating WHERE restaurant_id = 1));
    BEGIN PERFORM fn_add_review(c1, o1, 5, 'again'); msg := 'accepted';
    EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
    res := fn_test_add(res, 'An order can be reviewed only once', 'You already reviewed this order', msg);

    RAISE EXCEPTION 'tests finished' USING ERRCODE = 'TS000';   -- undo everything above
  EXCEPTION
    WHEN SQLSTATE 'TS000' THEN NULL;
    WHEN OTHERS THEN res := fn_test_add(res, 'Unexpected error while running tests', 'no error', SQLERRM);
  END;
  RETURN QUERY SELECT x.ord::int, x.e->>'t', x.e->>'e', x.e->>'a', (x.e->>'p')::boolean
               FROM jsonb_array_elements(res) WITH ORDINALITY AS x(e, ord);
END $$ LANGUAGE plpgsql;
