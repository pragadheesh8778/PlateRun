// Unit V NoSQL: document model (MongoDB). Orders embed items to avoid joins.
db.orders.insertOne({ _id: 1001, customer: { id: 1, name: "Asha" }, restaurant: "Spice Route", status: "PLACED",
  items: [{ name: "Chicken Biryani", qty: 2, price: 220 }], total: 440, ordered_at: new Date() });
db.orders.createIndex({ "customer.id": 1, ordered_at: -1 });
db.orders.aggregate([{ $unwind: "$items" },
  { $group: { _id: "$items.name", sold: { $sum: "$items.qty" } } }, { $sort: { sold: -1 } }, { $limit: 5 }]);
db.orders.find({ "customer.id": 1 }).sort({ ordered_at: -1 }).explain("executionStats");
