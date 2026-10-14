// booking-types.ts — the booking family's shared vocabulary, the part this template uses.
// Copied, never imported: compare VOCAB_VERSION when two booking templates meet.
export const VOCAB_VERSION = 1;

export type ConfirmationMode = 'instant' | 'request';
export type ServiceLocation = 'premises' | 'customer_site';
export type ResourceKind = 'staff' | 'room' | 'equipment';

/** Free until this many hours before the visit, then lateFeeBp basis points of the price (10000 = 100 %). */
export interface CancellationPolicy {
  freeUntilHoursBefore: number;
  lateFeeBp: number;
}

export interface Service {
  id: string;
  name: string;
  confirmation: ConfirmationMode;
  location: ServiceLocation;
  bufferBeforeMin: number;
  bufferAfterMin: number;
  resourcesRequired: number;
  policy: CancellationPolicy;
}

/** One bookable length of a service. Money is minor units plus an ISO 4217 code. */
export interface Duration {
  minutes: number;
  priceMinor: number;
  currency: string;
}

export interface Resource {
  id: string;
  kind: ResourceKind;
  name: string;
}

/** A bookable span: the visit itself (buffers not included), as ISO 8601 instants with an offset. */
export interface Slot {
  start: string;
  end: string;
  resourceIds: string[];
  zoneId: string;
}
