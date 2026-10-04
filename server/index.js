require('dotenv').config();
const express = require('express'), { Pool } = require('pg'), path = require('path'), crypto = require('crypto');
// If DATABASE_URL is empty, pg reads PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE instead
const pool = new Pool({ connectionString: process.env.DATABASE_URL || undefined, ssl: process.env.PGSSL === 'off' ? false : { rejectUnauthorized: false } });
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '20kb' }));

// ---------- config & helpers ----------
const ADMIN_KEY = process.env.ADMIN_KEY || '';   // no default: admin sign-in stays off until you set one
const SECRET = process.env.TOKEN_SECRET || crypto.randomBytes(32).toString('hex'); // random per start unless TOKEN_SECRET is set
if (!ADMIN_KEY) console.warn('ADMIN_KEY is not set in .env, so admin sign-in is disabled.');
const q = (sql, p) => pool.query(sql, p).then(r => r.rows);
const s = v => String(v ?? '');
const fail = (status, message) => Object.assign(new Error(message), { status });
const int = (v, min = 1, max = 1e9, msg = 'Invalid request') => { const n = Number(v); if (!Number.isInteger(n) || n < min || n > max) throw fail(400, msg); return n; };
// P0001 = RAISE EXCEPTION from our SQL (a business rule such as low stock) -> 400 with its message. Anything else is a fault: log it, hide details.
const h = fn => (req, res) => fn(req, res).catch(e => {
  const code = e.status || (e.code === 'P0001' ? 400 : 0);
  if (!code) console.error(req.method, req.originalUrl, e.code, e.message);
  res.status(code || 500).json({ error: code ? e.message : 'Something went wrong on the server' });
});

// Signed session tokens (HMAC-SHA256, 8h). Built-in crypto only, no extra packages.
const mac = t => crypto.createHmac('sha256', SECRET).update(t).digest('base64url');
const sha = v => crypto.createHash('sha256').update(s(v)).digest();
const same = (a, b) => crypto.timingSafeEqual(sha(a), sha(b));
const sign = (claims, hours = 8) => { const body = Buffer.from(JSON.stringify({ ...claims, exp: Date.now() + hours * 3600e3 })).toString('base64url'); return body + '.' + mac(body); };
const verify = tok => { const [body, sig] = s(tok).split('.'); if (!body || !sig || !same(sig, mac(body))) return null;
  try { const c = JSON.parse(Buffer.from(body, 'base64url').toString()); return c.exp > Date.now() ? c : null; } catch { return null; } };
const auth = role => (req, res, next) => {
  const c = verify(s(req.get('authorization')).replace(/^Bearer /, ''));
  if (!c) return res.status(401).json({ error: 'Please sign in' });
  if (role && c.role !== role) return res.status(403).json({ error: 'Not allowed' });
  req.user = c; next();
};

// Brute-force guard: 8 failed sign-ins per 15 minutes per IP+email (failures only)
const strikes = new Map(), WINDOW = 15 * 60e3;
const recent = k => (strikes.get(k) || []).filter(t => Date.now() - t < WINDOW);
const guard = k => { if (recent(k).length >= 8) throw fail(429, 'Too many failed attempts. Try again in a few minutes.'); };
const strike = k => strikes.set(k, [...recent(k), Date.now()]);

app.use('/api', (req, res, next) => {
  res.set({ 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  if (process.env.CORS_ORIGIN) {   // only needed if the frontend runs on a different origin during development
    res.set({ 'Access-Control-Allow-Origin': process.env.CORS_ORIGIN, 'Access-Control-Allow-Methods': 'GET,POST,PATCH,OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type,Authorization' });
    if (req.method === 'OPTIONS') return res.sendStatus(204);
  }
  next();
});

// ---------- public ----------
app.get('/api/health', h(async (req, res) => { await q('SELECT 1'); res.json({ ok: true }); }));

app.post('/api/register', h(async (req, res) => {
  const b = req.body || {};
  const [{ id }] = await q('SELECT fn_register($1,$2,$3,$4,$5,$6,$7) AS id', [s(b.name), s(b.email), s(b.phone), s(b.password), s(b.line1), s(b.city), s(b.pincode)]);
  const [user] = await q('SELECT customer_id, name, email FROM customers WHERE customer_id=$1', [id]);
  res.json({ user, token: sign({ role: 'customer', cid: id }) });
}));

app.post('/api/login', h(async (req, res) => {
  const email = s(req.body?.email).trim().toLowerCase(), key = req.ip + '|' + email;
  guard(key);
  const rows = await q('SELECT customer_id, name, email FROM customers WHERE lower(email)=$1 AND password_hash = crypt($2, password_hash)', [email, s(req.body?.password)]);
  if (!rows.length) { strike(key); throw fail(401, 'Invalid email or password'); }
  strikes.delete(key);
  res.json({ user: rows[0], token: sign({ role: 'customer', cid: rows[0].customer_id }) });
}));

app.post('/api/admin/login', h(async (req, res) => {
  if (!ADMIN_KEY) throw fail(503, 'Admin sign-in is disabled. Set ADMIN_KEY in server/.env and restart.');
  const key = 'admin|' + req.ip;
  guard(key);
  if (!same(req.body?.key, ADMIN_KEY)) { strike(key); throw fail(401, 'Invalid admin key'); }
  strikes.delete(key);
  res.json({ token: sign({ role: 'admin' }, 4) });
}));

app.get('/api/menu', h(async (req, res) => res.json(await q(
  `SELECT i.item_id, i.name, i.price, i.stock, r.restaurant_id, r.name AS restaurant, rr.rating, rr.reviews, c.name AS category
   FROM menu_items i JOIN restaurants r USING (restaurant_id) JOIN v_restaurant_rating rr USING (restaurant_id)
   JOIN categories c USING (category_id) ORDER BY r.name, c.name, i.name`))));

// ---------- customer + admin ----------
const STATUSES = ['PLACED', 'CONFIRMED', 'PREPARING', 'OUT_FOR_DELIVERY', 'DELIVERED', 'CANCELLED'];

app.post('/api/orders', auth('customer'), h(async (req, res) => {
  const items = req.body?.items, method = s(req.body?.method || 'UPI');
  if (!Array.isArray(items) || !items.length) throw fail(400, 'Cart is empty');
  if (items.length > 30) throw fail(400, 'Too many different dishes in one order');
  if (!['UPI', 'CARD', 'COD'].includes(method)) throw fail(400, 'Unsupported payment method');
  const rest = int(req.body?.restaurant_id), clean = items.map(i => ({ item_id: int(i?.item_id), qty: int(i?.qty, 1, 20, 'Quantity must be 1 to 20') }));
  const cid = req.user.cid;   // the customer comes from the signed token, never from the request body
  const [{ id }] = await q(`SELECT place_order($1::int,$2::int,
    (SELECT address_id FROM addresses WHERE customer_id=$1::int ORDER BY address_id LIMIT 1),$3::jsonb,$4) AS id`, [cid, rest, JSON.stringify(clean), method]);
  res.json((await q('SELECT * FROM v_order_summary WHERE order_id=$1', [id]))[0]);
}));

app.get('/api/orders', auth(), h(async (req, res) => res.json(req.user.role === 'admin'
  ? await q('SELECT * FROM v_order_summary ORDER BY order_id DESC LIMIT 50')
  : await q('SELECT * FROM v_order_summary WHERE customer_id=$1 ORDER BY order_id DESC LIMIT 20', [req.user.cid]))));

// Admins may move an order along the workflow; customers may only cancel their own. The DB trigger enforces the legal moves.
app.patch('/api/orders/:id/status', auth(), h(async (req, res) => {
  const id = int(req.params.id), status = s(req.body?.status);
  if (!STATUSES.includes(status)) throw fail(400, 'Unknown status');
  if (req.user.role !== 'admin') {
    if (status !== 'CANCELLED') throw fail(403, 'Customers can only cancel orders');
    if (!(await q('SELECT 1 FROM orders WHERE order_id=$1 AND customer_id=$2', [id, req.user.cid])).length) throw fail(404, 'Order not found');
  }
  const rows = await q('UPDATE orders SET status=$1 WHERE order_id=$2 RETURNING order_id,status,agent_id', [status, id]);
  if (!rows.length) throw fail(404, 'Order not found');
  res.json(rows[0]);
}));

app.post('/api/orders/:id/review', auth('customer'), h(async (req, res) => {
  await q('SELECT fn_add_review($1::int,$2::int,$3::int,$4)', [req.user.cid, int(req.params.id), int(req.body?.stars, 1, 5, 'Rating must be 1 to 5'), s(req.body?.comment)]);
  res.json({ ok: true });
}));

// ---------- admin only ----------
app.get('/api/reports', auth('admin'), h(async (req, res) => {
  const [topItems, sales, daily, lowStock, audit] = await Promise.all([
    q(`SELECT m.name, SUM(oi.qty)::int AS sold FROM order_items oi JOIN menu_items m USING (item_id) JOIN orders o USING (order_id)
       WHERE o.status <> 'CANCELLED' GROUP BY m.name ORDER BY sold DESC LIMIT 5`),
    q('SELECT name, orders, revenue FROM mv_restaurant_sales ORDER BY revenue DESC'),
    q(`SELECT to_char(day,'DD Mon') AS day, orders, revenue FROM v_daily_sales WHERE day >= CURRENT_DATE - 6 ORDER BY v_daily_sales.day`),
    q('SELECT * FROM v_low_stock'),
    q(`SELECT order_id, old_status, new_status, to_char(changed_at,'DD Mon HH24:MI') AS at FROM audit_log ORDER BY log_id DESC LIMIT 10`)]);
  res.json({ topItems, sales, daily, lowStock, audit });
}));

app.post('/api/admin/restock', auth('admin'), h(async (req, res) => {
  await pool.query('CALL sp_restock($1::int,$2::int)', [int(req.body?.item_id), int(req.body?.qty, 1, 10000, 'Quantity must be 1 to 10000')]);
  res.json({ ok: true });
}));

app.post('/api/admin/eod', auth('admin'), h(async (req, res) => {
  await pool.query('CALL sp_eod_settlement(CURRENT_DATE)');
  res.json(await q('SELECT * FROM daily_settlement WHERE settle_date=CURRENT_DATE'));
}));

app.get('/api/explain', auth('admin'), h(async (req, res) => {
  const rows = await q(`EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id=1 AND status='DELIVERED' ORDER BY ordered_at DESC LIMIT 10`);
  res.json(rows.map(r => r['QUERY PLAN']));
}));

// ---------- fallbacks ----------
app.use('/api', (req, res) => res.status(404).json({ error: 'Not found' }));
app.use(express.static(path.join(__dirname, '../public')));
app.use((err, req, res, next) => res.status(err.status === 400 ? 400 : 500).json({ error: err.status === 400 ? 'Bad request' : 'Server error' }));

app.listen(process.env.PORT || 3000, () => console.log('Running on http://localhost:' + (process.env.PORT || 3000)));
