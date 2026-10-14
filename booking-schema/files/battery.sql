-- battery.sql — exercises booking-schema's laws on a throwaway database. Invented data only.
-- Every refusal is matched on its SQLSTATE *and* on the law that raised it: the `booking Lnn:` code
-- for a law held by a trigger, the constraint's name for a law held by a constraint. So a test
-- cannot pass on the wrong law. Fixed instants lie in March 2097, so the battery does not expire.
-- Prints only PASS/FAIL lines and a summary; exits non-zero if any law fails. Every test is a CALL of a
-- procedure, which prints no result, so the battery needs no output redirection on any platform.
\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;

-- ───────── guard: a throwaway database only
DO $$
BEGIN
  IF to_regclass('booking.businesses') IS NULL THEN
    RAISE EXCEPTION 'battery: install booking-schema.sql first';
  END IF;
  -- the grant tests SET ROLE to app_reader and app_writer: check it here, before anything is written
  IF NOT (pg_has_role(current_user, 'app_reader', 'SET') AND pg_has_role(current_user, 'app_writer', 'SET')) THEN
    RAISE EXCEPTION 'battery: % cannot SET ROLE to app_reader and app_writer, which the grant tests need — run  GRANT app_reader, app_writer TO % WITH SET TRUE;  (or run the battery as a superuser)', current_user, quote_ident(current_user);
  END IF;
  IF EXISTS (SELECT 1 FROM booking.businesses) THEN
    RAISE EXCEPTION 'battery: booking.businesses already has rows — run the battery only on a fresh throwaway database, never on one with real data';
  END IF;
  IF to_regnamespace('t') IS NOT NULL THEN
    RAISE EXCEPTION 'battery: schema t already exists — use a fresh throwaway database';
  END IF;
END $$;

-- ───────── harness
CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO PUBLIC;
CREATE TABLE t.results (n serial PRIMARY KEY, label text NOT NULL, pass boolean NOT NULL, detail text);
CREATE TABLE t.ids (label text PRIMARY KEY, id uuid NOT NULL);
GRANT ALL ON t.results, t.ids TO PUBLIC;
GRANT USAGE ON SEQUENCE t.results_n_seq TO PUBLIC;

CREATE FUNCTION t.keep(p_label text, p_id uuid) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO t.ids VALUES (p_label, p_id) ON CONFLICT (label) DO UPDATE SET id = EXCLUDED.id RETURNING id $$;
CREATE FUNCTION t.id(p_label text) RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT id FROM t.ids WHERE label = p_label $$;

CREATE PROCEDURE t.ok(p_label text, p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    INSERT INTO t.results (label, pass, detail) VALUES (p_label, true, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t.results (label, pass, detail) VALUES (p_label, false, 'expected success, got ' || SQLSTATE || ': ' || SQLERRM);
  END;
END $$;

CREATE PROCEDURE t.refused(p_label text, p_sql text, p_state text, p_msg text) LANGUAGE plpgsql AS $$
DECLARE accepted boolean := false;
BEGIN
  BEGIN
    EXECUTE p_sql;
    accepted := true;
    RAISE EXCEPTION 'battery: accepted' USING ERRCODE = 'P0099';
  EXCEPTION WHEN OTHERS THEN
    IF accepted THEN
      INSERT INTO t.results (label, pass, detail) VALUES (p_label, false, 'expected ' || p_state || ' ' || p_msg || ' — but it was ACCEPTED');
    ELSIF SQLSTATE = p_state AND SQLERRM LIKE p_msg THEN
      INSERT INTO t.results (label, pass, detail) VALUES (p_label, true, SQLSTATE || ': ' || SQLERRM);
    ELSE
      INSERT INTO t.results (label, pass, detail) VALUES (p_label, false, 'expected ' || p_state || ' ' || p_msg || ', got ' || SQLSTATE || ': ' || SQLERRM);
    END IF;
  END;
END $$;

CREATE PROCEDURE t.check(p_label text, p_sql text) LANGUAGE plpgsql AS $$
DECLARE v boolean;
BEGIN
  BEGIN
    EXECUTE p_sql INTO v;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t.results (label, pass, detail) VALUES (p_label, false, 'check raised ' || SQLSTATE || ': ' || SQLERRM);
    RETURN;
  END;
  INSERT INTO t.results (label, pass, detail) VALUES (p_label, coalesce(v, false), CASE WHEN v THEN 'holds' ELSE 'does NOT hold' END);
END $$;

-- one booking with its contact and its resources, made whole before returning
CREATE FUNCTION t.book(p_service text, p_resources text[], p_from timestamptz, p_minutes int,
                       p_channel text DEFAULT 'customer', p_status text DEFAULT NULL, p_zone text DEFAULT NULL,
                       p_hold_until timestamptz DEFAULT NULL, p_address text DEFAULT NULL,
                       p_contact boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE bid uuid; biz uuid; svc uuid; z uuid; r text;
BEGIN
  SELECT s.id, s.business_id INTO svc, biz FROM booking.services s WHERE s.name = p_service;
  IF p_zone IS NOT NULL THEN
    SELECT id INTO z FROM booking.zones WHERE business_id = biz AND name = p_zone;
  END IF;
  INSERT INTO booking.bookings (business_id, service_id, zone_id, channel, status, during, hold_until)
  VALUES (biz, svc, z, p_channel::booking.booking_channel, p_status::booking.booking_status,
          tstzrange(p_from, p_from + make_interval(mins => p_minutes), '[)'), p_hold_until)
  RETURNING id INTO bid;
  IF p_contact THEN
    INSERT INTO booking.booking_contacts (booking_id, full_name, email, visit_address)
    VALUES (bid, 'Alex Example', 'alex@example.com', p_address);
  END IF;
  FOREACH r IN ARRAY p_resources LOOP
    INSERT INTO booking.booking_resources (booking_id, resource_id)
    SELECT bid, id FROM booking.resources WHERE business_id = biz AND display_name = r;
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;
  RETURN bid;
END $$;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA t TO PUBLIC;

-- ───────── fixtures (invented)
INSERT INTO booking.businesses (name, time_zone, currency, travel_base_minutes, note_retention_days, contact_retention_days)
VALUES ('Lindenhof Wellness', 'Europe/Vienna', 'EUR', 10, 0, 30);

INSERT INTO booking.zones (business_id, name, is_premises)
SELECT b.id, z.name, z.is_premises FROM booking.businesses b,
  (VALUES ('Studio', true), ('North', false), ('South', false), ('East', false)) z(name, is_premises);

INSERT INTO booking.zone_travel (business_id, from_zone_id, to_zone_id, minutes)
SELECT f.business_id, f.id, t2.id, v.minutes
  FROM (VALUES ('Studio','North',20), ('North','Studio',20), ('Studio','South',25), ('South','Studio',25),
               ('North','South',40), ('South','North',45)) v(f, t, minutes)
  JOIN booking.zones f  ON f.name = v.f
  JOIN booking.zones t2 ON t2.name = v.t;

INSERT INTO booking.services (business_id, name, confirmation, hold_minutes, location, buffer_before_minutes, buffer_after_minutes,
                              resources_required, cancel_free_hours, late_cancel_fee_bp)
SELECT b.id, s.* FROM booking.businesses b, (VALUES
  ('Deep tissue',  'instant'::booking.confirmation_mode, NULL::int, 'premises'::booking.service_location,      10, 15, 1::smallint, 24, 5000),
  ('Couples',      'instant',                            NULL,      'premises',                                  0,  0, 2,           24, 0),
  ('Home visit',   'request',                            120,       'customer_site',                             0,  0, 1,           48, 2500),
  ('Mobile quick', 'instant',                            NULL,      'customer_site',                             0,  0, 1,           24, 0)
) s;

INSERT INTO booking.service_durations (service_id, minutes, price_minor)
SELECT s.id, d.minutes, d.price FROM booking.services s
  JOIN (VALUES ('Deep tissue', 60, 8000), ('Deep tissue', 90, 11000), ('Couples', 60, 15000),
               ('Home visit', 60, 12000), ('Mobile quick', 40, 6000)) d(service, minutes, price) ON d.service = s.name;

INSERT INTO booking.resources (business_id, display_name, retired_at)
SELECT b.id, r.name, r.retired FROM booking.businesses b,
  (VALUES ('Mara', NULL::timestamptz), ('Jonas', NULL), ('Ilka', NULL), ('Rolf', now()), ('Noor', NULL)) r(name, retired);

INSERT INTO booking.resource_services (business_id, resource_id, service_id)
SELECT r.business_id, r.id, s.id FROM (VALUES
  ('Mara','Deep tissue'), ('Mara','Couples'), ('Mara','Home visit'),
  ('Jonas','Deep tissue'), ('Jonas','Couples'),
  ('Ilka','Couples'), ('Ilka','Home visit'), ('Ilka','Mobile quick'),
  ('Rolf','Deep tissue'), ('Noor','Home visit')) v(r, s)
  JOIN booking.resources r ON r.display_name = v.r
  JOIN booking.services  s ON s.name = v.s;

INSERT INTO booking.note_consent_texts (business_id, locale, body)
SELECT id, 'en', 'I agree that the studio stores what I write here, including information about my health, to prepare my appointment. It is deleted after the appointment.'
  FROM booking.businesses;

-- ───────── configuration laws
CALL t.ok('W1 weekly hours: a split shift is two windows',
  $$INSERT INTO booking.resource_weekly_hours (resource_id, iso_weekday, opens, closes)
    SELECT id, 1, o, c FROM booking.resources, (VALUES ('09:00'::time,'13:00'::time), ('14:00','18:00')) w(o,c) WHERE display_name = 'Mara'$$);
CALL t.refused('W2 weekly hours: overlapping windows are refused',
  $$INSERT INTO booking.resource_weekly_hours (resource_id, iso_weekday, opens, closes) SELECT id, 1, '12:00', '15:00' FROM booking.resources WHERE display_name = 'Mara'$$,
  '23P01', '%weekly_windows_never_overlap%');
CALL t.refused('Z1 a business time zone is an IANA name, not an abbreviation',
  $$INSERT INTO booking.businesses (name, time_zone, currency) VALUES ('Test', 'EST', 'EUR')$$,
  '23514', '%time_zone_is_an_iana_name%');

-- ───────── LAW A — no resource in two live bookings, buffers included (L1)
CALL t.ok('A1 Mara: deep tissue 10:00–11:00 (footprint 09:50–11:15)',
  $$SELECT t.keep('mara_10', t.book('Deep tissue', '{Mara}', '2097-03-15 10:00+01', 60))$$);
CALL t.refused('A2 Mara: an overlapping visit 10:30 is refused',
  $$SELECT t.book('Deep tissue', '{Mara}', '2097-03-15 10:30+01', 60)$$, '23P01', '%no_resource_in_two_live_bookings%');
CALL t.refused('A3 Mara: 11:20 is refused — the visits do not touch, the buffers do',
  $$SELECT t.book('Deep tissue', '{Mara}', '2097-03-15 11:20+01', 60)$$, '23P01', '%no_resource_in_two_live_bookings%');
CALL t.ok('A4 Mara: 11:25 is accepted — footprints [09:50,11:15) and [11:15,12:40) only touch',
  $$SELECT t.keep('mara_1125', t.book('Deep tissue', '{Mara}', '2097-03-15 11:25+01', 60))$$);
CALL t.ok('A5 Jonas: 10:00 in parallel with Mara (another resource)',
  $$SELECT t.keep('jonas_10', t.book('Deep tissue', '{Jonas}', '2097-03-15 10:00+01', 60))$$);
CALL t.ok('A6 couples massage 14:00 on Mara + Jonas',
  $$SELECT t.keep('couple_14', t.book('Couples', '{Mara,Jonas}', '2097-03-15 14:00+01', 60))$$);
CALL t.refused('A7 Jonas alone at 14:30 is refused — the second resource of a couples booking is guarded too',
  $$SELECT t.book('Deep tissue', '{Jonas}', '2097-03-15 14:30+01', 60)$$, '23P01', '%no_resource_in_two_live_bookings%');
CALL t.refused('A8 couples 14:30 on Ilka + Mara is refused on Mara',
  $$SELECT t.book('Couples', '{Ilka,Mara}', '2097-03-15 14:30+01', 60)$$, '23P01', '%no_resource_in_two_live_bookings%');
CALL t.check('A9 … and Ilka was not booked either (the refusal is atomic)',
  $$SELECT NOT EXISTS (SELECT 1 FROM booking.booking_resources br JOIN booking.resources r ON r.id = br.resource_id
                       WHERE r.display_name = 'Ilka' AND br.blocked && tstzrange('2097-03-15 14:30+01','2097-03-15 15:30+01'))$$);
CALL t.ok('A10 the customer cancels Mara 10:00',
  $$UPDATE booking.bookings SET status = 'cancelled', cancelled_by = 'customer' WHERE id = t.id('mara_10')$$);
CALL t.check('A11 … free of charge (decades ahead) and closed',
  $$SELECT cancellation_fee_minor = 0 AND closed_at IS NOT NULL AND NOT is_live FROM booking.bookings WHERE id = t.id('mara_10')$$);
CALL t.ok('A12 the freed slot is bookable again: Mara 10:00',
  $$SELECT t.keep('mara_10b', t.book('Deep tissue', '{Mara}', '2097-03-15 10:00+01', 60))$$);
CALL t.refused('A13 moving Jonas 10:00 to 14:15 is refused (the cascade re-checks the footprint)',
  $$UPDATE booking.bookings SET during = tstzrange('2097-03-15 14:15+01','2097-03-15 15:15+01','[)') WHERE id = t.id('jonas_10')$$,
  '23P01', '%no_resource_in_two_live_bookings%');
CALL t.refused('A14 a link cannot carry a footprint of its own',
  $$UPDATE booking.booking_resources SET blocked = tstzrange('2097-01-01 00:00+00','2097-01-01 01:00+00') WHERE booking_id = t.id('mara_1125')$$,
  '23503', '%a_link_carries_its_bookings_footprint%');
CALL t.refused('A15 a link of a live booking cannot be marked dead on its own',
  $$UPDATE booking.booking_resources SET is_live = false WHERE booking_id = t.id('mara_1125')$$,
  '23503', '%a_link_carries_its_bookings_footprint%');

-- ───────── LAW B — the request-hold lifecycle (L2–L8, L11)
CALL t.refused('B1 a customer cannot book a request-mode service as confirmed',
  $$SELECT t.book('Home visit', '{Mara}', '2097-03-16 10:00+01', 60, 'customer', 'confirmed', 'North', NULL, 'Ring 3')$$,
  '23514', 'booking L3: service % confirms by request%');
CALL t.ok('B2 a customer requests a home visit: it enters as held',
  $$SELECT t.keep('hold_a', t.book('Home visit', '{Mara}', '2097-03-16 10:00+01', 60, 'customer', NULL, 'North', NULL, 'Ring 3'))$$);
CALL t.check('B3 … held until created_at + 120 min, not confirmed',
  $$SELECT status = 'held' AND hold_until = created_at + interval '120 minutes' AND confirmed_at IS NULL FROM booking.bookings WHERE id = t.id('hold_a')$$);
CALL t.refused('B4 a live hold blocks its resource',
  $$SELECT t.book('Deep tissue', '{Mara}', '2097-03-16 10:30+01', 60)$$, '23P01', '%no_resource_in_two_live_bookings%');
CALL t.refused('B5 a hold cannot outlast the service''s window',
  $$SELECT t.book('Home visit', '{Ilka}', '2097-03-16 12:00+01', 60, 'customer', NULL, 'North', now() + interval '3 hours', 'Ring 4')$$,
  '23514', 'booking L4: a hold on service %');
CALL t.ok('B6 staff accept the hold before its deadline',
  $$UPDATE booking.bookings SET status = 'confirmed' WHERE id = t.id('hold_a')$$);
CALL t.check('B7 … confirmed_at is stamped, the deadline is kept as history',
  $$SELECT status = 'confirmed' AND confirmed_at IS NOT NULL AND hold_until IS NOT NULL FROM booking.bookings WHERE id = t.id('hold_a')$$);
CALL t.ok('B8 a hold that lapses in one second (Mara, 03-17 10:00)',
  $$SELECT t.keep('hold_b', t.book('Home visit', '{Mara}', '2097-03-17 10:00+01', 60, 'customer', NULL, 'North', now() + interval '1 second', 'Ring 5'))$$);
CALL t.ok('B9 a hold that stays open (Ilka, 03-17 12:00)',
  $$SELECT t.keep('hold_c', t.book('Home visit', '{Ilka}', '2097-03-17 12:00+01', 60, 'customer', NULL, 'South', NULL, 'Ring 6'))$$);
CALL t.ok('B9a a hold nobody will compete for (Noor, 03-23 10:00), lapsing in one second',
  $$SELECT t.keep('hold_d', t.book('Home visit', '{Noor}', '2097-03-23 10:00+01', 60, 'customer', NULL, 'North', now() + interval '1 second', 'Ring 17'))$$);
CALL t.ok('B9b … with a consented note',
  $$INSERT INTO booking.booking_notes (booking_id, business_id, body, consent_text_id)
    SELECT b.id, b.business_id, 'Bad knee, no stairs please.', (SELECT id FROM booking.note_consent_texts LIMIT 1)
      FROM booking.bookings b WHERE b.id = t.id('hold_d')$$);
CALL t.refused('B10 a hold cannot expire before its deadline',
  $$UPDATE booking.bookings SET status = 'expired' WHERE id = t.id('hold_c')$$, '23514', 'booking L8:%');
CALL t.refused('B11 held → completed is not a step of the lifecycle',
  $$UPDATE booking.bookings SET status = 'completed' WHERE id = t.id('hold_c')$$, '23514', 'booking L5:%');
CALL t.refused('B12 a hold deadline cannot be extended',
  $$UPDATE booking.bookings SET hold_until = hold_until + interval '1 day' WHERE id = t.id('hold_c')$$, '23514', 'booking L11:%');
DO $$ BEGIN PERFORM pg_sleep(1.5); END $$;
CALL t.refused('B13 staff cannot accept a lapsed hold',
  $$UPDATE booking.bookings SET status = 'confirmed' WHERE id = t.id('hold_b')$$, '23514', 'booking L7:%');
CALL t.ok('B14 a competitor books the lapsed hold''s slot — no sweeper ran',
  $$SELECT t.keep('competitor', t.book('Deep tissue', '{Mara}', '2097-03-17 10:00+01', 60))$$);
CALL t.check('B15 … the lapsed hold is now expired and closed',
  $$SELECT status = 'expired' AND closed_at IS NOT NULL FROM booking.bookings WHERE id = t.id('hold_b')$$);
CALL t.refused('B16 an expired hold never reopens',
  $$UPDATE booking.bookings SET status = 'confirmed' WHERE id = t.id('hold_b')$$, '23514', 'booking L6:%');
CALL t.ok('B17 staff decline the open hold',
  $$UPDATE booking.bookings SET status = 'declined' WHERE id = t.id('hold_c')$$);
CALL t.check('B18 … declined, closed, and no longer busy',
  $$SELECT b.status = 'declined' AND b.closed_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM booking.v_busy v WHERE v.booking_id = b.id)
      FROM booking.bookings b WHERE b.id = t.id('hold_c')$$);
CALL t.check('B19 the event log tells hold_a''s story: created held, then confirmed',
  $$SELECT array_agg(kind::text || ':' || status_after::text ORDER BY seq) = ARRAY['created:held', 'status_changed:confirmed']
      FROM booking.booking_events WHERE booking_id = t.id('hold_a')$$);
CALL t.ok('B20 staff may enter a request-mode booking as confirmed',
  $$SELECT t.book('Home visit', '{Ilka}', '2097-03-18 10:00+01', 60, 'staff', 'confirmed', 'South', NULL, 'Ring 7')$$);
CALL t.refused('B21 an instant service is never held',
  $$SELECT t.book('Deep tissue', '{Jonas}', '2097-03-18 10:00+01', 60, 'customer', 'held')$$, '23514', 'booking L3: service % confirms instantly%');
CALL t.refused('B22 only a held booking carries a hold deadline',
  $$SELECT t.book('Deep tissue', '{Jonas}', '2097-03-18 12:00+01', 60, 'customer', NULL, NULL, now() + interval '1 hour')$$,
  '23514', 'booking L4: only a held booking carries a hold deadline%');
CALL t.refused('B23 the caller never writes a lifecycle stamp',
  $$INSERT INTO booking.bookings (business_id, service_id, channel, during, confirmed_at)
    SELECT business_id, id, 'staff', tstzrange('2097-03-18 14:00+01','2097-03-18 15:00+01','[)'), '2097-01-01 00:00+00'
      FROM booking.services WHERE name = 'Deep tissue'$$,
  '23514', 'booking L11: confirmed_at, closed_at, cancelled_by and cancellation_fee_minor are written by the lifecycle%');

-- ───────── LAW C — travel between consecutive bookings of one resource (L19–L21)
CALL t.ok('C1 Ilka: mobile visit in North 16:00–16:40',
  $$SELECT t.keep('c1', t.book('Mobile quick', '{Ilka}', '2097-03-19 16:00+01', 40, 'customer', NULL, 'North', NULL, 'Ring 8'))$$);
CALL t.refused('C2 Ilka: South at 17:00 is refused — needs 10 + 40 min, has 20',
  $$SELECT t.book('Mobile quick', '{Ilka}', '2097-03-19 17:00+01', 40, 'customer', NULL, 'South', NULL, 'Ring 9')$$, '23514', 'booking L19:%');
CALL t.ok('C3 Ilka: South at 17:30 — exactly 50 min',
  $$SELECT t.keep('c3', t.book('Mobile quick', '{Ilka}', '2097-03-19 17:30+01', 40, 'customer', NULL, 'South', NULL, 'Ring 9'))$$);
CALL t.refused('C4 Ilka: East at 19:00 is refused — no travel time South→East is known',
  $$SELECT t.book('Mobile quick', '{Ilka}', '2097-03-19 19:00+01', 40, 'customer', NULL, 'East', NULL, 'Ring 10')$$, '23514', 'booking L20:%');
CALL t.refused('C5 Ilka: South 15:00–15:40 is refused by its SUCCESSOR in North (needs 55, has 20)',
  $$SELECT t.book('Mobile quick', '{Ilka}', '2097-03-19 15:00+01', 40, 'customer', NULL, 'South', NULL, 'Ring 10')$$, '23514', 'booking L19:%');
CALL t.ok('C6 Ilka: North 15:10–15:50 — same zone, no intra-zone row, no gap needed',
  $$SELECT t.book('Mobile quick', '{Ilka}', '2097-03-19 15:10+01', 40, 'customer', NULL, 'North', NULL, 'Ring 11')$$);
CALL t.refused('C7 moving C3 to 17:10 is refused (travel is re-checked on a move)',
  $$UPDATE booking.bookings SET during = tstzrange('2097-03-19 17:10+01','2097-03-19 17:50+01','[)') WHERE id = t.id('c3')$$, '23514', 'booking L19:%');
BEGIN ISOLATION LEVEL REPEATABLE READ;
CALL t.refused('C9 linking under REPEATABLE READ is refused, not silently unsafe',
  $$SELECT t.book('Mobile quick', '{Ilka}', '2097-03-21 10:00+01', 40, 'customer', NULL, 'North', NULL, 'Ring 12')$$, '23514', 'booking L21:%');
COMMIT;

-- ───────── whole booking at commit, resource fit (L17, L18)
CALL t.refused('D1 a couples booking on one resource is refused at commit',
  $$SELECT t.book('Couples', '{Mara}', '2097-03-22 15:00+01', 60)$$, '23514', 'booking L18: booking % stands on 1 resource(s)%');
CALL t.refused('D2 a visit at the customer''s site needs an address',
  $$SELECT t.book('Home visit', '{Mara}', '2097-03-22 08:00+01', 60, 'customer', NULL, 'North', NULL, NULL)$$, '23514', 'booking L18: booking % is a visit at the customer%');
CALL t.refused('D3 a resource that does not perform the service is refused',
  $$SELECT t.book('Deep tissue', '{Ilka}', '2097-03-22 10:00+01', 60)$$, '23514', 'booking L17: resource % does not perform%');
CALL t.refused('D4 a retired resource is refused',
  $$SELECT t.book('Deep tissue', '{Rolf}', '2097-03-22 10:00+01', 60)$$, '23514', 'booking L17: resource % was retired%');
CALL t.refused('D5 a duration the service does not offer is refused',
  $$SELECT t.book('Deep tissue', '{Jonas}', '2097-03-22 12:00+01', 45)$$, '23514', 'booking L13: service % offers no visit%');
CALL t.refused('D6 a live booking without its contact is refused at commit',
  $$SELECT t.book('Deep tissue', '{Jonas}', '2097-03-22 16:00+01', 60, 'customer', NULL, NULL, NULL, NULL, false)$$,
  '23514', 'booking L18: live booking % has no contact%');

-- ───────── grants: the booking path runs on app_writer's grants alone
SET ROLE app_writer;
CALL t.ok('E1 app_writer books (links, lazy release, travel, events) on its grants alone',
  $$SELECT t.keep('e1', t.book('Deep tissue', '{Jonas}', '2097-03-22 10:00+01', 60))$$);
CALL t.refused('E2 app_writer cannot forge an event',
  $$INSERT INTO booking.booking_events (booking_id, kind, status_after, during_after) SELECT id, 'created', status, during FROM booking.bookings LIMIT 1$$,
  '42501', '%permission denied%');
CALL t.ok('E3 app_writer cancels; cascade and event log run under its grants',
  $$UPDATE booking.bookings SET status = 'cancelled', cancelled_by = 'customer' WHERE id = t.id('e1')$$);
RESET ROLE;
SET ROLE app_reader;
CALL t.refused('E4 app_reader cannot read contacts', $$SELECT count(*) FROM booking.booking_contacts$$, '42501', '%permission denied%');
CALL t.refused('E5 app_reader cannot read notes', $$SELECT count(*) FROM booking.booking_notes$$, '42501', '%permission denied%');
CALL t.ok('E6 app_reader reads v_busy', $$SELECT count(*) FROM booking.v_busy$$);
RESET ROLE;

-- ───────── notes, consent, retention, fees, records (L22–L25)
CALL t.ok('F1 a note is written with its consent',
  $$INSERT INTO booking.booking_notes (booking_id, business_id, body, consent_text_id)
    SELECT b.id, b.business_id, 'Sore left shoulder since a fall.', (SELECT id FROM booking.note_consent_texts LIMIT 1)
      FROM booking.bookings b WHERE b.id IN (t.id('jonas_10'), t.id('mara_1125'))$$);
CALL t.refused('F2 a note without consent cannot exist',
  $$INSERT INTO booking.booking_notes (booking_id, business_id, body) SELECT id, business_id, 'x' FROM booking.bookings WHERE id = t.id('couple_14')$$,
  '23502', '%consent_text_id%');
CALL t.refused('F3 a note is never edited',
  $$UPDATE booking.booking_notes SET body = 'changed' WHERE booking_id = t.id('jonas_10')$$, '23514', 'booking L25:%');
CALL t.ok('F4 the business cancels Jonas 10:00',
  $$UPDATE booking.bookings SET status = 'cancelled', cancelled_by = 'business' WHERE id = t.id('jonas_10')$$);
CALL t.check('F5 erase_due_notes erases exactly one note: the closed booking''s (retention 0 days)',
  $$SELECT booking.erase_due_notes() = 1$$);
CALL t.check('F5a … the closed booking''s note is gone, the live booking''s note stays',
  $$SELECT NOT EXISTS (SELECT 1 FROM booking.booking_notes WHERE booking_id = t.id('jonas_10'))
       AND EXISTS (SELECT 1 FROM booking.booking_notes WHERE booking_id = t.id('mara_1125'))$$);
CALL t.check('F6 … and the erasure is an event',
  $$SELECT EXISTS (SELECT 1 FROM booking.booking_events WHERE booking_id = t.id('jonas_10') AND kind = 'note_erased')$$);
CALL t.refused('F7 published consent wording is evidence',
  $$UPDATE booking.note_consent_texts SET body = 'changed'$$, '23514', 'booking L24:%');
CALL t.refused('F8 a booking is never deleted',
  $$DELETE FROM booking.bookings WHERE id = t.id('jonas_10')$$, '23514', 'booking L22:%');
CALL t.refused('F9 the event log is append-only',
  $$UPDATE booking.booking_events SET at = now()$$, '23514', 'booking L23:%');
CALL t.refused('F9a … no event is deleted while its booking exists',
  $$DELETE FROM booking.booking_events WHERE booking_id = t.id('jonas_10')$$, '23514', 'booking L23:%');
CALL t.ok('F10 a booking two hours from now',
  $$SELECT t.keep('soon', t.book('Deep tissue', '{Jonas}', date_trunc('minute', now()) + interval '2 hours', 60))$$);
CALL t.ok('F11 the customer cancels it late',
  $$UPDATE booking.bookings SET status = 'cancelled', cancelled_by = 'customer' WHERE id = t.id('soon')$$);
CALL t.check('F12 … and owes 50 % of 80.00 = 40.00',
  $$SELECT cancellation_fee_minor = 4000 FROM booking.bookings WHERE id = t.id('soon')$$);
CALL t.refused('F13 a manage link stores a digest, never a token',
  $$INSERT INTO booking.manage_links (token_sha256, booking_id, expires_at) VALUES (convert_to('my-clear-token', 'UTF8'), t.id('mara_1125'), now() + interval '30 days')$$,
  '23514', '%stores_a_sha256_digest_not_a_token%');
CALL t.ok('F14 … its SHA-256 is accepted',
  $$INSERT INTO booking.manage_links (token_sha256, booking_id, expires_at) VALUES (sha256(convert_to('my-clear-token', 'UTF8')), t.id('mara_1125'), now() + interval '30 days')$$);

-- ───────── lifecycle edges, service and zone fit, links (L9, L10, L12, L14, L15, L16, L26), time zone
CALL t.refused('G1 a visit cannot be completed before it begins',
  $$UPDATE booking.bookings SET status = 'completed' WHERE id = t.id('mara_1125')$$, '23514', 'booking L9:%');
CALL t.ok('G2 staff record a visit that began 30 minutes ago',
  $$SELECT t.keep('begun', t.book('Deep tissue', '{Jonas}', date_trunc('minute', now()) - interval '30 minutes', 60, 'staff'))$$);
CALL t.refused('G3 a visit that has begun is not cancelled',
  $$UPDATE booking.bookings SET status = 'cancelled', cancelled_by = 'customer' WHERE id = t.id('begun')$$, '23514', 'booking L10:%');
CALL t.ok('G4 … it is completed',
  $$UPDATE booking.bookings SET status = 'completed' WHERE id = t.id('begun')$$);
CALL t.refused('G5 a move and a status change are two steps',
  $$UPDATE booking.bookings SET during = tstzrange('2097-04-01 11:25+02','2097-04-01 12:25+02','[)'), status = 'cancelled', cancelled_by = 'customer' WHERE id = t.id('mara_1125')$$,
  '23514', 'booking L12: move booking % or change its status%');
CALL t.refused('G6 a move keeps the visit''s length',
  $$UPDATE booking.bookings SET during = tstzrange('2097-04-01 11:25+02','2097-04-01 12:55+02','[)') WHERE id = t.id('mara_1125')$$,
  '23514', 'booking L12: a move keeps the visit%');
CALL t.ok('G7a a new service with a duration, performed by Mara',
  $$WITH s AS (INSERT INTO booking.services (business_id, name, confirmation, hold_minutes, location, buffer_before_minutes, buffer_after_minutes,
                                             resources_required, cancel_free_hours, late_cancel_fee_bp)
               SELECT id, 'Old ritual', 'instant', NULL, 'premises', 0, 0, 1, 24, 0 FROM booking.businesses RETURNING id, business_id),
         d AS (INSERT INTO booking.service_durations (service_id, minutes, price_minor) SELECT id, 60, 5000 FROM s)
    INSERT INTO booking.resource_services (business_id, resource_id, service_id)
    SELECT s.business_id, r.id, s.id FROM s JOIN booking.resources r ON r.business_id = s.business_id AND r.display_name = 'Mara'$$);
CALL t.ok('G7b … is retired',
  $$UPDATE booking.services SET retired_at = now() WHERE name = 'Old ritual'$$);
CALL t.refused('G7c a retired service is not booked',
  $$SELECT t.book('Old ritual', '{Mara}', '2097-03-24 10:00+01', 60)$$, '23514', 'booking L14: service % was retired%');
CALL t.refused('G8 a customer books only the future',
  $$SELECT t.book('Deep tissue', '{Mara}', date_trunc('minute', now()) - interval '3 hours', 60)$$, '23514', 'booking L15:%');
CALL t.refused('G9 a visit at the customer''s site names its zone',
  $$SELECT t.book('Home visit', '{Ilka}', '2097-03-25 10:00+01', 60, 'customer', NULL, NULL, NULL, 'Ring 15')$$,
  '23514', 'booking L16: service % is visited at the customer%');
CALL t.refused('G10 a premises booking stays in the premises zone',
  $$UPDATE booking.bookings SET zone_id = (SELECT id FROM booking.zones WHERE name = 'North') WHERE id = t.id('mara_1125')$$,
  '23514', 'booking L16: booking % happens at the premises%');
CALL t.refused('G11 a closed booking takes no new resource',
  $$INSERT INTO booking.booking_resources (booking_id, resource_id) SELECT t.id('mara_10'), id FROM booking.resources WHERE display_name = 'Jonas'$$,
  '23514', 'booking L26: booking % is closed (%)%');
CALL t.refused('G12 a link is never re-pointed',
  $$UPDATE booking.booking_resources SET resource_id = (SELECT id FROM booking.resources WHERE display_name = 'Jonas') WHERE booking_id = t.id('mara_1125')$$,
  '23514', 'booking L26: a link is never re-pointed%');
CALL t.refused('G13 a closed booking''s links are history',
  $$DELETE FROM booking.booking_resources WHERE booking_id = t.id('mara_10')$$,
  '23514', 'booking L26: booking % is closed — its resources are history%');
CALL t.ok('G14a the business moves to another time zone',
  $$UPDATE booking.businesses SET time_zone = 'America/New_York'$$);
CALL t.check('G14b … every booked instant stays where it was',
  $$SELECT during = tstzrange('2097-03-15 11:25+01','2097-03-15 12:25+01','[)') FROM booking.bookings WHERE id = t.id('mara_1125')$$);

-- ───────── the scheduler: lapsed holds, retention, manage links; retired consent wording (L2, L24)
CALL t.check('H1 a lapsed hold nobody competed for is still held and live — not yet in v_retention',
  $$SELECT b.status = 'held' AND b.is_live AND b.hold_until <= now()
       AND NOT EXISTS (SELECT 1 FROM booking.v_retention r WHERE r.booking_id = b.id)
      FROM booking.bookings b WHERE b.id = t.id('hold_d')$$);
SET ROLE app_writer;
CALL t.check('H2 app_writer runs expire_lapsed_holds(): it expires exactly that one hold',
  $$SELECT booking.expire_lapsed_holds() = 1$$);
RESET ROLE;
CALL t.check('H3 … expired and closed, with the story the lazy path writes (as hold_b''s)',
  $$SELECT b.status = 'expired' AND b.closed_at IS NOT NULL AND NOT b.is_live
       AND (SELECT array_agg(kind::text || ':' || status_after::text ORDER BY seq) FROM booking.booking_events WHERE booking_id = b.id)
           = ARRAY['created:held', 'status_changed:expired']
       AND (SELECT array_agg(kind::text || ':' || status_after::text ORDER BY seq) FROM booking.booking_events WHERE booking_id = t.id('hold_b'))
           = ARRAY['created:held', 'status_changed:expired']
      FROM booking.bookings b WHERE b.id = t.id('hold_d')$$);
CALL t.check('H4 the expired hold''s note is now due: erase_due_notes() erases it (note retention 0 days)',
  $$SELECT booking.erase_due_notes() = 1$$);
CALL t.check('H4a … it is gone, and its erasure is an event',
  $$SELECT NOT EXISTS (SELECT 1 FROM booking.booking_notes WHERE booking_id = t.id('hold_d'))
       AND EXISTS (SELECT 1 FROM booking.booking_events WHERE booking_id = t.id('hold_d') AND kind = 'note_erased')$$);
CALL t.ok('H5 a fresh hold (Noor, 03-23 14:00)',
  $$SELECT t.keep('hold_e', t.book('Home visit', '{Noor}', '2097-03-23 14:00+01', 60, 'customer', NULL, 'North', NULL, 'Ring 18'))$$);
CALL t.check('H5a … a second sweep expires nothing, the open hold stays held',
  $$SELECT booking.expire_lapsed_holds() = 0 AND (SELECT status = 'held' FROM booking.bookings WHERE id = t.id('hold_e'))$$);
CALL t.check('H6 no contact is due yet (contact retention 30 days)',
  $$SELECT booking.erase_due_contacts() = 0$$);
CALL t.ok('H7 the business shortens contact retention to 0 days',
  $$UPDATE booking.businesses SET contact_retention_days = 0$$);
CALL t.check('H8 erase_due_contacts() erases the contact of every closed booking but G2''s (its visit ends in 30 min)',
  $$WITH before AS MATERIALIZED (
       SELECT count(*) AS closed FROM booking.booking_contacts c JOIN booking.bookings b ON b.id = c.booking_id
        WHERE NOT b.is_live AND b.id <> t.id('begun')),
     erased AS MATERIALIZED (SELECT booking.erase_due_contacts() AS n FROM before)
     SELECT erased.n = before.closed AND before.closed > 0 FROM before, erased$$);
CALL t.check('H8a … only that visit''s contact stays among the closed bookings, and every live booking keeps its own',
  $$SELECT ARRAY(SELECT b.id FROM booking.booking_contacts c JOIN booking.bookings b ON b.id = c.booking_id WHERE NOT b.is_live) = ARRAY[t.id('begun')]
       AND NOT EXISTS (SELECT 1 FROM booking.bookings b WHERE b.is_live
                         AND NOT EXISTS (SELECT 1 FROM booking.booking_contacts c WHERE c.booking_id = b.id))$$);
CALL t.check('H9 … each erasure is a contact_erased event that states the booking''s status',
  $$SELECT EXISTS (SELECT 1 FROM booking.booking_events WHERE booking_id = t.id('jonas_10') AND kind = 'contact_erased' AND status_after = 'cancelled')
       AND (SELECT count(*) FROM booking.booking_events WHERE kind = 'contact_erased') = (SELECT count(*) - 1 FROM booking.bookings WHERE NOT is_live)$$);
CALL t.ok('H10 a manage link that expired yesterday',
  $$INSERT INTO booking.manage_links (token_sha256, booking_id, issued_at, expires_at)
    VALUES (sha256(convert_to('old-token', 'UTF8')), t.id('mara_1125'), now() - interval '31 days', now() - interval '1 day')$$);
CALL t.check('H11 prune_manage_links() removes exactly the expired link',
  $$SELECT booking.prune_manage_links() = 1$$);
CALL t.check('H11a … the valid link stays',
  $$SELECT NOT EXISTS (SELECT 1 FROM booking.manage_links WHERE token_sha256 = sha256(convert_to('old-token', 'UTF8')))
       AND EXISTS (SELECT 1 FROM booking.manage_links WHERE token_sha256 = sha256(convert_to('my-clear-token', 'UTF8')))$$);
CALL t.ok('H11b a second manage link that expired yesterday',
  $$INSERT INTO booking.manage_links (token_sha256, booking_id, issued_at, expires_at)
    VALUES (sha256(convert_to('older-token', 'UTF8')), t.id('mara_1125'), now() - interval '31 days', now() - interval '1 day')$$);
SET ROLE app_writer;
CALL t.check('H11c app_writer, the scheduler''s role, runs all four housekeeping functions in order on its grants alone; only the expired link is due',
  $$SELECT ARRAY[booking.expire_lapsed_holds(), booking.erase_due_notes(), booking.erase_due_contacts(), booking.prune_manage_links()] = ARRAY[0, 0, 0, 1]$$);
RESET ROLE;
CALL t.check('H11c2 … the second expired link is gone, the valid link stays',
  $$SELECT NOT EXISTS (SELECT 1 FROM booking.manage_links WHERE token_sha256 = sha256(convert_to('older-token', 'UTF8')))
       AND EXISTS (SELECT 1 FROM booking.manage_links WHERE token_sha256 = sha256(convert_to('my-clear-token', 'UTF8')))$$);
SET ROLE app_reader;
CALL t.refused('H11d app_reader cannot run prune_manage_links (it runs as its owner, so only app_writer may call it)',
  $$SELECT booking.prune_manage_links()$$, '42501', '%permission denied for function prune_manage_links%');
RESET ROLE;
CALL t.ok('H12 a second consent wording is published …',
  $$WITH c AS (INSERT INTO booking.note_consent_texts (business_id, locale, body)
                SELECT id, 'en', 'I agree that my note is stored for my appointment.' FROM booking.businesses RETURNING id)
    SELECT t.keep('old_wording', id) FROM c$$);
CALL t.ok('H12a … and retired',
  $$UPDATE booking.note_consent_texts SET retired_at = now() WHERE id = t.id('old_wording')$$);
CALL t.refused('H13 a note under retired wording is refused',
  $$INSERT INTO booking.booking_notes (booking_id, business_id, body, consent_text_id)
    SELECT id, business_id, 'Hip.', t.id('old_wording') FROM booking.bookings WHERE id = t.id('couple_14')$$,
  '23514', 'booking L24: consent wording % is retired%');

-- ───────── verdict (skipped when the caller passes -v battery_no_verdict=1)
\if :{?battery_no_verdict}
\else
\pset tuples_only on
\pset format unaligned
SELECT CASE WHEN pass THEN 'PASS  ' ELSE 'FAIL  ' END || label || CASE WHEN pass THEN '' ELSE E'\n        ' || detail END AS result
  FROM t.results ORDER BY n;
SELECT count(*) FILTER (WHERE pass) || ' passed, ' || count(*) FILTER (WHERE NOT pass) || ' failed' AS summary FROM t.results;
DO $$
DECLARE f int;
BEGIN
  SELECT count(*) INTO f FROM t.results WHERE NOT pass;
  IF f > 0 THEN RAISE EXCEPTION 'battery: % law test(s) failed — see the FAIL lines above', f; END IF;
END $$;
\endif
