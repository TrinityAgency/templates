# booking-availability

Free appointment slots from working hours, existing bookings and travel time. Pure TypeScript: no
dependencies, no I/O, no clock. Pass `now` in, get slots out. It never throws: nonsense input returns
`{ slots: [], reason: 'invalid_input' }`.

```ts
import { findSlots, travelFromGaps } from '@/utils/booking-availability/booking-availability';

const { slots, reason } = findSlots({
  timeZone: 'Europe/Vienna',
  from: '2097-03-18T00:00:00+01:00', to: '2097-03-25T00:00:00+01:00',   // starts offered in [from, to), at most 62 days
  service,            // buffers, resourcesRequired, …
  duration,           // { minutes, priceMinor, currency }
  resources,          // who can perform the service, in order of preference
  weeklyHours, exceptions,
  busy,               // footprints already taken (buffers included)
  zoneId,             // where this visit happens
  travelMinutes: travelFromGaps(gapRows),
  leadTimeMin: 120, stepMin: 15,
  now: new Date(),
});
```

## What a slot is

- `start` and `end` are the visit itself, as ISO 8601 instants in the business's offset. Buffers are not
  part of it.
- One slot per start time. Its `resourceIds` are the first free resources in the order you passed. To
  let a customer pick a person, call once per person, with `resources: [thatPerson]`.
- Starts sit on wall-clock multiples of `stepMin`, counted from midnight. With a 15-minute step, a
  window opening at 09:10 offers 09:15 first.
- The **footprint** must fit inside one open window: visit plus buffer before and after. A footprint
  never crosses midnight.
- It must not overlap a busy footprint of its resource. Touching is fine.
- It needs `travelMinutes(previous zone, this zone)` minutes after the resource's previous footprint, and
  `travelMinutes(this zone, next zone)` before its next one. `null` means the trip is unknown, and then
  the slot is not offered.
- Its start is at or after `now + leadTimeMin`, and strictly after `now`.
- A service with `resourcesRequired: 2` gets only starts where two resources are free together.
- Daylight saving: a wall-clock time that does not exist in spring is skipped. One that happens twice
  in autumn is offered once, at its first occurrence.

## Inputs, as a database hands them over

Instants may be ISO strings with an offset, Postgres's text form (`2097-03-18 10:00:00+01`) or `Date`
objects. Wall-clock times are `HH:MM`, or `HH:MM:00` as a driver returns a `time` column; `24:00`
closes a window at midnight. Dates are `'YYYY-MM-DD'` strings, never `Date` objects: drivers turn a
`date` column into local or UTC midnight depending on the driver, so read it as text (below). Date
ranges are `[from, to)`, and `null` or a missing `effectiveFrom`/`effectiveTo` means unbounded.

With the `booking-schema` template:

| Input | Read from |
|---|---|
| `weeklyHours` | `booking.resource_weekly_hours`: `resource_id`, `iso_weekday`, `opens`, `closes`, `to_char(lower(effective), 'YYYY-MM-DD')`, `to_char(upper(effective), 'YYYY-MM-DD')` |
| `exceptions` | `booking.resource_hours_exceptions`: `resource_id`, `to_char(lower(on_dates), 'YYYY-MM-DD')`, `to_char(upper(on_dates), 'YYYY-MM-DD')`, `starts`, `ends`, `effect` |
| `busy` | `booking.v_busy`: `resource_id`, `lower(blocked)`, `upper(blocked)`, `zone_id`, for **every** live footprint of these resources, not only those inside the window (see below). A lapsed request hold is already left out |
| `travelMinutes` | `travelFromGaps(rows of booking.v_travel_gaps)`: `from_zone_id`, `to_zone_id`, `gap_minutes` |

**Pass every live footprint, not only the window's.** The travel check looks at each resource's nearest
footprint before and after a slot, however far away it is, exactly as the schema does. A visit three
days earlier in a zone with no travel row still blocks the slot. A query filtered to the window drops
that neighbour, and the calculator would then offer slots the schema refuses. At the least, pass the
rows that overlap the window plus each resource's nearest row before and after it. Passing all of
`v_busy` for the resources is cheap: tens of thousands of rows cost milliseconds.

`travelFromGaps` applies the schema's own rule: a listed trip needs its gap (base buffer + travel), the
same zone without a row needs nothing, and any other trip is unknown. Given every live footprint, the
calculator and the database agree: a slot it offers is one the schema accepts.

## Reasons for an empty answer

| `reason` | Meaning |
|---|---|
| `invalid_input` | Something is malformed (time zone, instant, `HH:MM`, a non-integer minute count, a window over 62 days), or `travelMinutes` threw |
| `outside_window` | Nothing in `[from, to)` is at or after `now + leadTimeMin` |
| `no_resource` | Fewer resources than the service needs |
| `no_hours` | None of the resources has any open hours in the window |
| none | Hours exist, but everything is taken |

`booking-types.ts` is this template's copy of the booking vocabulary (`VOCAB_VERSION = 1`). Other
booking templates ship their own copy. Compare the version numbers when you combine them.
