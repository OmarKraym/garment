// Small line-icon set (24×24, 1.75 stroke), built with DOM APIs — no innerHTML, no external files.
const NS = "http://www.w3.org/2000/svg";

const PATHS = {
  tasks: ["M9 4h6a1 1 0 0 1 1 1v1H8V5a1 1 0 0 1 1-1z", "M8 6H6a1 1 0 0 0-1 1v13a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V7a1 1 0 0 0-1-1h-2", "M9 13l2 2 4-4"],
  dashboard: ["M4 4h7v7H4z", "M13 4h7v4h-7z", "M13 10h7v10h-7z", "M4 13h7v7H4z"],
  orders: ["M7 3h10l2 3v15H5V6z", "M5 6h14", "M9 11h6", "M9 15h4"],
  warehouse: ["M3 9l9-5 9 5v11H3z", "M8 20v-7h8v7", "M8 16h8"],
  quality: ["M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z", "M12 8v5", "M12 16h.01"],
  transfers: ["M4 8h13", "M14 5l3 3-3 3", "M20 16H7", "M10 13l-3 3 3 3"],
  work: ["M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", "M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6", "M16 5.5a3 3 0 0 1 0 5.5", "M18 14.5c1.8.8 3 2.6 3 5.5"],
  reports: ["M4 20V10", "M10 20V4", "M16 20v-7", "M22 20H2"],
  admin: ["M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", "M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"],
  account: ["M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z", "M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8"],
  more: ["M5 12h.01", "M12 12h.01", "M19 12h.01"],
  logout: ["M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3", "M10 17l-5-5 5-5", "M5 12h11"],
  close: ["M6 6l12 12", "M18 6L6 18"],
  plus: ["M12 5v14", "M5 12h14"],
  check: ["M5 12l5 5 9-10"],
  back: ["M9 6l6 6-6 6"],
};

/** icon("tasks", 22) → <svg aria-hidden="true">…</svg> */
export function icon(name, size = 22) {
  const svg = document.createElementNS(NS, "svg");
  for (const [k, v] of Object.entries({ viewBox: "0 0 24 24", width: size, height: size, fill: "none", stroke: "currentColor",
    "stroke-width": name === "more" ? 3 : 1.75, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false" })) {
    svg.setAttribute(k, String(v));
  }
  svg.classList.add("icon");
  for (const d of PATHS[name] ?? []) {
    const p = document.createElementNS(NS, "path");
    p.setAttribute("d", d);
    svg.append(p);
  }
  return svg;
}
