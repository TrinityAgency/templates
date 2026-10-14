# booking-service-area

Which zone a customer's address falls in, or that it is outside every zone. Answer it before you
compute slots for a home visit. Pure TypeScript: no dependencies, no network. It never throws:
nonsense input returns `{ outside: true, reason: 'invalid_input' }`, and a malformed area list
`{ outside: true, reason: 'invalid_config' }`.

```ts
import { resolveZone, type ServiceArea } from '@/utils/booking-service-area/booking-service-area';

const areas: ServiceArea[] = [
  { id: 'zone-north', name: 'North', isPremises: false, postcodes: ['1190', '1200..1219', '22*'], localities: ['Döbling'] },
  { id: 'zone-south', name: 'South', isPremises: false, postcodes: ['1100', '1230'], localities: ['Mödling'] },
];

resolveZone({ postcode: '1205' }, areas);          // { zoneId: 'zone-north' }
resolveZone({ locality: 'MODLING' }, areas);       // { zoneId: 'zone-south' }
resolveZone({ postcode: '9999' }, areas);          // { outside: true, reason: 'no_match' }
```

## Patterns

- **Postcodes:** an exact code (`'1190'`), a prefix (`'22*'`) or an inclusive range of equal-length digit
  codes (`'1200..1219'`). Spaces, hyphens and case are ignored on both sides: `'SW1A 1AA'` matches
  `'sw1a1aa'`, and `'00-950'` matches `'00950'`. A range only compares codes of its own length.
- **Write ranges with `..`.** `'1200-1219'` (two digit groups of equal length joined by a hyphen) is
  refused as `invalid_config`, because it would otherwise read as the single code `12001219`.
- **A country prefix does not match.** `'A-1190'` or `'D-80331'` is not `'1190'` or `'80331'`: prefixes
  cannot be stripped safely (UK postcodes start with letters). Strip it in your form, or list the variant.
- **Localities** match whole, ignoring case, accents and punctuation: `'St. Pölten'` matches
  `'st polten'`. `'Döblinger Hauptstraße'` does not match `'Döbling'`. List spelling variants yourself
  (`'Paphos'`, `'Pafos'`).

## Which zone wins

Matchers run as passes, in order. The first pass that matches any area decides, and within a pass the
first area in your order wins. The default is postcodes, then localities, so an exact postcode beats a
locality listed in an earlier zone, and an unlisted postcode falls back to the locality.

## Radius and polygon areas

Give an area a `circle` (`{ lat, lng, km }`) or a `polygon` (`[lat, lng]` corners) and pass a `point`
from your own geocoder. This template never calls one. Choose the passes:

```ts
import { byCircle, byPolygon, byPostcode, byLocality } from '@/utils/booking-service-area/booking-service-area';

resolveZone({ postcode, locality, point }, areas, [byPolygon, byCircle, byPostcode, byLocality]);
```

The edge of a circle or polygon counts as inside. Polygons are read on the lat/lng plane: fine for a
city or a region, but not for areas crossing the antimeridian. `distanceKm(a, b)` is exported too.

## Answers

| Answer | Meaning |
|---|---|
| `{ zoneId }` | The zone of the visit. Pass it to the slot calculator and store it on the booking |
| `{ outside: true, reason: 'no_match' }` | No area matched: show your area list, or a phone fallback |
| `{ outside: true, reason: 'invalid_input' }` | The customer gave nothing to match (no postcode, locality or point), or a malformed point: ask again |
| `{ outside: true, reason: 'invalid_config' }` | Your area list is malformed (a bad pattern, an empty locality, a non-string id, geometry that is not numbers) or a matcher threw. One bad area fails every lookup, so log it and fix the list; the customer cannot |

Rows from a table: `NULL` lists and geometry mean none. A `numeric` column arrives from most drivers as a
string, so convert coordinates and radii with `Number()` before you pass them in.

## With the booking-schema template

`zoneId` is a `booking.zones.id`. The schema stores zones and travel times, not their postcodes, so keep
the patterns in your configuration or in a table of your own. Any zone can be an area, the premises zone
included, when you also visit its neighbours at home.

`booking-types.ts` is this template's copy of the booking vocabulary (`VOCAB_VERSION = 1`). Other
booking templates ship their own copy. Compare the version numbers when you combine them.
