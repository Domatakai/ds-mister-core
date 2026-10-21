import type { OsdRow } from "@/lib/osd-tree";

/**
 * The OSD panel itself — a near-black, hairline-bordered slab of mono type,
 * styled after the translucent menu MiSTer cores draw over video output.
 * Purely presentational: callers own selection state and input handling.
 */
export function OsdPanel({
  title,
  rows,
  activeIndex = 0,
  statusLine,
  onRowClick,
  maxRows = 8,
  className = "",
}: {
  title: string;
  rows: OsdRow[];
  /** Index of the highlighted row. */
  activeIndex?: number;
  /** MiSTer-style status line pinned to the bottom of the panel. */
  statusLine?: string;
  /** Present when the panel is interactive. */
  onRowClick?: (index: number) => void;
  maxRows?: number;
  className?: string;
}) {
  const clampedActive = Math.min(Math.max(activeIndex, 0), Math.max(rows.length - 1, 0));
  const start =
    rows.length > maxRows
      ? Math.min(
          Math.max(clampedActive - Math.floor(maxRows / 2), 0),
          rows.length - maxRows,
        )
      : 0;
  const window_ = rows.slice(start, start + maxRows);
  const pad = Math.max(maxRows - window_.length, 0);

  return (
    <div
      className={`border border-white/12 bg-[#131312]/95 font-mono text-[12px] leading-none text-[#ECECE7] shadow-[0_24px_70px_-28px_rgba(0,0,0,0.55)] ${className}`}
    >
      <div className="flex items-center justify-between border-b border-white/12 px-3.5 py-2.5">
        <span className="text-[11px] tracking-[0.2em] uppercase text-white/90">
          {title}
        </span>
        <span className="text-[10px] tracking-[0.14em] text-white/35 tabular-nums">
          {rows.length > 0 ? `${clampedActive + 1}/${rows.length}` : "0/0"}
        </span>
      </div>

      <div className="py-1">
        {window_.map((row, i) => {
          const index = start + i;
          const active = index === clampedActive;
          return (
            <div
              key={`${row.label}-${index}`}
              onClick={onRowClick ? () => onRowClick(index) : undefined}
              className={[
                "flex h-[30px] items-center justify-between gap-3 px-3.5",
                active ? "bg-white/12" : "",
                onRowClick ? "cursor-pointer" : "",
              ].join(" ")}
            >
              <span className="flex min-w-0 items-center gap-2.5">
                <span
                  className={`w-2 shrink-0 text-[10px] ${active ? "text-white" : "text-transparent"}`}
                  aria-hidden
                >
                  ▸
                </span>
                <span
                  className={`truncate tracking-[0.02em] ${active ? "text-white" : "text-white/65"}`}
                >
                  {row.label}
                </span>
              </span>
              {row.kind === "value" && (
                <span
                  className={`shrink-0 tabular-nums ${
                    active ? "text-white/85" : "text-white/40"
                  }`}
                >
                  ‹ {row.value} ›
                </span>
              )}
              {row.kind === "submenu" && (
                <span
                  className={`shrink-0 text-[11px] ${active ? "text-white/85" : "text-white/35"}`}
                  aria-hidden
                >
                  ›
                </span>
              )}
            </div>
          );
        })}
        {pad > 0 &&
          Array.from({ length: pad }).map((_, i) => (
            <div key={`pad-${i}`} className="h-[30px]" />
          ))}
      </div>

      {statusLine && (
        <div className="truncate border-t border-white/12 px-3.5 py-2.5 text-[11px] tracking-[0.04em] text-white/45">
          {statusLine}
        </div>
      )}
    </div>
  );
}
