# booking-schema

A PostgreSQL 16 schema for appointment booking that refuses every conflict by itself: double booking
(buffers included, for every resource of a multi-resource booking), too little travel time between
two visits of one resource, request holds that outlive their deadline, and steps outside the
booking lifecycle. It does not search for free time. A slot calculator does that and reads
`booking.v_busy` and `booking.v_travel_gaps`.

## Install

    psql -v ON_ERROR_STOP=1 -1 -f db/booking-schema/booking-schema.sql

- Always install, and re-run, with `-1` (one transaction), as shown. A re-run replaces each trigger
  (drop, then create); inside one transaction no other session ever sees a table without its laws.
- Re-runnable: a second run changes nothing.
- Creates schema `booking` and, when they are missing, the NOLOGIN roles `app_reader`, `app_writer`
  and `app_admin`. Grant them to your app's login roles. Without CREATEROLE the file stops at the top,
  before it creates anything, and tells you what to do.
- Needs the `btree_gist` extension (part of contrib).

## Using it

- Insert a booking, its contact and its resource links in **one transaction**. A live booking must be
  whole at commit.
- Link resources in `resource_id` order. Two multi-resource bookings that link the same resources in
  opposite orders can deadlock, and Postgres aborts one of them.
- Create and move bookings (anything that links resources) under READ COMMITTED. Under REPEATABLE READ
  or SERIALIZABLE that is refused with `booking L21`, because the travel check needs a fresh snapshot
  per statement. Accepting, declining, cancelling and closing a booking work at any isolation level. If
  your connection pool sets `default_transaction_isolation` to anything else, set it back to
  `read committed` for the transactions that create or move bookings.
- Fill in `booking.zone_travel` before a zone's first booking: `booking L20` refuses a trip with no
  travel row across any time gap, even days apart, so a single visit in a zone with no travel rows
  blocks that resource's bookings in other zones on either side of it.
- A law held by a trigger refuses with SQLSTATE 23514 and a message starting `booking Lnn:`, which
  names the law and the way out. A law held by a constraint refuses with the constraint's own SQLSTATE
  and names the constraint. The two your app should map:
  - 23P01 `no_resource_in_two_live_bookings`: the slot was just taken. Offer another one.
  - 23503 `a_link_carries_its_bookings_footprint`: a write tried to give a resource link its own span
    or liveness. A link follows its booking; change the booking instead.

  The named CHECKs (for example `a_hold_lapses_by_the_visit`) refuse with 23514 and their name.
- From your scheduler, for example daily, call in this order: `booking.expire_lapsed_holds()`,
  `booking.erase_due_notes()`, `booking.erase_due_contacts()`, `booking.prune_manage_links()`.
  Personal data of a live booking is never due. `expire_lapsed_holds()` closes requests whose deadline
  passed; a confirmed booking stays live until your app closes it, so record every past visit as
  `completed` or `no_show`.
- `booking.booking_events` is append-only. A consumer reading by `seq` re-reads a short trailing window
  (e.g. the last 10 seconds), because `seq` is allocation order, not commit order.

## Retention and health data

`note_retention_days` (default 7) and `contact_retention_days` (default 365) are **placeholders**.
Set them with your own legal counsel. A note may contain health information. Asking for explicit
consent is your legal duty; the schema only records which consent wording was accepted, and when.

## Prove it

    psql -v ON_ERROR_STOP=1 -f db/booking-schema/battery.sql

Run it **only on a fresh throwaway database**. It writes invented fixtures, it refuses a database
whose `booking.businesses` has rows, and it exits non-zero if any law fails. It prints one PASS or FAIL
line per test and a summary.

Its grant tests `SET ROLE` to `app_reader` and `app_writer`, so run it as a superuser, or first run
`GRANT app_reader, app_writer TO <you> WITH SET TRUE;`. In PostgreSQL 16 the role that creates a
role gets ADMIN on it, but not SET. The battery checks this before it writes anything and tells you.

## What it leaves to other modules

Payments, deposits, vouchers and reminders reference `booking.bookings(id)` and read
`booking.booking_events`. None of them needs a column here.
