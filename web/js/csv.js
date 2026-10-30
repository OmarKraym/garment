// CSV export generated in the browser from server-authorized data, with spreadsheet
// formula-injection protection (OWASP) and a UTF-8 BOM so Excel shows Arabic correctly.
const DANGEROUS = /^[=+\-@\t\r]/;

export function csvCell(v) {
  if (v === null || v === undefined) return "";
  let s = String(v).replace(/[\u2066-\u2069]/g, ""); // drop display-only bidi isolates
  if (typeof v === "string" && DANGEROUS.test(s)) s = `'${s}`;
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function toCsv(columns, rows) {
  const lines = [columns.map((c) => csvCell(c.header)).join(",")];
  for (const r of rows) lines.push(columns.map((c) => csvCell(c.value(r))).join(","));
  return "﻿" + lines.join("\r\n") + "\r\n";
}

export function downloadCsv(name, columns, rows) {
  const blob = new Blob([toCsv(columns, rows)], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `${name}-${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
