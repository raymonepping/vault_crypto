export const bytes = (n) =>
  n == null ? "–" : n >= 1024 ? `${(n / 1024).toFixed(1)} KB` : `${n} B`;
export const int = (n) =>
  n == null ? "–" : new Intl.NumberFormat("en-GB").format(n);
export const ratio = (a, b) => (a && b ? `${(a / b).toFixed(1)}×` : "–");

export function when(iso) {
  if (!iso) return "–";
  const d = new Date(iso);
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export function relative(iso) {
  if (!iso) return "–";
  const s = Math.round((new Date(iso) - Date.now()) / 1000);
  const a = Math.abs(s);
  const v =
    a < 90
      ? `${a}s`
      : a < 5400
        ? `${Math.round(a / 60)}m`
        : a < 172800
          ? `${Math.round(a / 3600)}h`
          : `${Math.round(a / 86400)}d`;
  return s >= 0 ? `in ${v}` : `${v} ago`;
}

export const short = (s, n = 24) =>
  !s ? "–" : s.length > n ? `${s.slice(0, n)}…` : s;

export const date = (iso) =>
  !iso
    ? "–"
    : new Date(iso).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
      });
