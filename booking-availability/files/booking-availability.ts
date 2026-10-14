// booking-availability.ts — free slots from working hours, busy footprints and travel time.
// Pure and deterministic: no I/O, no clock (pass `now`), no dependencies. Never throws:
// nonsense input returns { slots: [], reason: 'invalid_input' }.
import type { Duration, Resource, Service, Slot } from './booking-types';

/**
 * An instant: an ISO 8601 string with an offset ('2097-03-18T10:00:00+01:00'), Postgres' text form
 * ('2097-03-18 10:00:00+01') or a Date — whatever your database driver hands you.
 */
export type Instant = string | Date;

/** A recurring wall-clock window, in the business time zone, on one ISO weekday (1 = Monday … 7 = Sunday). */
export interface WeeklyWindow {
  resourceId: string;
  isoWeekday: number;
  /** 'HH:MM' (or 'HH:MM:00'), 00:00–23:59 */
  opens: string;
  /** 'HH:MM' (or 'HH:MM:00'), after opens; '24:00' = end of day */
  closes: string;
  /** first date it applies, 'YYYY-MM-DD' (inclusive); omitted or null = always */
  effectiveFrom?: string | null;
  /** first date it no longer applies, 'YYYY-MM-DD' (exclusive); omitted or null = forever */
  effectiveTo?: string | null;
}

/** A dated change to one resource's hours, the same wall-clock window on every date of [fromDate, toDate). */
export interface HoursException {
  resourceId: string;
  fromDate: string;
  toDate: string;
  starts: string;
  ends: string;
  effect: 'closed' | 'open';
}

/** A footprint that already occupies a resource (buffers included), e.g. a row of booking.v_busy. */
export interface BusySpan {
  resourceId: string;
  start: Instant;
  end: Instant;
  zoneId: string;
}

/**
 * Minutes a resource needs between a footprint in zone `from` and the next one in zone `to`
 * (base buffer + travel), or null when unknown — then the slot is not offered.
 */
export type TravelMinutes = (fromZoneId: string, toZoneId: string) => number | null;

export interface FindSlotsInput {
  timeZone: string;
  /** slot starts are offered in [from, to) */
  from: Instant;
  to: Instant;
  service: Service;
  duration: Duration;
  /** the resources able to perform the service, in order of preference */
  resources: Resource[];
  weeklyHours: WeeklyWindow[];
  exceptions: HoursException[];
  busy: BusySpan[];
  /** where the visit happens: the premises zone, or the customer's zone */
  zoneId: string;
  travelMinutes: TravelMinutes;
  /** earliest start = now + leadTimeMin */
  leadTimeMin: number;
  /** slot starts sit on wall-clock multiples of stepMin from midnight */
  stepMin: number;
  now: Instant;
}

export type NoSlotsReason = 'no_hours' | 'no_resource' | 'outside_window' | 'invalid_input';

export interface FindSlotsResult {
  slots: Slot[];
  reason?: NoSlotsReason;
}

/** The longest window findSlots accepts, in days. */
export const MAX_WINDOW_DAYS = 62;

const MINUTE = 60_000;
const DAY = 86_400_000;
// date, 'T' or ' ', time with optional seconds and fraction, then Z or an offset ±HH, ±HHMM or ±HH:MM
const INSTANT = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}(?::?\d{2})?)$/;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
// 'HH:MM', or 'HH:MM:00' as a Postgres driver returns a time column; '24:00' = end of day
const HH_MM = /^(?:([01]\d|2[0-3]):[0-5]\d|24:00)(?::00)?$/;

// ───────────────────────────── time zone arithmetic (Intl only)

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone, hourCycle: 'h23',
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    formatters.set(timeZone, f);
  }
  return f;
}

export function isTimeZone(timeZone: string): boolean {
  try {
    formatter(timeZone);
    return true;
  } catch {
    return false;
  }
}

/** The zone's offset from UTC at an instant, in minutes (Vienna in winter: 60). */
export function offsetMinutes(timeZone: string, ms: number): number {
  const parts = formatter(timeZone).formatToParts(new Date(ms));
  const get = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((p) => p.type === type)?.value);
  const wall = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'));
  return Math.round((wall - Math.floor(ms / 1000) * 1000) / MINUTE);
}

/**
 * Every instant whose wall-clock time in the zone is `minuteOfDay` on the date (y, m, d):
 * none in a spring-forward gap, two in an autumn overlap (earlier first). minuteOfDay 1440 is
 * the next day's midnight.
 */
export function wallToInstants(timeZone: string, y: number, m: number, d: number, minuteOfDay: number): number[] {
  const naive = Date.UTC(y, m - 1, d) + minuteOfDay * MINUTE;
  const out: number[] = [];
  for (const probe of [naive - DAY / 2, naive + DAY / 2]) {
    const t = naive - offsetMinutes(timeZone, probe) * MINUTE;
    if (offsetMinutes(timeZone, t) * MINUTE === naive - t && !out.includes(t)) out.push(t);
  }
  return out.sort((a, b) => a - b);
}

/**
 * The zone's offset on a local date when it holds all day (no transition within 12 hours of it),
 * else null. Days without a transition — nearly all — then convert wall-clock time by arithmetic.
 */
export function dayOffset(timeZone: string, y: number, m: number, d: number): number | null {
  const midnight = Date.UTC(y, m - 1, d);
  const a = offsetMinutes(timeZone, midnight - DAY);
  const b = offsetMinutes(timeZone, midnight + 2 * DAY);
  return a === b && offsetMinutes(timeZone, midnight + DAY / 2) === a ? a : null;
}

/** A window boundary: the earlier instant of an ambiguous time; a time inside a gap moves forward past it. */
function boundary(timeZone: string, y: number, m: number, d: number, minuteOfDay: number): number {
  const [earlier] = wallToInstants(timeZone, y, m, d, minuteOfDay);
  if (earlier !== undefined) return earlier;
  const naive = Date.UTC(y, m - 1, d) + minuteOfDay * MINUTE;
  return naive - offsetMinutes(timeZone, naive - DAY / 2) * MINUTE;
}

/** An instant as ISO 8601 with the zone's offset at that instant, to the second. */
export function toIsoInZone(timeZone: string, ms: number): string {
  const off = offsetMinutes(timeZone, ms);
  const w = new Date(Math.floor(ms / 1000) * 1000 + off * MINUTE);
  const two = (n: number) => String(n).padStart(2, '0');
  const sign = off < 0 ? '-' : '+';
  const a = Math.abs(off);
  return `${String(w.getUTCFullYear()).padStart(4, '0')}-${two(w.getUTCMonth() + 1)}-${two(w.getUTCDate())}` +
    `T${two(w.getUTCHours())}:${two(w.getUTCMinutes())}:${two(w.getUTCSeconds())}${sign}${two(Math.floor(a / 60))}:${two(a % 60)}`;
}

function parseInstant(v: unknown): number | null {
  if (v instanceof Date) return Number.isFinite(v.getTime()) ? v.getTime() : null;
  if (typeof v !== 'string') return null;
  const m = INSTANT.exec(v);
  if (!m) return null;
  const [, date, hm, sec = '00', frac = '', zone = 'Z'] = m;
  const off = zone === 'Z' ? 'Z' : `${zone.slice(0, 3)}:${zone.length > 3 ? zone.slice(-2) : '00'}`;
  const ms = Date.parse(`${date}T${hm}:${sec}.${frac.padEnd(3, '0').slice(0, 3)}${off}`);
  return Number.isFinite(ms) ? ms : null;
}

function minuteOf(hhmm: string): number {
  return Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));
}

function isInt(n: unknown, lo: number, hi: number): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n >= lo && n <= hi;
}

function isDate(s: unknown): s is string {
  return typeof s === 'string' && ISO_DATE.test(s) && !Number.isNaN(Date.parse(`${s}T00:00:00Z`));
}

// ───────────────────────────── hours: wall-clock windows per resource and date

type Span = [number, number];

/** Sorted, merged union of minute spans. */
function union(spans: Span[]): Span[] {
  const s = [...spans].sort((a, b) => a[0] - b[0]);
  const out: Span[] = [];
  for (const [a, b] of s) {
    const last = out[out.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else out.push([a, b]);
  }
  return out;
}

function subtract(spans: Span[], cut: Span): Span[] {
  const out: Span[] = [];
  for (const [a, b] of spans) {
    if (cut[1] <= a || cut[0] >= b) { out.push([a, b]); continue; }
    if (a < cut[0]) out.push([a, cut[0]]);
    if (cut[1] < b) out.push([cut[1], b]);
  }
  return out;
}

/** The open minute spans of one resource on one local date. */
function openMinutes(resourceId: string, date: string, isoWeekday: number, weekly: WeeklyWindow[], exceptions: HoursException[]): Span[] {
  let spans: Span[] = [];
  for (const w of weekly) {
    if (w.resourceId !== resourceId || w.isoWeekday !== isoWeekday) continue;
    if (w.effectiveFrom != null && date < w.effectiveFrom) continue;
    if (w.effectiveTo != null && date >= w.effectiveTo) continue;
    spans.push([minuteOf(w.opens), minuteOf(w.closes)]);
  }
  const today = exceptions.filter((e) => e.resourceId === resourceId && e.fromDate <= date && date < e.toDate);
  for (const e of today) if (e.effect === 'open') spans.push([minuteOf(e.starts), minuteOf(e.ends)]);
  spans = union(spans);
  for (const e of today) if (e.effect === 'closed') spans = subtract(spans, [minuteOf(e.starts), minuteOf(e.ends)]);
  return spans;
}

// ───────────────────────────── validation

function validate(i: FindSlotsInput): boolean {
  if (!i || typeof i !== 'object') return false;
  if (typeof i.timeZone !== 'string' || !isTimeZone(i.timeZone)) return false;
  if ([i.from, i.to, i.now].some((s) => parseInstant(s) === null)) return false;
  const s = i.service;
  if (!s || !isInt(s.bufferBeforeMin, 0, 240) || !isInt(s.bufferAfterMin, 0, 240) || !isInt(s.resourcesRequired, 1, 10)) return false;
  if (!i.duration || !isInt(i.duration.minutes, 5, 1440)) return false;
  if (!isInt(i.stepMin, 1, 1440) || !isInt(i.leadTimeMin, 0, 525_600)) return false;
  if (typeof i.zoneId !== 'string' || typeof i.travelMinutes !== 'function') return false;
  if (!Array.isArray(i.resources) || !Array.isArray(i.weeklyHours) || !Array.isArray(i.exceptions) || !Array.isArray(i.busy)) return false;
  if (i.resources.some((r) => !r || typeof r.id !== 'string')) return false;
  for (const w of i.weeklyHours) {
    if (!w || typeof w.resourceId !== 'string' || !isInt(w.isoWeekday, 1, 7)) return false;
    if (!HH_MM.test(w.opens) || minuteOf(w.opens) === 1440 || !HH_MM.test(w.closes) || minuteOf(w.closes) <= minuteOf(w.opens)) return false;
    if (w.effectiveFrom != null && !isDate(w.effectiveFrom)) return false;
    if (w.effectiveTo != null && !isDate(w.effectiveTo)) return false;
  }
  for (const e of i.exceptions) {
    if (!e || typeof e.resourceId !== 'string' || !isDate(e.fromDate) || !isDate(e.toDate) || e.toDate <= e.fromDate) return false;
    if (!HH_MM.test(e.starts) || minuteOf(e.starts) === 1440 || !HH_MM.test(e.ends) || minuteOf(e.ends) <= minuteOf(e.starts)) return false;
    if (e.effect !== 'closed' && e.effect !== 'open') return false;
  }
  for (const b of i.busy) {
    if (!b || typeof b.resourceId !== 'string' || typeof b.zoneId !== 'string') return false;
    const a = parseInstant(b.start);
    const z = parseInstant(b.end);
    if (a === null || z === null || z <= a) return false;
  }
  return true;
}

// ───────────────────────────── the calculator

interface Busy { start: number; end: number; zoneId: string }

/** Is one resource free for a footprint [fpStart, fpEnd) in `zoneId`? Mirrors the schema's L1 and L19/L20. */
function resourceIsFree(busy: Busy[], fpStart: number, fpEnd: number, zoneId: string, travel: TravelMinutes): boolean {
  let before: Busy | undefined;
  let after: Busy | undefined;
  for (const b of busy) {
    if (b.start < fpEnd && fpStart < b.end) return false;
    if (b.end <= fpStart && (!before || b.end > before.end)) before = b;
    if (b.start >= fpEnd && (!after || b.start < after.start)) after = b;
  }
  if (before) {
    const need = travel(before.zoneId, zoneId);
    if (need === null || Math.floor((fpStart - before.end) / MINUTE) < need) return false;
  }
  if (after) {
    const need = travel(zoneId, after.zoneId);
    if (need === null || Math.floor((after.start - fpEnd) / MINUTE) < need) return false;
  }
  return true;
}

export function findSlots(input: FindSlotsInput): FindSlotsResult {
  try {
    return find(input);
  } catch {
    return { slots: [], reason: 'invalid_input' };
  }
}

function find(i: FindSlotsInput): FindSlotsResult {
  if (!validate(i)) return { slots: [], reason: 'invalid_input' };
  const from = parseInstant(i.from)!;
  const to = parseInstant(i.to)!;
  const now = parseInstant(i.now)!;
  if (to - from > MAX_WINDOW_DAYS * DAY) return { slots: [], reason: 'invalid_input' };
  const earliest = Math.max(from, now + i.leadTimeMin * MINUTE);
  if (to <= earliest) return { slots: [], reason: 'outside_window' };
  const need = i.service.resourcesRequired;
  if (i.resources.length < need) return { slots: [], reason: 'no_resource' };

  const before = i.service.bufferBeforeMin * MINUTE;
  const after = i.service.bufferAfterMin * MINUTE;
  const length = i.duration.minutes * MINUTE;
  const busyOf = new Map<string, Busy[]>();
  for (const r of i.resources) busyOf.set(r.id, []);
  for (const b of i.busy) busyOf.get(b.resourceId)?.push({ start: parseInstant(b.start)!, end: parseInstant(b.end)!, zoneId: b.zoneId });

  // free resource ids per slot start (ms), in resource order
  const freeAt = new Map<number, string[]>();
  let anyHours = false;
  // local dates from the day before `from` to the day after `to` (a window can start on either side of midnight UTC)
  const first = new Date(from + offsetMinutes(i.timeZone, from) * MINUTE);
  const days = Math.ceil((to - from) / DAY) + 2;
  for (const r of i.resources) {
    for (let k = -1; k <= days; k++) {
      const day = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), first.getUTCDate() + k));
      const [y, m, d] = [day.getUTCFullYear(), day.getUTCMonth() + 1, day.getUTCDate()];
      const date = day.toISOString().slice(0, 10);
      const isoWeekday = ((day.getUTCDay() + 6) % 7) + 1;
      const fixed = dayOffset(i.timeZone, y, m, d);
      for (const [open, close] of openMinutes(r.id, date, isoWeekday, i.weeklyHours, i.exceptions)) {
        const midnight = Date.UTC(y, m - 1, d);
        const at = (minute: number) => midnight + (minute - (fixed ?? 0)) * MINUTE;
        const winStart = fixed !== null ? at(open) : boundary(i.timeZone, y, m, d, open);
        const winEnd = fixed !== null ? at(close) : boundary(i.timeZone, y, m, d, close);
        if (winStart < to && winEnd > from) anyHours = true; // open hours inside [from, to), not on a neighbouring day
        for (let minute = Math.ceil(open / i.stepMin) * i.stepMin; minute < close; minute += i.stepMin) {
          // spring forward: a wall-clock time that does not exist has no instant and is skipped;
          // autumn: a repeated time is offered once, at its first occurrence
          const start = fixed !== null ? at(minute) : wallToInstants(i.timeZone, y, m, d, minute)[0];
          if (start === undefined) continue;
          if (start < earliest || start <= now || start >= to) continue; // the schema refuses a customer start at now (L15)
          const fpStart = start - before;
          const fpEnd = start + length + after;
          if (fpStart < winStart || fpEnd > winEnd) continue;
          if (!resourceIsFree(busyOf.get(r.id)!, fpStart, fpEnd, i.zoneId, i.travelMinutes)) continue;
          const list = freeAt.get(start) ?? [];
          list.push(r.id);
          freeAt.set(start, list);
        }
      }
    }
  }
  if (!anyHours) return { slots: [], reason: 'no_hours' };

  const order = new Map(i.resources.map((r, n) => [r.id, n] as const));
  const slots: Slot[] = [];
  for (const start of [...freeAt.keys()].sort((a, b) => a - b)) {
    const ids = freeAt.get(start)!;
    if (ids.length < need) continue;
    ids.sort((a, b) => order.get(a)! - order.get(b)!);
    slots.push({
      start: toIsoInZone(i.timeZone, start),
      end: toIsoInZone(i.timeZone, start + length),
      resourceIds: ids.slice(0, need),
      zoneId: i.zoneId,
    });
  }
  return { slots };
}

/**
 * travelMinutes from rows of booking.v_travel_gaps (gap_minutes = base buffer + travel), with the
 * schema's rule: a listed trip needs its gap; the same zone without a row needs nothing; any other
 * trip is unknown (null).
 */
export function travelFromGaps(rows: { fromZoneId: string; toZoneId: string; gapMinutes: number }[]): TravelMinutes {
  const gaps = new Map(rows.map((r) => [`${r.fromZoneId}\u0000${r.toZoneId}`, r.gapMinutes] as const));
  return (fromZoneId, toZoneId) => gaps.get(`${fromZoneId}\u0000${toZoneId}`) ?? (fromZoneId === toZoneId ? 0 : null);
}
