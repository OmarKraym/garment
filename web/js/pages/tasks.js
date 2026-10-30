// «مهامي» — the one screen a worker needs, in the order the work happens:
//   1. receive what was sent to me   2. (cutter) orders to cut   3. pass my pieces to the next stage
//   4. my extra assignments, if any.
import { operation, rpc } from "../api.js";
import { badge, details, field, fmtDate, h, input, pageHead, routeRail, select } from "../dom.js";
import { actionButton, actionForm, int, optional } from "../forms.js";
import { DEFECT_REASONS, STAGE_LABEL, stageRank } from "../labels.js";
import { partialReceiveForm } from "./transfers.js";
import { progressForm } from "./work.js";

const qtyInput = (name, max, value, label) =>
  input({ name, type: "number", inputmode: "numeric", min: 0, max, step: 1, value, class: "qty-input", "aria-label": label });

// ---------------------------------------------------------------- 2. cutter: orders sent to cutting
function cutOrderCard(o, depts) {
  const ops = new Map(o.lines.map((l) => [l.id, operation()])); // one retry-safe key per line
  const rows = o.lines.map((l) => h("tr", {},
    h("td", { text: `${l.color} / ${l.size}` }),
    h("td", { class: "num" }, qtyInput(`plan_${l.id}`, 1000000, l.planned_qty, `المطلوب ${l.color} / ${l.size}`)),
    h("td", { class: "num", text: l.cut_qty }),
    h("td", { class: "num" }, qtyInput(`cut_${l.id}`, 1000000, Math.max(l.planned_qty - l.cut_qty, 0) || "", `قصّ الآن ${l.color} / ${l.size}`))));
  const form = actionForm({
    submit: "حفظ",
    children: [
      h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, ["اللون / المقاس", "المطلوب", "مقصوص", "قصّ الآن"].map((t, i) => h("th", { class: i ? "num" : "", text: t })))),
        h("tbody", {}, rows))),
      depts.length > 1 ? field("قسم القص", select("dept", depts.map((d) => ({ value: d.id, label: d.name })))) : null,
      h("p", { class: "small muted", text: "عدّل «المطلوب» إن لزم (الألوان والمقاسات ثابتة)، واكتب ما قصصته فعلاً في «قصّ الآن»." }),
    ],
    run: async (d) => {
      const changed = o.lines.filter((l) => int(d[`plan_${l.id}`]) !== l.planned_qty)
        .map((l) => ({ lineId: l.id, plannedQty: int(d[`plan_${l.id}`]) }));
      if (changed.some((c) => !(c.plannedQty > 0))) throw new Error("الكمية المطلوبة يجب أن تكون 1 أو أكثر");
      if (changed.length) await rpc("app_set_line_quantities", { p_order: o.id, p: { lines: changed } });
      const dept = d.dept || depts[0]?.id;
      let pieces = 0;
      for (const l of o.lines) {
        const n = int(d[`cut_${l.id}`]) || 0;
        if (n <= 0) continue;
        await ops.get(l.id).run("app_create_cut_lot", (requestKey) => ({ p: { requestKey, orderLineId: l.id, quantity: n, cuttingDepartmentId: dept } }));
        pieces += n;
      }
      if (!changed.length && !pieces) throw new Error("لا يوجد تغيير للحفظ");
      return [changed.length ? "تم تعديل الكميات" : null, pieces ? `تم تسجيل قص ${pieces} قطعة — وزّعها على الخياطين من «في عهدتك»` : null].filter(Boolean).join(". ");
    },
  });
  return h("article", { class: "card m0 cut-order", dataset: { order: o.order_code } },
    h("div", { class: "ticket-head" },
      h("div", {}, h("div", { class: "ticket-code ltr", text: o.order_code }),
        h("div", { class: "ticket-sub", text: `${o.product_name}${o.model_code ? ` (${o.model_code})` : ""} — ${o.customer_name}` })),
      badge("جديدة للقص", "primary")),
    routeRail("CUTTING"),
    h("div", { class: "small muted" }, "التسليم للزبون ", h("span", { class: "num", text: o.due_date })),
    o.notes ? h("div", { class: "alert warn small", text: `ملاحظة المشرف: ${o.notes}` }) : null,
    h("div", { class: "mt" }, form));
}

function replacementCard(r, depts) {
  return h("div", { class: "card m0" },
    h("div", {}, h("b", { class: "ltr", text: r.order_code }), ` — ${r.color} / ${r.size} — بدل عيب ${r.defect_code}: ${r.reason}`),
    actionForm({
      submit: `تسجيل القص البديل (${r.replacement_qty})`,
      run: async (_d, op) => {
        const res = await op.run("app_create_cut_lot", (requestKey) => ({ p: { requestKey, orderLineId: r.order_line_id, quantity: r.replacement_qty,
          cuttingDepartmentId: depts[0]?.id, replacementDispositionId: r.id } }));
        return `تم تسجيل الدفعة ${res.lotCode}`;
      },
    }));
}

// ---------------------------------------------------------------- 3. my pieces, one card per order
const lineName = (l) => `${l.color} / ${l.size}`;
const lineOptions = (lines) => lines.map((l, i) => ({ value: i, label: `${lineName(l)} — ${l.condition === "GOOD" ? "سليم" : "معيب"} (${l.qty})` }));

/** Cutter → tailors: tick the tailors, then one column per tailor and one row per colour/size. */
function distributeTable(g, lines, nextDepts) {
  const deptSel = select("to", nextDepts.map((t) => ({ value: t.id, label: t.name })));
  const chooser = h("div", { class: "row wrap" });
  const tableBox = h("div", {});
  const values = new Map(); // keep typed numbers when the tailor selection changes
  const selected = () => [...chooser.querySelectorAll("input:checked")].map((x) => ({ id: x.value, name: x.dataset.name }));
  const drawChooser = () => {
    const t = nextDepts.find((x) => x.id === deptSel.value);
    chooser.replaceChildren(...(t.members.length ? t.members.map((m) => h("label", { class: "check chip-check" },
      h("input", { attrs: { type: "checkbox", value: m.id, "data-name": m.name } }), m.name))
      : [h("p", { class: "small muted", text: "لا يوجد عمال في هذا القسم. اطلب من مدير النظام إضافتهم." })]));
    drawTable();
  };
  const drawTable = () => {
    tableBox.querySelectorAll("input").forEach((x) => values.set(x.name, x.value));
    const people = selected();
    if (!people.length) { tableBox.replaceChildren(h("p", { class: "small muted", text: "اختر العمال الذين ستوزع عليهم." })); return; }
    tableBox.replaceChildren(h("div", { class: "table-wrap" }, h("table", { class: "qty-grid" },
      h("thead", {}, h("tr", {}, h("th", { text: "اللون / المقاس" }), h("th", { class: "num", text: "معك" }),
        people.map((p) => h("th", { class: "num", text: p.name })), h("th", { class: "num", text: "يبقى" }))),
      h("tbody", {}, lines.map((l, i) => h("tr", { dataset: { row: i } }, h("th", { text: lineName(l) }), h("td", { class: "num", text: l.qty }),
        people.map((p) => h("td", {}, qtyInput(`d_${i}_${p.id}`, l.qty, values.get(`d_${i}_${p.id}`) ?? "", `${p.name} — ${lineName(l)}`))),
        h("td", { class: "num left" })))))));
    recount();
  };
  const recount = () => lines.forEach((l, i) => {
    const row = tableBox.querySelector(`tr[data-row="${i}"]`);
    if (!row) return;
    const used = [...row.querySelectorAll("input")].reduce((s, x) => s + (int(x.value) || 0), 0);
    const cell = row.querySelector(".left");
    cell.textContent = l.qty - used;
    cell.classList.toggle("danger-text", used > l.qty);
  });
  chooser.addEventListener("change", drawTable);
  tableBox.addEventListener("input", recount);
  deptSel.addEventListener("change", drawChooser);
  const even = h("button", { class: "btn-ghost btn-sm", attrs: { type: "button" }, text: "وزّع بالتساوي", onclick: () => {
    const people = selected();
    if (!people.length) return;
    lines.forEach((l, i) => people.forEach((p, k) => {
      const x = tableBox.querySelector(`input[name="d_${i}_${p.id}"]`);
      if (x) x.value = Math.floor(l.qty / people.length) + (k < l.qty % people.length ? 1 : 0);
    }));
    recount();
  } });
  drawChooser();
  return actionForm({
    submit: "توزيع",
    children: [nextDepts.length > 1 ? field("القسم", deptSel) : null, h("p", { class: "small", text: "على من توزّع؟" }), chooser, tableBox, h("div", { class: "row" }, even)],
    run: async (_d, op) => {
      const items = [];
      lines.forEach((l, i) => {
        let used = 0;
        for (const p of selected()) {
          const n = int(tableBox.querySelector(`input[name="d_${i}_${p.id}"]`)?.value) || 0;
          if (n > 0) { items.push({ lotId: l.lot_id, fromCustodyId: l.custody_id, toDepartmentId: deptSel.value, toEmployeeId: p.id, quantity: n }); used += n; }
        }
        if (used > l.qty) throw new Error(`${lineName(l)}: المجموع أكبر مما معك (${l.qty})`);
      });
      if (!items.length) throw new Error("اكتب كمية لعامل واحد على الأقل");
      const r = await op.run("app_dispatch_batch", (requestKey) => ({ p: { requestKey, items } }));
      return `تم توزيع ${r.quantity} قطعة على ${r.workers} ${r.workers > 1 ? "عمال" : "عامل"}. تصلهم بعد تأكيد الاستلام.`;
    },
  });
}

/** Any other stage → the next one: every row pre-filled with all pieces, one button. */
function passTable(g, lines, nextDepts) {
  const deptSel = select("to", nextDepts.map((t) => ({ value: t.id, label: t.name })));
  return actionForm({
    submit: `تمرير إلى ${nextDepts.length === 1 ? nextDepts[0].name : STAGE_LABEL[nextDepts[0].stage]}`,
    children: [nextDepts.length > 1 ? field("القسم", deptSel) : null,
      h("div", { class: "table-wrap" }, h("table", { class: "qty-grid" },
        h("thead", {}, h("tr", {}, h("th", { text: "اللون / المقاس" }), h("th", { class: "num", text: "معك" }), h("th", { class: "num", text: "تمرير" }))),
        h("tbody", {}, lines.map((l, i) => h("tr", {}, h("th", { text: lineName(l) }), h("td", { class: "num", text: l.qty }),
          h("td", {}, qtyInput(`p_${i}`, l.qty, l.qty, `تمرير ${lineName(l)}`))))))),
      h("p", { class: "small muted", text: "الأرقام معبأة بكل ما معك؛ خفّضها إن كنت ستمرر جزءاً فقط." })],
    run: async (d, op) => {
      const items = lines.map((l, i) => ({ lotId: l.lot_id, fromCustodyId: l.custody_id, toDepartmentId: deptSel.value, quantity: int(d[`p_${i}`]) || 0 }))
        .filter((x) => x.quantity > 0);
      if (!items.length) throw new Error("اكتب الكمية");
      const r = await op.run("app_dispatch_batch", (requestKey) => ({ p: { requestKey, items } }));
      return `تم تمرير ${r.quantity} قطعة. تبقى «قيد النقل» حتى يؤكد المستلم.`;
    },
  });
}

function returnForm(lines, prevDepts) {
  const deptSel = select("to", prevDepts.map((t) => ({ value: t.id, label: t.name })));
  const who = h("div", {});
  const draw = () => {
    const t = prevDepts.find((x) => x.id === deptSel.value);
    who.replaceChildren(t.mode === "INDIVIDUAL"
      ? field("إلى العامل", select("employee", [{ value: "", label: "اختر" }, ...t.members.map((m) => ({ value: m.id, label: m.name }))], "", { required: true }))
      : "");
  };
  deptSel.addEventListener("change", draw);
  draw();
  return actionForm({
    submit: "إرجاع",
    children: [h("div", { class: "inline-fields" },
      lines.length > 1 ? field("القطع", select("line", lineOptions(lines))) : null,
      prevDepts.length > 1 ? field("القسم", deptSel) : null, who,
      field("الكمية", qtyInput("quantity", null, "", "كمية الإرجاع"))),
      field("سبب الإرجاع", input({ name: "reason", required: true, maxlength: 500 }))],
    run: async (d, op) => {
      const l = lines[int(d.line) || 0];
      const n = int(d.quantity);
      if (!(n > 0)) throw new Error("اكتب الكمية");
      if (n > l.qty) throw new Error(`معك ${l.qty} فقط من ${lineName(l)}`);
      await op.run("app_dispatch", (requestKey) => ({ p: { requestKey, lotId: l.lot_id, fromCustodyId: l.custody_id,
        toDepartmentId: deptSel.value, toEmployeeId: optional(d.employee), condition: l.condition, quantity: n, reason: d.reason } }));
      return `تم إرجاع ${n} قطعة إلى ${prevDepts.find((x) => x.id === deptSel.value).name}`;
    },
  });
}

function defectForm(lines, v) {
  return actionForm({
    submit: "تسجيل عيب", danger: true,
    children: [h("div", { class: "inline-fields" },
      lines.length > 1 ? field("القطع", select("line", lineOptions(lines))) : null,
      field("الكمية المعيبة", input({ name: "quantity", type: "number", inputmode: "numeric", min: 1, step: 1, required: true })),
      field("السبب", select("reason", Object.entries(DEFECT_REASONS).map(([value, label]) => ({ value, label })))),
      field("القسم المسؤول (اختياري)", select("responsible", [{ value: "", label: "غير محدد" },
        ...v.targets.filter((t) => stageRank(t.stage) <= stageRank(lines[0].stage)).map((t) => ({ value: t.id, label: t.name }))], ""))),
      field("وصف (اختياري)", input({ name: "description", maxlength: 1000 }))],
    run: async (d, op) => {
      const l = lines[int(d.line) || 0];
      const r = await op.run("app_mark_defect", (requestKey) => ({ p: {
        requestKey, lotId: l.lot_id, custodyId: l.custody_id, quantity: int(d.quantity), reasonCode: d.reason,
        description: optional(d.description), responsibleDepartmentId: optional(d.responsible) } }));
      return `تم تسجيل العيب ${r.defectCode}. القطع بقيت عندك بحالة «معيب».`;
    },
  });
}

function repairForm(lines, v) {
  const defects = v.open_defects.filter((x) => lines.some((l) => l.lot_id === x.lot_id));
  if (!defects.length) return h("p", { class: "small muted", text: "لا يوجد سجل عيب مفتوح لهذه القطع." });
  const label = (x) => `${lineName(lines.find((l) => l.lot_id === x.lot_id))} — ${DEFECT_REASONS[x.reason] ?? x.reason} (مفتوح ${x.open})`;
  return actionForm({
    submit: "تسجيل الإصلاح",
    children: [h("div", { class: "inline-fields" },
      field("سجل العيب", select("defect", defects.map((x) => ({ value: x.id, label: label(x) })))),
      field("الكمية المُصلحة", input({ name: "quantity", type: "number", inputmode: "numeric", min: 1, step: 1, required: true }))),
      field("ملاحظة (اختياري)", input({ name: "note", maxlength: 500 }))],
    run: async (d, op) => {
      await op.run("app_repair_defect", (requestKey) => ({ p_id: d.defect, p: { requestKey, custodyId: lines[0].custody_id, quantity: int(d.quantity), note: optional(d.note) } }));
      return "تم تسجيل الإصلاح وأصبحت القطع سليمة.";
    },
  });
}

/** Lines grouped by (custody, order): one card per order in each of my custodies. */
function groupLines(lines) {
  const map = new Map();
  for (const l of lines) {
    const k = `${l.custody_id}|${l.order_id}`;
    if (!map.has(k)) map.set(k, { ...l, lines: [] });
    map.get(k).lines.push(l);
  }
  return [...map.values()];
}

function orderCard(g, v, showCustody) {
  const rank = stageRank(g.stage);
  const next = v.targets.filter((t) => stageRank(t.stage) === rank + 1);
  const prev = v.targets.filter((t) => stageRank(t.stage) === rank - 1);
  const here = v.targets.find((t) => t.id === g.department_id);
  const good = g.lines.filter((l) => l.condition === "GOOD");
  const bad = g.lines.filter((l) => l.condition === "DEFECTIVE");
  const sum = (ls) => ls.reduce((s, l) => s + l.qty, 0);
  let main = null;
  if (good.length) {
    if (!next.length) main = h("p", { class: "small" }, "وصلت المخزن. التسليم للزبون من ", h("a", { attrs: { href: "#/warehouse" }, text: "المخزن والتسليم" }), ".");
    else if (next[0].mode === "INDIVIDUAL") main = distributeTable(g, good, next);
    else main = passTable(g, good, next);
  }
  return h("article", { class: "card m0 stock-group", dataset: { order: g.order_code } },
    h("div", { class: "ticket-head" },
      h("div", {}, h("div", { class: "ticket-code ltr", text: g.order_code }),
        h("div", { class: "ticket-sub" }, g.product_name, showCustody ? ` — ${g.custody_label}` : "")),
      h("div", { class: "row" }, badge(`سليم ${sum(good)}`, "ok"), bad.length ? badge(`معيب ${sum(bad)}`, "danger") : null)),
    routeRail(g.stage),
    h("div", { class: "small muted" }, "التسليم للزبون ", h("span", { class: "num", text: g.due_date })),
    h("div", { class: "hidden-totals" }, h("span", { class: "good-total", text: sum(good) }), h("span", { class: "bad-total", text: sum(bad) })),
    main ? h("div", { class: "mt" }, main) : null,
    bad.length ? h("div", { class: "alert warn mt", text: `قطع معيبة: ${bad.map((l) => `${lineName(l)} (${l.qty})`).join("، ")} — أصلحها، أو أرجعها، أو ينتظر قرار المشرف.` }) : null,
    h("div", { class: "row mt" },
      good.length ? details("تسجيل عيب", defectForm(good, v)) : null,
      bad.length ? details("تسجيل إصلاح", repairForm(bad, v)) : null,
      prev.length && here?.allow_return ? details(`إرجاع إلى ${prev.length === 1 ? prev[0].name : STAGE_LABEL[prev[0].stage]}`, returnForm(g.lines, prev)) : null));
}

// ---------------------------------------------------------------- 1. what was sent to me, one card per order
function groupIncoming(rows) {
  const map = new Map();
  for (const t of rows) {
    const k = `${t.order_code}|${t.from_custody_id}|${t.to_custody_id}|${t.direction}`;
    if (!map.has(k)) map.set(k, { ...t, items: [] });
    map.get(k).items.push(t);
  }
  return [...map.values()];
}

function incomingCard(g) {
  const total = g.items.reduce((s, t) => s + t.pending_qty, 0);
  const back = g.direction === "RETURN";
  const reasons = [...new Set(g.items.map((t) => t.reason).filter(Boolean))];
  const receive = actionButton(`استلام الكل (${total})`, {
    cls: "btn-block",
    run: async (op) => {
      const r = await op.run("app_receive_batch", (requestKey) => ({ p: { requestKey, transferIds: g.items.map((t) => t.id) } }));
      return `تم استلام ${r?.quantity ?? total} قطعة`;
    },
  });
  return h("article", { class: "card m0 incoming", dataset: { order: g.order_code } },
    h("div", { class: "ticket-head" },
      h("div", {}, h("div", { class: "ticket-code ltr", text: g.order_code }),
        h("div", { class: "ticket-sub" }, "من ", h("b", { text: g.from_label }), ` · ${fmtDate(g.created_at)}`)),
      h("div", { class: "row" },
        back ? badge("مُرجعة إليك", "warn") : null,
        g.items.some((t) => t.condition === "DEFECTIVE") ? badge("فيها معيب", "danger") : null,
        g.age_hours >= 24 ? badge(`منذ ${g.age_hours} ساعة`, "warn") : null)),
    reasons.length ? h("div", { class: "alert warn", text: `سبب الإرجاع: ${reasons.join("، ")}` }) : null,
    h("div", { class: "table-wrap" }, h("table", { class: "lines" },
      h("thead", {}, h("tr", {}, h("th", { text: "اللون / المقاس" }), h("th", { class: "num", text: "العدد" }))),
      h("tbody", {}, g.items.map((t) => h("tr", {},
        h("td", {}, `${t.color} / ${t.size}`, t.condition === "DEFECTIVE" ? h("span", { class: "badge danger sm", text: "معيب" }) : null),
        h("td", { class: "num", text: t.pending_qty })))),
      g.items.length > 1 ? h("tfoot", {}, h("tr", {}, h("th", { text: "المجموع" }), h("th", { class: "num", text: total }))) : null)),
    h("div", { class: "card-actions" }, receive),
    details("العدد لا يطابق؟ سجّل الفرق", h("div", { class: "stack" },
      h("p", { class: "small muted", text: "اختر السطر الذي فيه نقص أو زيادة. ما لم يُطابق يبقى «خلافاً» حتى يُحل." }),
      g.items.map((t) => h("div", { class: "sub-panel" }, h("b", { text: `${t.color} / ${t.size} — ${t.pending_qty}` }), partialReceiveForm(t))))));
}

// ---------------------------------------------------------------- page
export async function render({ me }) {
  const cutter = me.departments.some((d) => d.stage === "CUTTING");
  const [stock, incoming, cutting, work] = await Promise.all([
    rpc("app_my_stock"),
    rpc("app_list_transfers", { p_tab: "incoming" }),
    cutter ? rpc("app_cutting_view") : null,
    rpc("app_work_view"),
  ]);
  const myTasks = work.mine.filter((a) => ["ASSIGNED", "IN_PROGRESS"].includes(a.status));
  const groups = groupLines(stock.lines);
  const toCut = cutting ? cutting.orders.length + cutting.replacements.length : 0;
  const sections = [];

  if (incoming.rows.length) {
    const inc = groupIncoming(incoming.rows);
    sections.push(h("section", { class: "block section-incoming" },
      h("h2", {}, "وصلتك ", badge(String(inc.length), "warn")),
      h("p", { class: "section-hint", text: "عُدّ القطع، ثم اضغط «استلام الكل»." }),
      h("div", { class: "stack" }, inc.map(incomingCard))));
  }
  if (toCut) {
    sections.push(h("section", { class: "block" }, h("h2", {}, "للقص ", badge(String(toCut))),
      cutting.replacements.length ? h("div", { class: "stack" }, h("h3", { text: "قص بديل معتمد من المشرف" }),
        cutting.replacements.map((r) => replacementCard(r, cutting.depts))) : null,
      cutting.orders.length ? h("div", { class: "stack" }, cutting.orders.map((o) => cutOrderCard(o, cutting.depts))) : null));
  }
  if (groups.length) {
    sections.push(h("section", { class: "block" }, h("h2", {}, "عندك الآن ", badge(String(groups.length))),
      h("div", { class: "stack" }, groups.map((g) => orderCard(g, stock, stock.custodies.length > 1)))));
  }
  if (myTasks.length) {
    sections.push(h("section", { class: "block" }, h("h2", { text: "تكليفاتي" }),
      h("div", { class: "stack" }, myTasks.map((a) => h("div", { class: "card m0" },
        h("div", { class: "card-row" },
          h("div", {}, h("b", { class: "ltr", text: a.order_code }), ` — ${a.color} / ${a.size} · ${a.department_name}`,
            a.notes ? h("div", { class: "small", text: a.notes }) : null),
          h("span", { class: "num", text: `${a.completed_qty} / ${a.assigned_qty}` })),
        progressForm(a, work.can_cancel))))));
  }
  if (!sections.length) {
    sections.push(h("div", { class: "empty-state" },
      h("div", { class: "empty-mark", attrs: { "aria-hidden": "true" } }),
      h("h2", { text: stock.custodies.length || cutter ? "لا يوجد عمل بانتظارك" : "لم تُضف إلى أي قسم بعد" }),
      h("p", { text: stock.custodies.length || cutter ? "ستظهر هنا القطع فور إرسالها إليك." : "تواصل مع مدير النظام ليضيفك إلى قسمك." })));
  }
  return h("div", {}, pageHead("مهامي"), sections);
}
