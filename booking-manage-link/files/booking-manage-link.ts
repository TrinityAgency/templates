// booking-manage-link.ts — a link that lets a customer view or cancel one booking without an account.
// The link carries a random 256-bit token; only its SHA-256 reaches your store, so a leaked table
// opens nothing. Expired, revoked, tampered and unknown links all get the same answer: { invalid: true }.
// Storage is yours, passed in as three callbacks. Server-side only (node:crypto).
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

/**
 * An instant: an ISO 8601 string with an offset, Postgres' text form ('2097-03-18 10:00:00+00')
 * or a Date — whatever your database driver hands you.
 */
export type Instant = string | Date;

/** What issue() asks your store to keep: the digest, never the token. */
export interface NewLink {
  /** SHA-256 of the token, 32 bytes */
  tokenSha256: Uint8Array;
  bookingId: string;
  issuedAt: Date;
  expiresAt: Date;
}

/** A stored link as your store returns it. */
export interface LinkRecord {
  tokenSha256: Uint8Array;
  bookingId: string;
  issuedAt: Instant;
  expiresAt: Instant;
  revokedAt: Instant | null;
}

/** Your storage, e.g. a table (token_sha256 bytea PRIMARY KEY, booking_id, issued_at, expires_at, revoked_at). */
export interface LinkStore {
  save(link: NewLink): Promise<void>;
  /** the link with exactly this digest, or null */
  find(tokenSha256: Uint8Array): Promise<LinkRecord | null>;
  /** stamp revokedAt on the link with this digest, if it is not revoked yet */
  revoke(tokenSha256: Uint8Array, at: Date): Promise<void>;
}

export interface IssueInput {
  bookingId: string;
  /** how long the link stays valid, in whole minutes (1 minute to 366 days) */
  ttlMinutes: number;
  /** absolute http(s) URL of your manage page; the token is appended as the last path segment */
  baseUrl: string;
  /** defaults to the current time */
  now?: Instant;
}

export interface Issued {
  url: string;
  token: string;
  /** ISO 8601, UTC */
  expiresAt: string;
}

export type Verified = { bookingId: string } | { invalid: true };

const TOKEN = /^[A-Za-z0-9_-]{43}$/;
// date, 'T' or ' ', time with optional seconds and fraction, then Z or an offset ±HH, ±HHMM or ±HH:MM
const INSTANT = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}(?::?\d{2})?)$/;
const MAX_TTL_MINUTES = 366 * 24 * 60;

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

function nowMs(now: Instant | undefined): number {
  const ms = now === undefined ? Date.now() : parseInstant(now);
  if (ms === null) throw new TypeError('booking-manage-link: now must be an ISO instant with an offset or a valid Date');
  return ms;
}

/** The SHA-256 of a token's UTF-8 bytes: what the store keeps and looks up. */
export function digestOf(token: string): Uint8Array {
  return new Uint8Array(createHash('sha256').update(token, 'utf8').digest());
}

const INVALID: Verified = { invalid: true };

/** Issue a new link for a booking. Throws TypeError on invalid input, before anything is stored. */
export async function issue(input: IssueInput, store: LinkStore): Promise<Issued> {
  const { bookingId, ttlMinutes, baseUrl } = input ?? ({} as IssueInput);
  if (typeof bookingId !== 'string' || bookingId === '') throw new TypeError('booking-manage-link: bookingId must be a non-empty string');
  if (!Number.isInteger(ttlMinutes) || ttlMinutes < 1 || ttlMinutes > MAX_TTL_MINUTES) {
    throw new TypeError(`booking-manage-link: ttlMinutes must be a whole number from 1 to ${MAX_TTL_MINUTES}`);
  }
  let base: URL;
  try {
    base = new URL(baseUrl);
  } catch {
    throw new TypeError('booking-manage-link: baseUrl must be an absolute URL');
  }
  if ((base.protocol !== 'https:' && base.protocol !== 'http:') || base.search !== '' || base.hash !== '') {
    throw new TypeError('booking-manage-link: baseUrl must be http(s), without a query or fragment');
  }
  const issuedMs = nowMs(input.now);

  const token = randomBytes(32).toString('base64url');
  const issuedAt = new Date(issuedMs);
  const expiresAt = new Date(issuedMs + ttlMinutes * 60_000);
  await store.save({ tokenSha256: digestOf(token), bookingId, issuedAt, expiresAt });
  return { url: `${base.href.replace(/\/+$/, '')}/${token}`, token, expiresAt: expiresAt.toISOString() };
}

/**
 * The booking a link opens, or { invalid: true } when it is expired, revoked, tampered or unknown.
 * Errors from your store are not swallowed: a database outage is not a bad link. A record your store hands
 * back in an unusable shape (digest not bytes, bookingId not a string, expiresAt without an offset) is a TypeError.
 */
export async function verify(token: string, store: LinkStore, now?: Instant): Promise<Verified> {
  const at = nowMs(now);
  if (typeof token !== 'string' || !TOKEN.test(token)) return { ...INVALID };
  const digest = digestOf(token);
  const record = await store.find(digest);
  if (!record) return { ...INVALID };
  const stored = record.tokenSha256;
  if (!(stored instanceof Uint8Array)) throw new TypeError('booking-manage-link: store.find must return tokenSha256 as bytes (Uint8Array or Buffer)');
  if (stored.length !== digest.length || !timingSafeEqual(stored, digest)) return { ...INVALID };
  const expires = parseInstant(record.expiresAt);
  if (expires === null) throw new TypeError('booking-manage-link: store.find must return expiresAt as a Date or an ISO instant with an offset');
  if (typeof record.bookingId !== 'string' || record.bookingId === '') throw new TypeError('booking-manage-link: store.find must return bookingId as a non-empty string');
  if (at >= expires) return { ...INVALID };
  if (record.revokedAt != null) return { ...INVALID };
  return { bookingId: record.bookingId };
}

/** Revoke a valid link, e.g. after the booking is cancelled. An invalid link stays invalid; the store is not asked. */
export async function revoke(token: string, store: LinkStore, now?: Instant): Promise<{ revoked: true } | { invalid: true }> {
  const at = nowMs(now);
  const v = await verify(token, store, new Date(at));
  if ('invalid' in v) return { invalid: true };
  await store.revoke(digestOf(token), new Date(at));
  return { revoked: true };
}
