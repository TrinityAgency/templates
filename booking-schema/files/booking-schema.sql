-- booking-schema.sql — the data model of an appointment booking system (PostgreSQL 16+).
--
-- WHAT IT ADDS
--   Schema `booking`: businesses (one time zone each), services with priced durations, a
--   confirmation mode (instant | request) and a cancellation policy; resources (staff now,
--   rooms and equipment later) with weekly hours, dated exceptions and the services each can
--   perform; zones with a directed travel-minutes table; bookings standing on 1..n resources;
--   per-booking customer contact, an optional consented note, hashed manage links, and an
--   append-only event log other modules read by cursor.
--
-- WHAT IT GUARDS AGAINST (each law named). A law held by a trigger refuses with SQLSTATE 23514 and a
-- message starting `booking Lnn:`; a law held by a constraint refuses with the constraint's SQLSTATE
-- and names the constraint: L1 is 23P01 `no_resource_in_two_live_bookings` (the slot was just
-- taken), a link that tries to carry a footprint of its own is 23503 `a_link_carries_its_bookings_footprint`,
-- and the named CHECKs (e.g. `a_hold_lapses_by_the_visit`) are 23514 with their name.
--   L1  a resource in two live bookings whose footprints (visit + buffers) overlap — race-free,
--       by an exclusion constraint, for every resource of a multi-resource booking at once
--   L2  a lapsed hold blocking a slot: a hold past its deadline yields to the next booking of
--       its resource without waiting for a sweeper; booking.expire_lapsed_holds() closes the
--       lapsed holds nobody competed for, so their personal data can fall due for erasure
--   L3–L10 the lifecycle: entry state follows the confirmation mode, a hold has a bounded
--       deadline, only listed steps, closed never reopens, accept only before the deadline …
--   L11 terms (price, buffers, cancellation policy) changing after the customer agreed to them
--   L19/L20 two consecutive bookings of one resource closer than the travel between their zones
--   L21 a resource linked under any isolation level but READ COMMITTED, where the travel law
--       could not see a neighbour committed meanwhile
--   L18 a live booking without its resources, its contact, or (on site) its address
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * compute availability (weekly hours, exceptions, time-zone arithmetic): the slot
--     calculator does that; this schema refuses conflicts, it does not search for free time
--   * refuse a booking outside working hours (staff may book overtime; the slot calculator offers only working hours)
--   * payments, deposits, vouchers, reminders: separate modules reference booking.bookings(id)
--     and read booking.booking_events; none of them needs a column here
--   * row-level security per business (add policies on business_id if one database serves several businesses)
--
-- Re-runnable: apply it twice and the second run changes nothing.
-- Run inside one transaction:  psql -v ON_ERROR_STOP=1 -1 -f booking-schema.sql

-- ───────────────────────────── 0. prerequisites — fail loudly, here, not halfway down
DO $$
BEGIN
  IF current_setting('server_version_num')::int < 160000 THEN
    RAISE EXCEPTION 'booking-schema needs PostgreSQL 16 or newer — this server is %', current_setting('server_version');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'btree_gist') THEN
    RAISE EXCEPTION 'booking-schema needs the btree_gist extension (contrib) — install the server''s contrib package';
  END IF;
END $$;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['app_reader', 'app_writer', 'app_admin'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      BEGIN
        EXECUTE format('CREATE ROLE %I NOLOGIN', r);
      EXCEPTION WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'booking-schema needs CREATEROLE to create app_reader/app_writer/app_admin (role % is missing) — create them first, or install as a role with CREATEROLE', r;
      END;
    END IF;
  END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA IF NOT EXISTS booking;

-- ───────────────────────────── 1. vocabulary — declared order is policy
DO $$ BEGIN CREATE TYPE booking.confirmation_mode AS ENUM ('instant', 'request');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE booking.service_location AS ENUM ('premises', 'customer_site');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE booking.resource_kind AS ENUM ('staff', 'room', 'equipment');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE booking.hours_effect AS ENUM ('closed', 'open');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE booking.booking_channel AS ENUM ('customer', 'staff');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- live states first (held < confirmed), then the outcomes of a visit, then the ways a booking
-- ends without one. is_live ≡ status IN ('held','confirmed').
DO $$ BEGIN CREATE TYPE booking.booking_status AS ENUM
  ('held', 'confirmed', 'completed', 'no_show', 'cancelled', 'declined', 'expired');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE booking.cancelling_party AS ENUM ('customer', 'business');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE booking.booking_event_kind AS ENUM
  ('created', 'status_changed', 'moved', 'contact_erased', 'note_erased');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- wall-clock windows (weekly hours, exceptions) are ranges of time-of-day
DO $$ BEGIN CREATE TYPE booking.timerange AS RANGE (subtype = time);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ───────────────────────────── 2. pure functions the tables need
CREATE OR REPLACE FUNCTION booking.is_iana_time_zone(z text) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT z IS NOT NULL
     AND (z = 'UTC' OR z ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$')
     AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = z)
$$;

-- The footprint of a visit: the span a resource is blocked, buffers included.
-- IMMUTABLE is honest here: adding whole minutes to an instant does not depend on TimeZone.
CREATE OR REPLACE FUNCTION booking.footprint(visit tstzrange, before_min integer, after_min integer)
RETURNS tstzrange LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog AS $$
  SELECT tstzrange(lower(visit) - make_interval(mins => before_min), upper(visit) + make_interval(mins => after_min), '[)')
$$;

-- The late-cancellation fee, rounded half up to the minor unit. Declared once; the view and the
-- lifecycle both call it.
CREATE OR REPLACE FUNCTION booking.late_fee_minor(price_minor bigint, fee_bp integer)
RETURNS bigint LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT (price_minor * fee_bp + 5000) / 10000
$$;

-- ───────────────────────────── 3. the business and its configuration
CREATE TABLE IF NOT EXISTS booking.businesses (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                   text NOT NULL,
  time_zone              text NOT NULL,
  currency               text NOT NULL,
  travel_base_minutes    integer NOT NULL DEFAULT 0,
  note_retention_days    integer NOT NULL DEFAULT 7,
  contact_retention_days integer NOT NULL DEFAULT 365,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_name_is_not_blank  CHECK (btrim(name) <> ''),
  CONSTRAINT time_zone_is_an_iana_name   CHECK (booking.is_iana_time_zone(time_zone)),
  CONSTRAINT currency_is_iso_4217_shaped CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT travel_base_is_sane         CHECK (travel_base_minutes BETWEEN 0 AND 240),
  CONSTRAINT retention_is_bounded        CHECK (note_retention_days BETWEEN 0 AND 3650
                                            AND contact_retention_days BETWEEN 0 AND 3650)
);
COMMENT ON TABLE booking.businesses IS
  'One row = one business that takes bookings: one time zone (wall-clock hours are read in it), one currency, its retention periods.';

CREATE TABLE IF NOT EXISTS booking.zones (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES booking.businesses (id) ON DELETE CASCADE,
  name        text NOT NULL,
  is_premises boolean NOT NULL DEFAULT false,
  CONSTRAINT zone_name_is_unique_per_business UNIQUE (business_id, name),
  CONSTRAINT zone_key_with_business           UNIQUE (business_id, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS zones_one_premises_per_business
  ON booking.zones (business_id) WHERE is_premises;
COMMENT ON TABLE booking.zones IS
  'One row = one place a visit can happen: the premises (at most one per business) or a service area of mobile visits.';

CREATE TABLE IF NOT EXISTS booking.zone_travel (
  business_id  uuid NOT NULL,
  from_zone_id uuid NOT NULL,
  to_zone_id   uuid NOT NULL,
  minutes      integer NOT NULL,
  PRIMARY KEY (from_zone_id, to_zone_id),
  FOREIGN KEY (business_id, from_zone_id) REFERENCES booking.zones (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, to_zone_id)   REFERENCES booking.zones (business_id, id) ON DELETE CASCADE,
  CONSTRAINT travel_minutes_are_sane CHECK (minutes BETWEEN 0 AND 600)
);
COMMENT ON TABLE booking.zone_travel IS
  'One row = the travel time of one directed trip from a zone to a zone (A→B may differ from B→A). A row from a zone to itself opts that zone into intra-zone trips.';

CREATE TABLE IF NOT EXISTS booking.services (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           uuid NOT NULL REFERENCES booking.businesses (id) ON DELETE CASCADE,
  name                  text NOT NULL,
  confirmation          booking.confirmation_mode NOT NULL,
  hold_minutes          integer,
  location              booking.service_location NOT NULL DEFAULT 'premises',
  buffer_before_minutes integer NOT NULL DEFAULT 0,
  buffer_after_minutes  integer NOT NULL DEFAULT 0,
  resources_required    smallint NOT NULL DEFAULT 1,
  cancel_free_hours     integer NOT NULL DEFAULT 24,
  late_cancel_fee_bp    integer NOT NULL DEFAULT 0,
  retired_at            timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT service_key_with_business       UNIQUE (business_id, id),
  CONSTRAINT service_name_is_not_blank       CHECK (btrim(name) <> ''),
  CONSTRAINT a_request_names_its_hold_window CHECK ((confirmation = 'request') = (hold_minutes IS NOT NULL)),
  CONSTRAINT hold_window_is_sane             CHECK (hold_minutes IS NULL OR hold_minutes BETWEEN 5 AND 10080),
  CONSTRAINT buffers_are_sane                CHECK (buffer_before_minutes BETWEEN 0 AND 240
                                                AND buffer_after_minutes BETWEEN 0 AND 240),
  CONSTRAINT resources_required_is_sane      CHECK (resources_required BETWEEN 1 AND 10),
  CONSTRAINT cancellation_policy_is_sane     CHECK (cancel_free_hours BETWEEN 0 AND 720
                                                AND late_cancel_fee_bp BETWEEN 0 AND 10000)
);
COMMENT ON TABLE booking.services IS
  'One row = one service a business offers: how it is confirmed, where it happens, its buffers, how many resources it needs at once, and its cancellation policy (free until N hours before, then a fee share in basis points).';

CREATE TABLE IF NOT EXISTS booking.service_durations (
  service_id  uuid NOT NULL REFERENCES booking.services (id) ON DELETE CASCADE,
  minutes     integer NOT NULL,
  price_minor bigint NOT NULL,
  PRIMARY KEY (service_id, minutes),
  CONSTRAINT duration_is_sane      CHECK (minutes BETWEEN 5 AND 1440),
  CONSTRAINT price_is_not_negative CHECK (price_minor >= 0)
);
COMMENT ON TABLE booking.service_durations IS
  'One row = one length a service can be booked for, and its current list price in minor units of the business currency.';

CREATE TABLE IF NOT EXISTS booking.resources (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  uuid NOT NULL REFERENCES booking.businesses (id) ON DELETE CASCADE,
  kind         booking.resource_kind NOT NULL DEFAULT 'staff',
  display_name text NOT NULL,
  retired_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT resource_key_with_business UNIQUE (business_id, id),
  CONSTRAINT resource_name_is_not_blank CHECK (btrim(display_name) <> '')
);
COMMENT ON TABLE booking.resources IS
  'One row = one thing a booking occupies exclusively: a person, a room, a piece of equipment. Retired, never deleted, once booked.';

CREATE TABLE IF NOT EXISTS booking.resource_services (
  business_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  service_id  uuid NOT NULL,
  PRIMARY KEY (resource_id, service_id),
  FOREIGN KEY (business_id, resource_id) REFERENCES booking.resources (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, service_id)  REFERENCES booking.services (business_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS resource_services_by_service ON booking.resource_services (service_id);
COMMENT ON TABLE booking.resource_services IS
  'One row = one resource is able to perform one service (same business, by foreign key).';

CREATE TABLE IF NOT EXISTS booking.resource_weekly_hours (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_id uuid NOT NULL REFERENCES booking.resources (id) ON DELETE CASCADE,
  iso_weekday smallint NOT NULL,
  opens       time NOT NULL,
  closes      time NOT NULL,
  effective   daterange NOT NULL DEFAULT daterange(NULL, NULL),
  CONSTRAINT weekday_is_iso                CHECK (iso_weekday BETWEEN 1 AND 7),
  CONSTRAINT a_window_closes_after_opening CHECK (closes > opens),
  CONSTRAINT effective_is_not_empty        CHECK (NOT isempty(effective)),
  CONSTRAINT weekly_windows_never_overlap  EXCLUDE USING gist
    (resource_id WITH =, iso_weekday WITH =, effective WITH &&, booking.timerange(opens, closes) WITH &&)
);
COMMENT ON TABLE booking.resource_weekly_hours IS
  'One row = one recurring wall-clock window a resource works on one ISO weekday (1 = Monday), in the business time zone, over an effective date range. A split shift is two rows; closes may be 24:00.';

CREATE TABLE IF NOT EXISTS booking.resource_hours_exceptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_id uuid NOT NULL REFERENCES booking.resources (id) ON DELETE CASCADE,
  on_dates    daterange NOT NULL,
  starts      time NOT NULL DEFAULT '00:00',
  ends        time NOT NULL DEFAULT '24:00',
  effect      booking.hours_effect NOT NULL,
  CONSTRAINT exception_dates_are_bounded      CHECK (NOT isempty(on_dates) AND NOT lower_inf(on_dates) AND NOT upper_inf(on_dates)),
  CONSTRAINT an_exception_ends_after_it_starts CHECK (ends > starts),
  CONSTRAINT exceptions_never_overlap          EXCLUDE USING gist
    (resource_id WITH =, on_dates WITH &&, booking.timerange(starts, ends) WITH &&)
);
COMMENT ON TABLE booking.resource_hours_exceptions IS
  'One row = one dated change to a resource''s hours: closed (a day or hours off) or open (extra hours), the same wall-clock window on every date of the range. Deliberately no reason column: a reason for an absence can be health data about staff.';

CREATE TABLE IF NOT EXISTS booking.note_consent_texts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  uuid NOT NULL REFERENCES booking.businesses (id) ON DELETE CASCADE,
  locale       text NOT NULL,
  body         text NOT NULL,
  published_at timestamptz NOT NULL DEFAULT now(),
  retired_at   timestamptz,
  CONSTRAINT consent_text_key_with_business UNIQUE (business_id, id),
  CONSTRAINT consent_body_is_not_blank      CHECK (btrim(body) <> ''),
  CONSTRAINT consent_retires_after_publish  CHECK (retired_at IS NULL OR retired_at >= published_at)
);
COMMENT ON TABLE booking.note_consent_texts IS
  'One row = one published wording of the explicit consent a customer gives before writing a note that may carry health information. Evidence: never edited, only retired.';

-- ───────────────────────────── 4. bookings
CREATE TABLE IF NOT EXISTS booking.bookings (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id            uuid NOT NULL REFERENCES booking.businesses (id) ON DELETE RESTRICT,
  service_id             uuid NOT NULL,
  zone_id                uuid NOT NULL,
  channel                booking.booking_channel NOT NULL,
  status                 booking.booking_status NOT NULL,
  during                 tstzrange NOT NULL,
  -- terms fixed at booking time (copied from the service by the lifecycle, L11)
  location               booking.service_location NOT NULL,
  buffer_before_minutes  integer NOT NULL,
  buffer_after_minutes   integer NOT NULL,
  resources_required     smallint NOT NULL,
  price_minor            bigint NOT NULL,
  currency               text NOT NULL,
  cancel_free_hours      integer NOT NULL,
  late_cancel_fee_bp     integer NOT NULL,
  -- lifecycle stamps (written by the lifecycle, never by the caller)
  hold_until             timestamptz,
  confirmed_at           timestamptz,
  closed_at              timestamptz,
  cancelled_by           booking.cancelling_party,
  cancellation_fee_minor bigint,
  created_at             timestamptz NOT NULL DEFAULT now(),
  -- derived, never written
  blocked                tstzrange GENERATED ALWAYS AS (booking.footprint(during, buffer_before_minutes, buffer_after_minutes)) STORED,
  is_live                boolean   GENERATED ALWAYS AS (status IN ('held', 'confirmed')) STORED,
  FOREIGN KEY (business_id, service_id) REFERENCES booking.services (business_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (business_id, zone_id)    REFERENCES booking.zones (business_id, id)    ON DELETE RESTRICT,
  CONSTRAINT booking_key_with_business   UNIQUE (id, business_id),
  CONSTRAINT booking_footprint_key       UNIQUE (id, business_id, zone_id, blocked, is_live),
  CONSTRAINT a_visit_is_a_bounded_half_open_span CHECK (NOT isempty(during) AND NOT lower_inf(during) AND NOT upper_inf(during)
                                                    AND lower_inc(during) AND NOT upper_inc(during)),
  CONSTRAINT request_states_carry_a_deadline CHECK (status NOT IN ('held', 'declined', 'expired') OR hold_until IS NOT NULL),
  CONSTRAINT a_hold_lapses_by_the_visit      CHECK (status <> 'held' OR hold_until <= lower(during)),
  CONSTRAINT confirmation_is_stamped         CHECK ((status IN ('confirmed', 'completed', 'no_show')) <= (confirmed_at IS NOT NULL)
                                                AND (status IN ('held', 'declined', 'expired')) <= (confirmed_at IS NULL)),
  CONSTRAINT closed_exactly_when_not_live    CHECK ((closed_at IS NULL) = (status IN ('held', 'confirmed'))),
  CONSTRAINT a_cancellation_names_its_party  CHECK ((status = 'cancelled') = (cancelled_by IS NOT NULL)
                                                AND (status = 'cancelled') = (cancellation_fee_minor IS NOT NULL)),
  CONSTRAINT fee_is_within_the_price         CHECK (cancellation_fee_minor IS NULL OR cancellation_fee_minor BETWEEN 0 AND price_minor),
  CONSTRAINT terms_are_sane                  CHECK (price_minor >= 0 AND currency ~ '^[A-Z]{3}$'
                                                AND buffer_before_minutes BETWEEN 0 AND 240 AND buffer_after_minutes BETWEEN 0 AND 240
                                                AND resources_required BETWEEN 1 AND 10
                                                AND cancel_free_hours BETWEEN 0 AND 720 AND late_cancel_fee_bp BETWEEN 0 AND 10000)
);
CREATE INDEX IF NOT EXISTS bookings_by_business_start ON booking.bookings (business_id, lower(during));
CREATE INDEX IF NOT EXISTS bookings_open_holds ON booking.bookings (hold_until) WHERE status = 'held';
COMMENT ON TABLE booking.bookings IS
  'One row = one appointment one customer made for one service at one span of time, with the terms agreed at that moment. Closed, never deleted. Other modules (payments, vouchers, reminders) reference it by id.';

CREATE TABLE IF NOT EXISTS booking.booking_resources (
  booking_id  uuid NOT NULL,
  resource_id uuid NOT NULL,
  business_id uuid NOT NULL,
  zone_id     uuid NOT NULL,
  blocked     tstzrange NOT NULL,
  is_live     boolean NOT NULL,
  PRIMARY KEY (booking_id, resource_id),
  FOREIGN KEY (business_id, resource_id) REFERENCES booking.resources (business_id, id) ON DELETE RESTRICT
);
COMMENT ON TABLE booking.booking_resources IS
  'One row = one resource occupied by one booking. Carries its booking''s footprint and liveness by a cascading foreign key, so one exclusion constraint guards every resource.';

-- L1's carrier: a link's footprint IS its booking's footprint (by foreign key, cascading on change)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'a_link_carries_its_bookings_footprint' AND conrelid = 'booking.booking_resources'::regclass) THEN
    ALTER TABLE booking.booking_resources ADD CONSTRAINT a_link_carries_its_bookings_footprint FOREIGN KEY (booking_id, business_id, zone_id, blocked, is_live) REFERENCES booking.bookings (id, business_id, zone_id, blocked, is_live) ON UPDATE CASCADE ON DELETE CASCADE;
  END IF;
END $$;

-- L1: no resource in two live bookings whose footprints overlap
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'no_resource_in_two_live_bookings' AND conrelid = 'booking.booking_resources'::regclass) THEN
    ALTER TABLE booking.booking_resources ADD CONSTRAINT no_resource_in_two_live_bookings EXCLUDE USING gist (resource_id WITH =, blocked WITH &&) WHERE (is_live);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS booking.booking_contacts (
  booking_id    uuid PRIMARY KEY REFERENCES booking.bookings (id) ON DELETE CASCADE,
  full_name     text NOT NULL,
  email         text,
  phone         text,
  visit_address text,
  locale        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contact_name_is_not_blank   CHECK (btrim(full_name) <> ''),
  CONSTRAINT reachable_by_email_or_phone CHECK (email IS NOT NULL OR phone IS NOT NULL),
  CONSTRAINT email_is_shaped_like_one    CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+$'),
  CONSTRAINT phone_is_shaped_like_one    CHECK (phone IS NULL OR phone ~ '^\+?[0-9 ()./-]{5,32}$')
);
COMMENT ON TABLE booking.booking_contacts IS
  'One row = how to reach the customer of one booking (no account). Personal data: erased by retention after the booking ends.';

CREATE TABLE IF NOT EXISTS booking.booking_notes (
  booking_id      uuid PRIMARY KEY,
  business_id     uuid NOT NULL,
  body            text NOT NULL,
  consent_text_id uuid NOT NULL,
  consented_at    timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (booking_id, business_id)      REFERENCES booking.bookings (id, business_id)           ON DELETE CASCADE,
  FOREIGN KEY (business_id, consent_text_id) REFERENCES booking.note_consent_texts (business_id, id) ON DELETE RESTRICT,
  CONSTRAINT note_is_not_blank CHECK (btrim(body) <> ''),
  CONSTRAINT note_is_bounded   CHECK (char_length(body) <= 2000)
);
CREATE INDEX IF NOT EXISTS booking_notes_by_consent_text ON booking.booking_notes (consent_text_id);
COMMENT ON TABLE booking.booking_notes IS
  'One row = the customer''s free-text note to one booking, which may carry health information, and the explicit consent given with it (which wording, when). Erased by retention or on withdrawal; never edited.';

CREATE TABLE IF NOT EXISTS booking.manage_links (
  token_sha256 bytea PRIMARY KEY,
  booking_id   uuid NOT NULL REFERENCES booking.bookings (id) ON DELETE CASCADE,
  issued_at    timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  CONSTRAINT stores_a_sha256_digest_not_a_token CHECK (octet_length(token_sha256) = 32),
  CONSTRAINT a_link_expires_after_issue         CHECK (expires_at > issued_at),
  CONSTRAINT revocation_follows_issue           CHECK (revoked_at IS NULL OR revoked_at >= issued_at)
);
CREATE INDEX IF NOT EXISTS manage_links_by_booking ON booking.manage_links (booking_id);
COMMENT ON TABLE booking.manage_links IS
  'One row = one link issued to a customer to view or cancel one booking. Only the SHA-256 of the token is stored; the token itself lives in the link.';

CREATE TABLE IF NOT EXISTS booking.booking_events (
  seq          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id   uuid NOT NULL REFERENCES booking.bookings (id) ON DELETE CASCADE,
  kind         booking.booking_event_kind NOT NULL,
  status_after booking.booking_status NOT NULL,
  during_after tstzrange NOT NULL,
  at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS booking_events_by_booking ON booking.booking_events (booking_id, seq);
COMMENT ON TABLE booking.booking_events IS
  'One row = one change to one booking, stating its status and span after the change. Append-only; written only by triggers. Reminder, payment and other modules read it by cursor (seq).';

-- ───────────────────────────── 5. laws as triggers
-- 5a. the lifecycle (L3–L16)
CREATE OR REPLACE FUNCTION booking.bookings_lifecycle() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
DECLARE
  s   booking.services%ROWTYPE;
  biz booking.businesses%ROWTYPE;
  d   booking.service_durations%ROWTYPE;
  cap timestamptz;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.during IS NULL OR isempty(NEW.during) OR lower_inf(NEW.during) OR upper_inf(NEW.during) OR NOT lower_inc(NEW.during) OR upper_inc(NEW.during) THEN
      RAISE EXCEPTION 'booking L13: a visit is a bounded half-open span [start, end) — got %', NEW.during USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO s FROM booking.services WHERE id = NEW.service_id AND business_id = NEW.business_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'booking L14: service % is not offered by business %', NEW.service_id, NEW.business_id USING ERRCODE = 'check_violation';
    END IF;
    IF s.retired_at IS NOT NULL THEN
      RAISE EXCEPTION 'booking L14: service % was retired at % — book a service still offered', s.id, s.retired_at USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO d FROM booking.service_durations
     WHERE service_id = s.id AND minutes * interval '1 minute' = upper(NEW.during) - lower(NEW.during);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'booking L13: service % offers no visit of % — book one of its durations', s.id, upper(NEW.during) - lower(NEW.during) USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO biz FROM booking.businesses WHERE id = NEW.business_id;
    IF ROW(NEW.confirmed_at, NEW.closed_at, NEW.cancelled_by, NEW.cancellation_fee_minor) IS DISTINCT FROM ROW(NULL::timestamptz, NULL::timestamptz, NULL::booking.cancelling_party, NULL::bigint) THEN
      RAISE EXCEPTION 'booking L11: confirmed_at, closed_at, cancelled_by and cancellation_fee_minor are written by the lifecycle, never by the caller' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.channel = 'customer' AND lower(NEW.during) <= now() THEN
      RAISE EXCEPTION 'booking L15: a customer books a visit that starts in the future — % has begun', lower(NEW.during) USING ERRCODE = 'check_violation';
    END IF;

    -- terms fixed at booking time (L11)
    NEW.location              := s.location;
    NEW.buffer_before_minutes := s.buffer_before_minutes;
    NEW.buffer_after_minutes  := s.buffer_after_minutes;
    NEW.resources_required    := s.resources_required;
    NEW.cancel_free_hours     := s.cancel_free_hours;
    NEW.late_cancel_fee_bp    := s.late_cancel_fee_bp;
    NEW.price_minor           := d.price_minor;
    NEW.currency              := biz.currency;
    NEW.created_at            := now();

    -- the place (L16)
    IF s.location = 'premises' THEN
      SELECT z.id INTO NEW.zone_id FROM booking.zones z WHERE z.business_id = NEW.business_id AND z.is_premises;
      IF NEW.zone_id IS NULL THEN
        RAISE EXCEPTION 'booking L16: business % has no premises zone — create its zone with is_premises = true', NEW.business_id USING ERRCODE = 'check_violation';
      END IF;
    ELSIF NEW.zone_id IS NULL THEN
      RAISE EXCEPTION 'booking L16: service % is visited at the customer''s site — name the zone of the visit', s.id USING ERRCODE = 'check_violation';
    END IF;

    -- the entry state follows the confirmation mode (L3)
    IF NEW.status IS NULL THEN
      NEW.status := CASE s.confirmation WHEN 'request' THEN 'held' ELSE 'confirmed' END::booking.booking_status;
    END IF;
    IF NEW.status NOT IN ('held', 'confirmed') THEN
      RAISE EXCEPTION 'booking L3: a booking enters as held or confirmed — got %', NEW.status USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'held' AND s.confirmation = 'instant' THEN
      RAISE EXCEPTION 'booking L3: service % confirms instantly — it is booked as confirmed, never held', s.id USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'confirmed' AND s.confirmation = 'request' AND NEW.channel <> 'staff' THEN RAISE EXCEPTION 'booking L3: service % confirms by request — a customer''s booking enters as held until staff accept or decline it', s.id USING ERRCODE = 'check_violation'; END IF;

    -- the hold deadline (L4)
    IF NEW.status = 'held' THEN
      cap := least(now() + make_interval(mins => s.hold_minutes), lower(NEW.during));
      IF NEW.hold_until IS NULL THEN
        NEW.hold_until := cap;
      END IF;
      IF NEW.hold_until <= now() OR NEW.hold_until > cap THEN
        RAISE EXCEPTION 'booking L4: a hold on service % ends after now and by % (its %-minute window or the visit start, whichever comes first) — got %', s.id, cap, s.hold_minutes, NEW.hold_until USING ERRCODE = 'check_violation';
      END IF;
    ELSE
      IF NEW.hold_until IS NOT NULL THEN
        RAISE EXCEPTION 'booking L4: only a held booking carries a hold deadline' USING ERRCODE = 'check_violation';
      END IF;
      NEW.confirmed_at := now();
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NOT OLD.is_live THEN RAISE EXCEPTION 'booking L6: booking % is closed (%) — a closed booking never changes; book again', OLD.id, OLD.status USING ERRCODE = 'check_violation'; END IF;
  IF ROW(NEW.id, NEW.business_id, NEW.service_id, NEW.channel, NEW.location, NEW.buffer_before_minutes, NEW.buffer_after_minutes,
         NEW.resources_required, NEW.price_minor, NEW.currency, NEW.cancel_free_hours, NEW.late_cancel_fee_bp, NEW.created_at,
         NEW.hold_until, NEW.confirmed_at, NEW.closed_at, NEW.cancellation_fee_minor)
     IS DISTINCT FROM
     ROW(OLD.id, OLD.business_id, OLD.service_id, OLD.channel, OLD.location, OLD.buffer_before_minutes, OLD.buffer_after_minutes,
         OLD.resources_required, OLD.price_minor, OLD.currency, OLD.cancel_free_hours, OLD.late_cancel_fee_bp, OLD.created_at,
         OLD.hold_until, OLD.confirmed_at, OLD.closed_at, OLD.cancellation_fee_minor) THEN
    RAISE EXCEPTION 'booking L11: the terms of booking % were fixed when it was made and its stamps belong to the lifecycle — cancel it and book again', OLD.id USING ERRCODE = 'check_violation';
  END IF;

  -- a move (L12)
  IF NEW.during IS DISTINCT FROM OLD.during OR NEW.zone_id IS DISTINCT FROM OLD.zone_id THEN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'booking L12: move booking % or change its status — one step at a time', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.during IS NULL OR isempty(NEW.during) OR lower_inf(NEW.during) OR upper_inf(NEW.during)
       OR upper(NEW.during) - lower(NEW.during) <> upper(OLD.during) - lower(OLD.during) THEN
      RAISE EXCEPTION 'booking L12: a move keeps the visit''s length (%) — to change it, cancel and book again', upper(OLD.during) - lower(OLD.during) USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.location = 'premises' AND NEW.zone_id IS DISTINCT FROM OLD.zone_id THEN
      RAISE EXCEPTION 'booking L16: booking % happens at the premises — its zone is the premises zone', OLD.id USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- a step of the lifecycle (L5, L7–L10)
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ((OLD.status = 'held'      AND NEW.status IN ('confirmed', 'declined', 'expired', 'cancelled'))
         OR (OLD.status = 'confirmed' AND NEW.status IN ('completed', 'no_show', 'cancelled'))) THEN
      RAISE EXCEPTION 'booking L5: % → % is not a step of the lifecycle — from held: confirmed, declined, expired, cancelled; from confirmed: completed, no_show, cancelled', OLD.status, NEW.status USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'held' AND NEW.status = 'confirmed' AND now() >= OLD.hold_until THEN RAISE EXCEPTION 'booking L7: the hold on booking % lapsed at % — it can only expire now; the customer books again', OLD.id, OLD.hold_until USING ERRCODE = 'check_violation'; END IF;
    IF NEW.status = 'expired' AND now() < OLD.hold_until THEN
      RAISE EXCEPTION 'booking L8: booking % is held until % — it expires only then; decline it to release it sooner', OLD.id, OLD.hold_until USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IN ('completed', 'no_show') AND now() < lower(OLD.during) THEN
      RAISE EXCEPTION 'booking L9: booking % begins at % — completed and no_show are recorded once the visit has begun', OLD.id, lower(OLD.during) USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'cancelled' AND now() >= lower(OLD.during) THEN
      RAISE EXCEPTION 'booking L10: booking % began at % — a visit that has begun is completed or no_show, not cancelled', OLD.id, lower(OLD.during) USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'confirmed' THEN
      NEW.confirmed_at := now();
    END IF;
    IF NEW.status NOT IN ('held', 'confirmed') THEN
      NEW.closed_at := now();
    END IF;
    IF NEW.status = 'cancelled' THEN
      NEW.cancellation_fee_minor := CASE
        WHEN OLD.status = 'confirmed' AND NEW.cancelled_by = 'customer'
         AND now() > lower(OLD.during) - make_interval(hours => OLD.cancel_free_hours)
        THEN booking.late_fee_minor(OLD.price_minor, OLD.late_cancel_fee_bp)
        ELSE 0 END;
    END IF;
  END IF;
  RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS b_10_lifecycle ON booking.bookings;
CREATE TRIGGER b_10_lifecycle BEFORE INSERT OR UPDATE ON booking.bookings
  FOR EACH ROW EXECUTE FUNCTION booking.bookings_lifecycle();

-- 5b. a booking is a record (L22)
CREATE OR REPLACE FUNCTION booking.bookings_never_deleted() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  RAISE EXCEPTION 'booking L22: booking % is a record — cancel it instead of deleting; personal data leaves through the retention functions', OLD.id USING ERRCODE = 'check_violation';
END
$fn$;
DROP TRIGGER IF EXISTS b_20_never_deleted ON booking.bookings;
CREATE TRIGGER b_20_never_deleted BEFORE DELETE ON booking.bookings
  FOR EACH ROW EXECUTE FUNCTION booking.bookings_never_deleted();

-- 5c. a link adopts its booking's footprint and fits the service (L17, L26)
CREATE OR REPLACE FUNCTION booking.link_adopts_booking() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
DECLARE
  b booking.bookings%ROWTYPE;
  r booking.resources%ROWTYPE;
BEGIN
  SELECT * INTO b FROM booking.bookings WHERE id = NEW.booking_id;
  IF NOT FOUND THEN
    RETURN NEW;                                   -- the foreign key refuses it
  END IF;
  IF NOT b.is_live THEN
    RAISE EXCEPTION 'booking L26: booking % is closed (%) — resources are linked only while a booking is live', b.id, b.status USING ERRCODE = 'check_violation';
  END IF;
  NEW.business_id := b.business_id;
  NEW.zone_id     := b.zone_id;
  NEW.blocked     := b.blocked;
  NEW.is_live     := b.is_live;
  SELECT * INTO r FROM booking.resources WHERE id = NEW.resource_id;
  IF NOT FOUND THEN
    RETURN NEW;                                   -- the foreign key refuses it
  END IF;
  IF r.business_id <> b.business_id THEN
    RAISE EXCEPTION 'booking L17: resource % belongs to another business than booking %', r.id, b.id USING ERRCODE = 'check_violation';
  END IF;
  IF r.retired_at IS NOT NULL THEN
    RAISE EXCEPTION 'booking L17: resource % was retired at % — pick another resource', r.id, r.retired_at USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM booking.resource_services rs WHERE rs.resource_id = r.id AND rs.service_id = b.service_id) THEN
    RAISE EXCEPTION 'booking L17: resource % does not perform service % — add it to resource_services or pick another resource', r.id, b.service_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS br_10_adopt_booking ON booking.booking_resources;
CREATE TRIGGER br_10_adopt_booking BEFORE INSERT ON booking.booking_resources
  FOR EACH ROW EXECUTE FUNCTION booking.link_adopts_booking();

-- 5d. a lapsed hold yields (L2): before a resource is linked or moved, its lapsed holds expire
CREATE OR REPLACE FUNCTION booking.release_lapsed_holds() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  IF NEW.is_live THEN
    UPDATE booking.bookings b SET status = 'expired'
     WHERE b.status = 'held' AND b.hold_until <= now() AND b.id <> NEW.booking_id
       AND EXISTS (SELECT 1 FROM booking.booking_resources br
                    WHERE br.booking_id = b.id AND br.resource_id = NEW.resource_id AND br.is_live);
  END IF;
  RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS br_20_release_lapsed_holds ON booking.booking_resources;
CREATE TRIGGER br_20_release_lapsed_holds BEFORE INSERT OR UPDATE OF blocked, zone_id ON booking.booking_resources FOR EACH ROW EXECUTE FUNCTION booking.release_lapsed_holds();

-- 5e. links are history once their booking closes (L26)
CREATE OR REPLACE FUNCTION booking.links_keep_history() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.booking_id <> OLD.booking_id OR NEW.resource_id <> OLD.resource_id THEN
      RAISE EXCEPTION 'booking L26: a link is never re-pointed — delete it and link the new resource' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM booking.bookings WHERE id = OLD.booking_id AND NOT is_live) THEN
    RAISE EXCEPTION 'booking L26: booking % is closed — its resources are history', OLD.booking_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN OLD;
END
$fn$;
DROP TRIGGER IF EXISTS br_30_keep_history ON booking.booking_resources;
CREATE TRIGGER br_30_keep_history BEFORE UPDATE OR DELETE ON booking.booking_resources
  FOR EACH ROW EXECUTE FUNCTION booking.links_keep_history();

-- 5f. travel (L19–L21). A trip between consecutive footprints of one resource needs
-- base buffer + travel(A→B); within one zone without a row, nothing; unknown A→B is refused.
CREATE OR REPLACE VIEW booking.v_travel_gaps AS
SELECT t.business_id, t.from_zone_id, t.to_zone_id, t.minutes AS travel_minutes,
       t.minutes + b.travel_base_minutes AS gap_minutes
  FROM booking.zone_travel t
  JOIN booking.businesses b ON b.id = t.business_id;
COMMENT ON VIEW booking.v_travel_gaps IS
  'The derivation of a travel gap: base buffer + travel minutes. The slot calculator''s travelMinutes(from, to) reads this view (or travel_gap_minutes) so both agree.';

CREATE OR REPLACE FUNCTION booking.travel_gap_minutes(from_zone uuid, to_zone uuid) RETURNS integer
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT COALESCE((SELECT g.gap_minutes FROM booking.v_travel_gaps g
                    WHERE g.from_zone_id = from_zone AND g.to_zone_id = to_zone),
                  CASE WHEN from_zone = to_zone THEN 0 END)
$$;

CREATE OR REPLACE FUNCTION booking.travel_law() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
DECLARE
  nb   record;
  need integer;
  gap  integer;
BEGIN
  -- L21: READ COMMITTED only. Under REPEATABLE READ the snapshot predates the lock below; under
  -- SERIALIZABLE too, and SSI cannot rescue it when the neighbour's writer ran READ COMMITTED.
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'booking L21: resources are linked under READ COMMITTED, this transaction is % — under REPEATABLE READ or SERIALIZABLE the travel law cannot see a neighbour committed meanwhile', upper(current_setting('transaction_isolation')) USING ERRCODE = 'check_violation';
  END IF;
  -- one writer per resource at a time; the next writer re-reads after the first commits
  PERFORM pg_advisory_xact_lock(hashtext('booking.resource'), hashtext(NEW.resource_id::text));
  FOR nb IN
    (SELECT 'before' AS side, br.booking_id, br.zone_id, br.blocked
       FROM booking.booking_resources br JOIN booking.bookings b ON b.id = br.booking_id
      WHERE br.resource_id = NEW.resource_id AND br.is_live AND br.booking_id <> NEW.booking_id
        AND upper(br.blocked) <= lower(NEW.blocked)
        AND NOT (b.status = 'held' AND b.hold_until <= now())
      ORDER BY upper(br.blocked) DESC LIMIT 1)
    UNION ALL
    (SELECT 'after', br.booking_id, br.zone_id, br.blocked
       FROM booking.booking_resources br JOIN booking.bookings b ON b.id = br.booking_id
      WHERE br.resource_id = NEW.resource_id AND br.is_live AND br.booking_id <> NEW.booking_id
        AND lower(br.blocked) >= upper(NEW.blocked)
        AND NOT (b.status = 'held' AND b.hold_until <= now())
      ORDER BY lower(br.blocked) LIMIT 1)
  LOOP
    IF nb.side = 'before' THEN
      need := booking.travel_gap_minutes(nb.zone_id, NEW.zone_id);
      gap  := floor(extract(epoch FROM lower(NEW.blocked) - upper(nb.blocked)) / 60);
      IF need IS NULL THEN
        RAISE EXCEPTION 'booking L20: no travel time is known from zone % to zone % — add it to booking.zone_travel', nb.zone_id, NEW.zone_id USING ERRCODE = 'check_violation';
      END IF;
    ELSE
      need := booking.travel_gap_minutes(NEW.zone_id, nb.zone_id);
      gap  := floor(extract(epoch FROM lower(nb.blocked) - upper(NEW.blocked)) / 60);
      IF need IS NULL THEN
        RAISE EXCEPTION 'booking L20: no travel time is known from zone % to zone % — add it to booking.zone_travel', NEW.zone_id, nb.zone_id USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    IF gap < need THEN
      RAISE EXCEPTION 'booking L19: resource % needs % min between booking % and its % neighbour % (base buffer + travel), the plan leaves % — move one of them or pick another resource', NEW.resource_id, need, NEW.booking_id, nb.side, nb.booking_id, gap USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  RETURN NULL;
END
$fn$;
DROP TRIGGER IF EXISTS br_40_travel ON booking.booking_resources;
CREATE TRIGGER br_40_travel AFTER INSERT OR UPDATE OF blocked, zone_id, is_live ON booking.booking_resources FOR EACH ROW WHEN (NEW.is_live) EXECUTE FUNCTION booking.travel_law();

-- 5g. a live booking is whole at commit (L18)
CREATE OR REPLACE FUNCTION booking.booking_is_whole() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
DECLARE
  bid uuid;
  b   booking.bookings%ROWTYPE;
  c   booking.booking_contacts%ROWTYPE;
  n   integer;
BEGIN
  IF TG_TABLE_NAME = 'bookings' THEN
    bid := NEW.id;
  ELSIF TG_OP = 'DELETE' THEN
    bid := OLD.booking_id;
  ELSE
    bid := NEW.booking_id;
  END IF;
  SELECT * INTO b FROM booking.bookings WHERE id = bid;
  IF NOT FOUND OR NOT b.is_live THEN
    RETURN NULL;
  END IF;
  SELECT count(*) INTO n FROM booking.booking_resources WHERE booking_id = bid;
  IF n <> b.resources_required THEN
    RAISE EXCEPTION 'booking L18: booking % stands on % resource(s) but its service needs % — link exactly that many before commit', bid, n, b.resources_required USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO c FROM booking.booking_contacts WHERE booking_id = bid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking L18: live booking % has no contact — write booking_contacts in the same transaction', bid USING ERRCODE = 'check_violation';
  END IF;
  IF b.location = 'customer_site' AND c.visit_address IS NULL THEN
    RAISE EXCEPTION 'booking L18: booking % is a visit at the customer''s site — its contact needs a visit_address', bid USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END
$fn$;
DROP TRIGGER IF EXISTS b_90_whole ON booking.bookings;
CREATE CONSTRAINT TRIGGER b_90_whole AFTER INSERT ON booking.bookings
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION booking.booking_is_whole();
DROP TRIGGER IF EXISTS br_90_whole ON booking.booking_resources;
CREATE CONSTRAINT TRIGGER br_90_whole AFTER INSERT OR DELETE ON booking.booking_resources
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION booking.booking_is_whole();
DROP TRIGGER IF EXISTS bc_90_whole ON booking.booking_contacts;
CREATE CONSTRAINT TRIGGER bc_90_whole AFTER UPDATE OR DELETE ON booking.booking_contacts
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION booking.booking_is_whole();

-- 5h. consent wording is evidence (L24); a note is never edited (L25)
CREATE OR REPLACE FUNCTION booking.consent_wording_fixed() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  IF ROW(NEW.id, NEW.business_id, NEW.locale, NEW.body, NEW.published_at)
     IS DISTINCT FROM ROW(OLD.id, OLD.business_id, OLD.locale, OLD.body, OLD.published_at) THEN
    RAISE EXCEPTION 'booking L24: consent wording % is evidence once published — publish a new version and retire this one', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS ct_10_wording_fixed ON booking.note_consent_texts;
CREATE TRIGGER ct_10_wording_fixed BEFORE UPDATE ON booking.note_consent_texts
  FOR EACH ROW EXECUTE FUNCTION booking.consent_wording_fixed();

CREATE OR REPLACE FUNCTION booking.note_takes_consent() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'booking L25: a note is never edited — the customer withdraws it (delete) and writes a new one with fresh consent' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM booking.note_consent_texts WHERE id = NEW.consent_text_id AND retired_at IS NOT NULL) THEN
    RAISE EXCEPTION 'booking L24: consent wording % is retired — ask with the current wording', NEW.consent_text_id USING ERRCODE = 'check_violation';
  END IF;
  NEW.consented_at := now();
  RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS bn_10_takes_consent ON booking.booking_notes;
CREATE TRIGGER bn_10_takes_consent BEFORE INSERT OR UPDATE ON booking.booking_notes
  FOR EACH ROW EXECUTE FUNCTION booking.note_takes_consent();

-- 5i. the event log: written by triggers only (SECURITY DEFINER), append-only (L23)
CREATE OR REPLACE FUNCTION booking.record_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  IF TG_TABLE_NAME = 'bookings' THEN
    IF TG_OP = 'INSERT' THEN
      INSERT INTO booking.booking_events (booking_id, kind, status_after, during_after) VALUES (NEW.id, 'created', NEW.status, NEW.during);
    ELSE
      IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO booking.booking_events (booking_id, kind, status_after, during_after) VALUES (NEW.id, 'status_changed', NEW.status, NEW.during);
      END IF;
      IF NEW.during IS DISTINCT FROM OLD.during OR NEW.zone_id IS DISTINCT FROM OLD.zone_id THEN
        INSERT INTO booking.booking_events (booking_id, kind, status_after, during_after) VALUES (NEW.id, 'moved', NEW.status, NEW.during);
      END IF;
    END IF;
  ELSIF TG_TABLE_NAME = 'booking_contacts' THEN
    INSERT INTO booking.booking_events (booking_id, kind, status_after, during_after)
    SELECT b.id, 'contact_erased', b.status, b.during FROM booking.bookings b WHERE b.id = OLD.booking_id;
  ELSIF TG_TABLE_NAME = 'booking_notes' THEN
    INSERT INTO booking.booking_events (booking_id, kind, status_after, during_after)
    SELECT b.id, 'note_erased', b.status, b.during FROM booking.bookings b WHERE b.id = OLD.booking_id;
  END IF;
  RETURN NULL;
END
$fn$;
REVOKE ALL ON FUNCTION booking.record_event() FROM PUBLIC;
DROP TRIGGER IF EXISTS b_80_event ON booking.bookings;
CREATE TRIGGER b_80_event AFTER INSERT OR UPDATE ON booking.bookings
  FOR EACH ROW EXECUTE FUNCTION booking.record_event();
DROP TRIGGER IF EXISTS bc_80_event ON booking.booking_contacts;
CREATE TRIGGER bc_80_event AFTER DELETE ON booking.booking_contacts
  FOR EACH ROW EXECUTE FUNCTION booking.record_event();
DROP TRIGGER IF EXISTS bn_80_event ON booking.booking_notes;
CREATE TRIGGER bn_80_event AFTER DELETE ON booking.booking_notes
  FOR EACH ROW EXECUTE FUNCTION booking.record_event();

CREATE OR REPLACE FUNCTION booking.events_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $fn$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM booking.bookings WHERE id = OLD.booking_id) THEN
    RETURN OLD;                                   -- only as a cascade of a deliberate purge
  END IF;
  RAISE EXCEPTION 'booking L23: booking_events is append-only — a correction is a new event' USING ERRCODE = 'check_violation';
END
$fn$;
DROP TRIGGER IF EXISTS be_10_append_only ON booking.booking_events;
CREATE TRIGGER be_10_append_only BEFORE UPDATE OR DELETE ON booking.booking_events
  FOR EACH ROW EXECUTE FUNCTION booking.events_append_only();

-- ───────────────────────────── 6. derivations
CREATE OR REPLACE VIEW booking.v_busy AS
SELECT br.resource_id, br.booking_id, b.business_id, b.status, b.during, br.blocked, br.zone_id
  FROM booking.booking_resources br
  JOIN booking.bookings b ON b.id = br.booking_id
 WHERE br.is_live
   AND NOT (b.status = 'held' AND b.hold_until <= now());
COMMENT ON VIEW booking.v_busy IS
  'The slot calculator''s input: every footprint that occupies a resource now. A lapsed hold is not busy even before it is marked expired.';

CREATE OR REPLACE VIEW booking.v_cancellation_terms AS
SELECT b.id AS booking_id,
       lower(b.during) - make_interval(hours => b.cancel_free_hours) AS free_until,
       CASE WHEN b.status = 'confirmed' THEN booking.late_fee_minor(b.price_minor, b.late_cancel_fee_bp) ELSE 0 END AS late_fee_minor,
       b.currency
  FROM booking.bookings b
 WHERE b.is_live;
COMMENT ON VIEW booking.v_cancellation_terms IS
  'What cancelling a live booking costs the customer: free until free_until, then late_fee_minor. A request not yet accepted is always free.';

CREATE OR REPLACE VIEW booking.v_retention AS
SELECT b.id AS booking_id, b.business_id, e.ended_at,
       e.ended_at + make_interval(days => z.note_retention_days)    AS note_due_at,
       e.ended_at + make_interval(days => z.contact_retention_days) AS contact_due_at,
       EXISTS (SELECT 1 FROM booking.booking_notes n    WHERE n.booking_id = b.id) AS has_note,
       EXISTS (SELECT 1 FROM booking.booking_contacts c WHERE c.booking_id = b.id) AS has_contact
  FROM booking.bookings b
  JOIN booking.businesses z ON z.id = b.business_id
 CROSS JOIN LATERAL (SELECT CASE WHEN b.status IN ('completed', 'no_show')
                                 THEN greatest(upper(b.during), b.closed_at)
                                 ELSE b.closed_at END AS ended_at) e
 WHERE NOT b.is_live;
COMMENT ON VIEW booking.v_retention IS
  'When the personal data of a closed booking falls due for erasure: a booking ends when its visit ends (completed, no_show) or when it closes without one (cancelled, declined, expired).';

CREATE OR REPLACE FUNCTION booking.erase_due_notes() RETURNS integer
LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH gone AS (
    DELETE FROM booking.booking_notes n USING booking.v_retention r
     WHERE r.booking_id = n.booking_id AND r.note_due_at <= now()
    RETURNING 1)
  SELECT count(*)::integer FROM gone
$$;
CREATE OR REPLACE FUNCTION booking.erase_due_contacts() RETURNS integer
LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH gone AS (
    DELETE FROM booking.booking_contacts c USING booking.v_retention r
     WHERE r.booking_id = c.booking_id AND r.contact_due_at <= now()
    RETURNING 1)
  SELECT count(*)::integer FROM gone
$$;
-- Runs as its owner (SECURITY DEFINER), so app_writer, the scheduler's role, prunes expired links
-- without holding DELETE on manage_links: with DELETE the booking path could erase a link that is
-- still valid instead of revoking it (revoked_at). One fixed statement, no parameters, search_path
-- pinned with pg_temp last, EXECUTE revoked from PUBLIC and granted to app_writer only (section 7).
CREATE OR REPLACE FUNCTION booking.prune_manage_links() RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  WITH gone AS (DELETE FROM booking.manage_links WHERE expires_at <= now() RETURNING 1)
  SELECT count(*)::integer FROM gone
$$;

-- L2's sweeper. The lazy path (5d) expires a lapsed hold only when its resource is linked again;
-- a hold nobody competes for would stay held and live, and its contact and note would never fall
-- due (v_retention reads closed bookings only). Call it from the scheduler before the erase
-- functions. It steps each lapsed hold to expired through the lifecycle, so it writes the same
-- status_changed event the lazy path writes. Returns how many holds it expired.
CREATE OR REPLACE FUNCTION booking.expire_lapsed_holds() RETURNS integer
LANGUAGE sql SET search_path = pg_catalog AS $$
  WITH gone AS (
    UPDATE booking.bookings SET status = 'expired'
     WHERE status = 'held' AND hold_until <= now()
    RETURNING 1)
  SELECT count(*)::integer FROM gone
$$;

-- ───────────────────────────── 7. grants — re-runnable; a restore without ACLs needs them again
REVOKE ALL ON FUNCTION booking.erase_due_notes(), booking.erase_due_contacts(), booking.prune_manage_links(),
                       booking.expire_lapsed_holds() FROM PUBLIC;
GRANT USAGE ON SCHEMA booking TO app_reader, app_writer, app_admin;
-- everyone who reads: configuration and bookings, no personal data
GRANT SELECT ON booking.businesses, booking.zones, booking.zone_travel, booking.services, booking.service_durations,
                booking.resources, booking.resource_services, booking.resource_weekly_hours, booking.resource_hours_exceptions,
                booking.note_consent_texts, booking.bookings, booking.booking_resources, booking.booking_events,
                booking.v_busy, booking.v_travel_gaps, booking.v_cancellation_terms, booking.v_retention
  TO app_reader, app_writer, app_admin;
-- the booking path (customer self-service and staff desk): bookings, links, personal data
GRANT INSERT, UPDATE ON booking.bookings TO app_writer;
GRANT INSERT, DELETE ON booking.booking_resources TO app_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON booking.booking_contacts TO app_writer;
GRANT SELECT, INSERT, DELETE ON booking.booking_notes TO app_writer;
GRANT SELECT, INSERT ON booking.manage_links TO app_writer;
GRANT UPDATE (revoked_at) ON booking.manage_links TO app_writer;
GRANT EXECUTE ON FUNCTION booking.erase_due_notes(), booking.erase_due_contacts(), booking.prune_manage_links(),
                          booking.expire_lapsed_holds() TO app_writer;
-- configuration
GRANT INSERT, UPDATE, DELETE ON booking.businesses, booking.zones, booking.zone_travel, booking.services, booking.service_durations,
                                booking.resources, booking.resource_services, booking.resource_weekly_hours, booking.resource_hours_exceptions
  TO app_admin;
GRANT INSERT, UPDATE ON booking.note_consent_texts TO app_admin;
