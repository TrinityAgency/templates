// booking-types.ts — the booking family's shared vocabulary, the part this template uses.
// Copied, never imported: compare VOCAB_VERSION when two booking templates meet.
export const VOCAB_VERSION = 1;

/** One place a visit can happen: the premises, or a service area of mobile visits. */
export interface Zone {
  id: string;
  name: string;
  isPremises: boolean;
}
