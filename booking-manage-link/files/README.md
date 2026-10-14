# booking-manage-link

A link that lets a customer view or cancel one booking without an account. The link carries a random
256-bit token. Only the token's SHA-256 reaches your store, so a leaked table opens nothing. Expired,
revoked, tampered and unknown links all get the same answer: `{ invalid: true }`. Server-side only
(`node:crypto`). No dependencies; storage is yours, passed in as three callbacks.

```ts
import { issue, verify, revoke } from '@/lib/booking-manage-link/booking-manage-link';

// after the booking is made: send `url` in the confirmation email, never store it
const { url } = await issue({ bookingId, ttlMinutes: 60 * 24 * 30, baseUrl: 'https://example.com/manage' }, store);

// on the manage page, /manage/[token]
const link = await verify(params.token, store);
if ('invalid' in link) return neutralPage();          // one page for expired, revoked, tampered and unknown
const booking = await loadBooking(link.bookingId);

// after the customer cancels, or when you send a fresh link
await revoke(params.token, store);
```

## The store

```ts
import type { LinkStore } from '@/lib/booking-manage-link/booking-manage-link';

// postgres.js, with the booking-schema template's table booking.manage_links
export const store: LinkStore = {
  async save(l) {
    await sql`INSERT INTO booking.manage_links (token_sha256, booking_id, issued_at, expires_at)
              VALUES (${Buffer.from(l.tokenSha256)}, ${l.bookingId}, ${l.issuedAt}, ${l.expiresAt})`;
  },
  async find(d) {
    const [r] = await sql`SELECT token_sha256, booking_id, issued_at, expires_at, revoked_at
                          FROM booking.manage_links WHERE token_sha256 = ${Buffer.from(d)}`;
    return r ? { tokenSha256: r.token_sha256, bookingId: r.booking_id, issuedAt: r.issued_at, expiresAt: r.expires_at, revokedAt: r.revoked_at } : null;
  },
  async revoke(d, at) {
    await sql`UPDATE booking.manage_links SET revoked_at = ${at} WHERE token_sha256 = ${Buffer.from(d)} AND revoked_at IS NULL`;
  },
};
```

Any storage works: the store receives `{ tokenSha256, bookingId, issuedAt, expiresAt }` and must find a
link by the exact 32-byte digest. `find` may return instants as `Date` objects or strings, the way your
driver hands them over, as long as a string carries its offset (`timestamptz`, not `timestamp`). Return
`tokenSha256` as bytes (`Buffer` or `Uint8Array`) and `bookingId` as a string (`String(id)` for integer
ids). A record in any other shape makes `verify` throw a `TypeError` instead of calling every link
invalid, so a misconfigured store shows up on the first test, not in customer complaints.

## The rules

- A link is valid until `expiresAt`, exclusive: at that instant it is invalid. `ttlMinutes` runs from
  1 minute to 366 days.
- A revoked link stays invalid. Revoking an invalid link does nothing and returns `{ invalid: true }`.
- The stored digest is compared with the token's digest in constant time, so even a store that returns
  the wrong row cannot open a booking.
- `issue` throws a `TypeError` on invalid input (empty booking id, a ttl out of range, a base URL that is
  not absolute http(s) or carries a query), before anything is stored.
- Errors from your store are not swallowed: a database outage is an error, not a bad link.
- `now` is optional on every call, for tests and for replaying a clock.

## Keep the token out of logs and other sites

The token is in the URL path. Serve the manage page with `Referrer-Policy: same-origin`, so the link never
travels to another site in a `Referer` header, and keep request paths of that route out of your logs.

## With the booking-schema template

`booking.manage_links` stores exactly what `issue` hands over: the schema refuses anything but a
32-byte digest. Delete expired links with `SELECT booking.prune_manage_links();` from a scheduled job
(as the schema's `app_writer` role this needs booking-schema 1.0.1 or later).

`booking-types.ts` is this template's copy of the booking vocabulary (`VOCAB_VERSION = 1`). Other
booking templates ship their own copy. Compare the version numbers when you combine them.
