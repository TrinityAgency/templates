// booking-cancellation.ts — what cancelling a booking costs, and whether it is still possible.
// Pure and deterministic: pass `now`. Never throws: nonsense input returns reason 'invalid_input'.
// The arithmetic is booking-schema's: the fee is stamped by the same rule when a booking is cancelled.
import type { BookingStatus, CancellationPolicy, CancellingParty } from './booking-types';

/**
 * An instant: an ISO 8601 string with an offset ('2097-03-20T10:00:00+01:00'), Postgres' text form
 * ('2097-03-20 10:00:00+01') or a Date — whatever your database driver hands you.
 */
export type Instant = string | Date;

/** The fields of a booking that decide its cancellation. */
export interface CancellableBooking {
  status: BookingStatus;
  /** the visit's start */
  start: Instant;
  /** the agreed price in minor units; a bigint column may arrive as a decimal string or a bigint */
  priceMinor: number | bigint | string;
}

export interface EvaluateInput {
  policy: CancellationPolicy;
  booking: CancellableBooking;
  cancelledBy: CancellingParty;
  now: Instant;
}

export type NotCancellableReason = 'closed' | 'begun' | 'invalid_input';

export interface Evaluation {
  allowed: boolean;
  /** what the cancelling party is charged, in minor units (0 when free or not allowed) */
  feeMinor: number;
  /** the last free instant, ISO 8601 in the offset of booking.start (Z for a Date); null on invalid input */
  freeUntil: string | null;
  reason?: NotCancellableReason;
}

// date, 'T' or ' ', time with optional seconds and fraction, then Z or an offset ±HH, ±HHMM or ±HH:MM
const INSTANT = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}(?::?\d{2})?)$/;
const STATUSES: readonly string[] = ['held', 'confirmed', 'completed', 'no_show', 'cancelled', 'declined', 'expired'];
const HOUR = 3_600_000;

/** The late fee, rounded half up to the minor unit: (price × bp + 5000) ÷ 10000, exactly. */
export function lateFeeMinor(priceMinor: number, feeBp: number): number {
  return Number((BigInt(priceMinor) * BigInt(feeBp) + BigInt(5000)) / BigInt(10000));
}

/** An instant as epoch ms plus its offset in minutes (0 for Z or a Date), or null. */
function parseInstant(v: unknown): { ms: number; offsetMin: number } | null {
  if (v instanceof Date) return Number.isFinite(v.getTime()) ? { ms: v.getTime(), offsetMin: 0 } : null;
  if (typeof v !== 'string') return null;
  const m = INSTANT.exec(v);
  if (!m) return null;
  const [, date, hm, sec = '00', frac = '', zone = 'Z'] = m;
  const off = zone === 'Z' ? 'Z' : `${zone.slice(0, 3)}:${zone.length > 3 ? zone.slice(-2) : '00'}`;
  const ms = Date.parse(`${date}T${hm}:${sec}.${frac.padEnd(3, '0').slice(0, 3)}${off}`);
  if (!Number.isFinite(ms)) return null;
  const offsetMin = off === 'Z' ? 0 : (off[0] === '-' ? -1 : 1) * (Number(off.slice(1, 3)) * 60 + Number(off.slice(4, 6)));
  return { ms, offsetMin };
}

/** A price in minor units as a safe non-negative integer, from a number, a bigint or a decimal string; else null. */
function minorUnits(v: unknown): number | null {
  const n = typeof v === 'bigint' ? (v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : -1)
    : typeof v === 'string' && /^(0|[1-9]\d{0,15})$/.test(v) ? Number(v)
    : v;
  return isInt(n, 0, Number.MAX_SAFE_INTEGER) ? n : null;
}

function isInt(n: unknown, lo: number, hi: number): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n >= lo && n <= hi;
}

/** ms as ISO 8601 to the second, written in the given offset (0 → Z). */
function toIso(ms: number, offsetMin: number): string {
  const wall = new Date(Math.floor(ms / 1000) * 1000 + offsetMin * 60_000).toISOString().slice(0, 19);
  if (offsetMin === 0) return `${wall}Z`;
  const a = Math.abs(offsetMin);
  const two = (n: number) => String(n).padStart(2, '0');
  return `${wall}${offsetMin < 0 ? '-' : '+'}${two(Math.floor(a / 60))}:${two(a % 60)}`;
}

const INVALID: Evaluation = { allowed: false, feeMinor: 0, freeUntil: null, reason: 'invalid_input' };

export function evaluate(input: EvaluateInput): Evaluation {
  try {
    const { policy, booking, cancelledBy } = input;
    if (!policy || !isInt(policy.freeUntilHoursBefore, 0, 720) || !isInt(policy.lateFeeBp, 0, 10000)) return { ...INVALID };
    if (!booking || !STATUSES.includes(booking.status)) return { ...INVALID };
    const price = minorUnits(booking.priceMinor);
    if (price === null) return { ...INVALID };
    if (cancelledBy !== 'customer' && cancelledBy !== 'business') return { ...INVALID };
    const begins = parseInstant(booking.start);
    const at = parseInstant(input.now);
    if (begins === null || at === null) return { ...INVALID };
    const start = begins.ms;
    const now = at.ms;

    const freeUntilMs = start - policy.freeUntilHoursBefore * HOUR;
    const freeUntil = toIso(freeUntilMs, begins.offsetMin);
    if (booking.status !== 'held' && booking.status !== 'confirmed') return { allowed: false, feeMinor: 0, freeUntil, reason: 'closed' };
    if (now >= start) return { allowed: false, feeMinor: 0, freeUntil, reason: 'begun' };
    const late = booking.status === 'confirmed' && cancelledBy === 'customer' && now > freeUntilMs;
    return { allowed: true, feeMinor: late ? lateFeeMinor(price, policy.lateFeeBp) : 0, freeUntil };
  } catch {
    return { ...INVALID };
  }
}
