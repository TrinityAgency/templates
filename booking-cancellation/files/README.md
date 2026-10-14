# booking-cancellation

Whether a booking can still be cancelled, and what it costs. Pure TypeScript: no dependencies, no
clock. Pass `now` in. It never throws: nonsense input returns `reason: 'invalid_input'`.

```ts
import { evaluate } from '@/utils/booking-cancellation/booking-cancellation';

const { allowed, feeMinor, freeUntil, reason } = evaluate({
  policy: { freeUntilHoursBefore: 24, lateFeeBp: 5000 },   // free until 24 h before, then 50 %
  booking: { status: 'confirmed', start: '2097-03-20T10:00:00+01:00', priceMinor: 9000 },
  cancelledBy: 'customer',
  now: new Date(),
});
```

## The rules

- Only a `held` (a request not yet accepted) or `confirmed` booking can be cancelled. Anything else
  returns `reason: 'closed'`.
- A visit that has begun (`now >= start`) cannot be cancelled: `reason: 'begun'`.
- `freeUntil = start − freeUntilHoursBefore`. Cancelling **at** `freeUntil` is still free. One second
  later, the fee applies.
- The fee applies only when the **customer** cancels a **confirmed** booking. A business cancelling and
  a request not yet accepted are always free.
- `fee = (priceMinor × lateFeeBp + 5000) ÷ 10000`, rounded half up to the minor unit and computed
  exactly. `lateFeeBp` is in basis points: 10000 = 100 %, 2500 = 25 %.
- `freeUntil` is written in the offset of `booking.start` (`Z` when you pass a `Date`).

Show the fee before the customer confirms. Collecting it is a payment module's job.

## With the booking-schema template

These are the rules `booking-schema` applies when a booking is cancelled, and the fee it stamps is the
same number. Read the policy from `booking.bookings` (`cancel_free_hours`, `late_cancel_fee_bp`, the
terms agreed at booking time, not the service's current ones). Read the price from `price_minor`, and
the start from `lower(during)`. Instants may be ISO strings, Postgres's text form or `Date` objects.
`price_minor` is a `bigint` column, which drivers return as a string such as `'9000'`: pass it as it
comes. A decimal string, a `bigint` or a number are all accepted, up to `Number.MAX_SAFE_INTEGER`.

`booking-types.ts` is this template's copy of the booking vocabulary (`VOCAB_VERSION = 1`). Other
booking templates ship their own copy. Compare the version numbers when you combine them.
