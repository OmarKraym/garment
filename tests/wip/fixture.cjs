const { createHash } = require("node:crypto");
const uuid = (n) => "00000000-0000-4000-8000-" + String(n).padStart(12, "0");
const ts = "2026-01-01T10:00:00Z";
const moves = [];
let prev = "";
for (const [i, base] of [
  {
    type: "cut_adjust",
    qty: 100,
    fromStation: "cutter",
    toStation: "cutter",
    fromHolder: null,
    toHolder: null,
    reason: "تعديل كمية القص",
    actualQty: 100,
  },
  {
    type: "forward",
    qty: 50,
    fromStation: "cutter",
    toStation: "tailor",
    fromHolder: null,
    toHolder: uuid(2),
    reason: null,
  },
].entries()) {
  const payload = {
    ...base,
    id: uuid(10 + i),
    orderId: uuid(1),
    color: "أبيض",
    size: "M",
    ts,
    prevHash: prev,
  };
  const payloadText = JSON.stringify(payload);
  const hash = createHash("sha256")
    .update(prev + payloadText)
    .digest("hex");
  moves.push({ ...payload, payloadText, hash });
  prev = hash;
}
module.exports = {
  version: 1,
  revision: 1,
  me: {
    roles: ["ADMIN"],
    stages: [],
    employee_id: uuid(9),
    display_name: "مدير تجريبي",
  },
  settings: { allowReturns: true },
  staff: [{ id: uuid(8), name: "حساب تجريبي" }],
  tailors: [{ id: uuid(2), name: "خياط 1", active: true, employeeId: uuid(8) }],
  orders: [
    {
      id: uuid(1),
      orderNo: "TEST-001",
      createdAt: ts,
      colors: ["أبيض", "كحلي"],
      sizes: ["M", "L"],
      plannedQty: 100,
      actualCutQty: 100,
      status: "in_progress",
      note: "طلبية اختبار",
    },
  ],
  lots: [
    {
      id: uuid(3),
      orderId: uuid(1),
      color: "أبيض",
      size: "M",
      qty: 50,
      station: "cutter",
      holderId: null,
      state: "active",
      createdAt: ts,
      updatedAt: ts,
    },
    {
      id: uuid(4),
      orderId: uuid(1),
      color: "أبيض",
      size: "M",
      qty: 50,
      station: "tailor",
      holderId: uuid(2),
      state: "pending",
      createdAt: ts,
      updatedAt: ts,
    },
  ],
  moves,
};
