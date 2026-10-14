// booking-types.ts — the booking family's shared vocabulary, the part this template uses.
// Copied, never imported: compare VOCAB_VERSION when two booking templates meet.
export const VOCAB_VERSION = 1;

export type BookingStatus = 'held' | 'confirmed' | 'completed' | 'no_show' | 'cancelled' | 'declined' | 'expired';
export type CancellingParty = 'customer' | 'business';

/** Free until this many hours before the visit, then lateFeeBp basis points of the price (10000 = 100 %). */
export interface CancellationPolicy {
  freeUntilHoursBefore: number;
  lateFeeBp: number;
}
