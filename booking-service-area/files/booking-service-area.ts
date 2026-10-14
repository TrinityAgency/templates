// booking-service-area.ts — which zone an address falls in, or that it is outside every zone.
// Pure and deterministic: no I/O, no network. Postcodes and localities are matched against your lists;
// for radius or polygon areas, pass a point from your own geocoder. Never throws: nonsense input returns
// { outside: true, reason: 'invalid_input' }, a malformed area list or matcher { outside: true, reason: 'invalid_config' }.
import type { Zone } from './booking-types';

export interface Point {
  lat: number;
  lng: number;
}

/** What the customer gave: any of a postcode, a locality, a point. */
export interface AreaInput {
  postcode?: string | null;
  locality?: string | null;
  point?: Point | null;
}

/**
 * A zone and the area it covers. Postcode patterns: an exact code ('1190'), a prefix ('22*') or an
 * inclusive range of equal-length digit codes ('1200..1219'). Spaces, hyphens and case are ignored.
 * Localities match whole, ignoring case, accents and punctuation. Geometry is optional; null means none,
 * as a table row hands it over.
 */
export interface ServiceArea extends Zone {
  postcodes?: string[] | null;
  localities?: string[] | null;
  /** a disc: centre and radius in kilometres (the edge counts as inside) */
  circle?: { lat: number; lng: number; km: number } | null;
  /** a polygon of [lat, lng] corners, at least three, not crossing the antimeridian (the edge counts as inside) */
  polygon?: [number, number][] | null;
}

/** Does this input fall in this area? */
export type Matcher = (input: AreaInput, area: ServiceArea) => boolean;

/**
 * no_match: no area covers the input. invalid_input: the customer gave nothing usable.
 * invalid_config: your area list or matcher is malformed (or a matcher threw); no customer can fix that.
 */
export type ZoneResult = { zoneId: string } | { outside: true; reason: 'no_match' | 'invalid_input' | 'invalid_config' };

// ───────────────────────────── normalising

/** A postcode as compared: upper case, without spaces and hyphens. */
export function normalisePostcode(s: string): string {
  return s.toUpperCase().replace(/[\s-]+/g, '');
}

/** A locality as compared: lower case, accents removed, every run of punctuation or space one space. */
export function normaliseLocality(s: string): string {
  return s.normalize('NFKD').replace(/\p{M}+/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function postcodeMatches(pattern: string, code: string): boolean {
  const p = normalisePostcode(pattern);
  const range = /^(\d+)\.\.(\d+)$/.exec(p);
  if (range) {
    const [, lo = '', hi = ''] = range;
    return code.length === lo.length && /^\d+$/.test(code) && code >= lo && code <= hi;
  }
  if (p.endsWith('*')) return code.startsWith(p.slice(0, -1));
  return code === p;
}

// ───────────────────────────── matchers

/** The input's postcode is in the area's list. */
export const byPostcode: Matcher = (input, area) => {
  const code = typeof input.postcode === 'string' ? normalisePostcode(input.postcode) : '';
  return code !== '' && (area.postcodes ?? []).some((p) => postcodeMatches(p, code));
};

/** The input's locality is in the area's list. */
export const byLocality: Matcher = (input, area) => {
  const name = typeof input.locality === 'string' ? normaliseLocality(input.locality) : '';
  return name !== '' && (area.localities ?? []).some((l) => normaliseLocality(l) === name);
};

const EARTH_KM = 6371.0088;
const rad = (deg: number) => (deg * Math.PI) / 180;

/** Great-circle distance in kilometres (haversine). */
export function distanceKm(a: Point, b: Point): number {
  const h = Math.sin(rad(b.lat - a.lat) / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lng - a.lng) / 2) ** 2;
  return 2 * EARTH_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** The input's point lies in the area's circle. */
export const byCircle: Matcher = (input, area) =>
  !!input.point && !!area.circle && distanceKm(area.circle, input.point) <= area.circle.km;

function onSegment(y: number, x: number, [y1, x1]: [number, number], [y2, x2]: [number, number]): boolean {
  const cross = (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1);
  return Math.abs(cross) <= 1e-12 && x >= Math.min(x1, x2) && x <= Math.max(x1, x2) && y >= Math.min(y1, y2) && y <= Math.max(y1, y2);
}

/** The input's point lies in the area's polygon (ray casting on lat/lng; the edge counts as inside). */
export const byPolygon: Matcher = (input, area) => {
  const poly = area.polygon;
  if (!input.point || !poly) return false;
  const { lat: y, lng: x } = input.point;
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i]!;
    const b = poly[j]!;
    if (onSegment(y, x, a, b)) return true;
    if (a[0] > y !== b[0] > y && x < ((b[1] - a[1]) * (y - a[0])) / (b[0] - a[0]) + a[1]) inside = !inside;
  }
  return inside;
};

/** The default: postcodes first, then localities. */
export const DEFAULT_MATCHERS: readonly Matcher[] = [byPostcode, byLocality];

// ───────────────────────────── validation

const isNum = (n: unknown, lo: number, hi: number): n is number => typeof n === 'number' && Number.isFinite(n) && n >= lo && n <= hi;
const isPoint = (p: unknown): boolean => !!p && typeof p === 'object' && isNum((p as Point).lat, -90, 90) && isNum((p as Point).lng, -180, 180);

function validPattern(s: unknown): boolean {
  if (typeof s !== 'string') return false;
  // '1200-1219' is a range written the usual way, not a code: refuse it rather than let it match nothing
  const hyphenRange = /^\s*(\d{3,})\s*-\s*(\d{3,})\s*$/.exec(s);
  if (hyphenRange && hyphenRange[1]!.length === hyphenRange[2]!.length) return false;
  const p = normalisePostcode(s);
  const range = /^(\d+)\.\.(\d+)$/.exec(p);
  if (range) return range[1]!.length === range[2]!.length && range[1]! <= range[2]!;
  return /^[A-Z0-9]+\*?$/.test(p);
}

function validArea(a: ServiceArea): boolean {
  if (!a || typeof a !== 'object' || typeof a.id !== 'string' || a.id === '') return false;
  if (a.postcodes != null && (!Array.isArray(a.postcodes) || !a.postcodes.every(validPattern))) return false;
  if (a.localities != null && (!Array.isArray(a.localities) || !a.localities.every((l) => typeof l === 'string' && normaliseLocality(l) !== ''))) return false;
  if (a.circle != null && (!isPoint(a.circle) || !isNum(a.circle.km, Number.MIN_VALUE, 20_000))) return false;
  if (a.polygon != null && (!Array.isArray(a.polygon) || a.polygon.length < 3 ||
      !a.polygon.every((c) => Array.isArray(c) && c.length === 2 && isPoint({ lat: c[0], lng: c[1] })))) return false;
  return true;
}

function validInput(i: AreaInput): boolean {
  if (!i || typeof i !== 'object') return false;
  if (i.point != null && !isPoint(i.point)) return false;
  const code = typeof i.postcode === 'string' ? normalisePostcode(i.postcode) : '';
  const name = typeof i.locality === 'string' ? normaliseLocality(i.locality) : '';
  return code !== '' || name !== '' || i.point != null;
}

// ───────────────────────────── the resolver

/**
 * The zone an input falls in. Matchers run as passes, in order: the first pass that matches any area
 * decides, and within a pass the first area in your order wins. Default: postcodes, then localities.
 */
export function resolveZone(input: AreaInput, areas: ServiceArea[], matcher: Matcher | readonly Matcher[] = DEFAULT_MATCHERS): ZoneResult {
  try {
    if (!Array.isArray(areas) || !areas.every(validArea)) return { outside: true, reason: 'invalid_config' };
    const passes = typeof matcher === 'function' ? [matcher] : matcher;
    if (!Array.isArray(passes) || !passes.every((m) => typeof m === 'function')) return { outside: true, reason: 'invalid_config' };
    if (!validInput(input)) return { outside: true, reason: 'invalid_input' };
    for (const pass of passes) {
      const hit = areas.find((area) => pass(input, area));
      if (hit) return { zoneId: hit.id };
    }
    return { outside: true, reason: 'no_match' };
  } catch {
    return { outside: true, reason: 'invalid_config' };
  }
}
