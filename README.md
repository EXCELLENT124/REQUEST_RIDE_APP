# Request Ride

A cross-platform Flutter and Supabase foundation for a South African ride-hailing service. It supports customer, approved car-driver, and admin roles; guarded ride state changes; configurable ZAR fare rules; private driver documents; and real-time ride tracking.

## Run locally

1. If platform folders are not present, run `flutter create --platforms=android,ios,web,windows --org za.co.requestride --project-name request_ride .` once. This preserves the existing `lib`, `test`, and `supabase` source.
2. Create a Supabase project and apply `supabase/migrations/0001_request_ride.sql`.
3. Promote the first administrator directly in the database: `update public.profiles set role = 'admin' where id = '<user id>';`. Never offer admin role during public registration.
4. A local ignored configuration is available in `config/local.json`. Run:

   `flutter run -d chrome --dart-define-from-file=config/local.json`

   On Windows, double-click `RUN_REQUEST_RIDE.bat`. The app includes the
   client-safe project URL and publishable key, so Windows and IDE launches do
   not require extra arguments.

5. The development map uses OpenStreetMap tiles. Configure a commercial tile provider or Google Maps/Mapbox with suitable production terms and API restrictions before public launch.

## Architecture

- `lib/src/domain`: provider-neutral business models.
- `lib/src/data`: Supabase authentication, RPC, and real-time streams.
- `lib/src/app.dart`: adaptive role routing and initial screens.
- `supabase/migrations`: schema, constraints, RLS, storage policies, RPCs, indexes, and Realtime publication.

## Production checklist

Implemented foundations now include server-calculated final fares, payment-method/status records, password recovery, profile and emergency-contact settings, deletion requests, safety incidents, privacy consent, ratings, cancellation reasons, and trip receipts.

Testing legal drafts are in `docs/PRIVACY_POLICY.md` and `docs/TERMS_OF_SERVICE.md`.

Add `io.supabase.flutter://reset-callback/` to Supabase Authentication → URL Configuration → Redirect URLs so password-recovery emails return to the installed app.

- Replace the sample launch fare with rates approved by the business; it is illustrative and does not reproduce Uber/Bolt pricing.
- Add phone verification, password recovery, push token registration, and a server-side notification worker.
- Add background location permissions/disclosures per Apple, Google Play, and Microsoft policies.
- Move high-frequency tracking to private Supabase Broadcast channels at scale; persist sampled points for audit/history.
- Add an external routing provider for road distance, ETA, geocoding, and route polylines. Never trust distance supplied by a client when calculating a final fare.
- Connect a PCI-compliant South African payment provider for card authorization/capture; never collect raw card details directly.
- Arrange a staffed safety escalation process and emergency-service guidance; the in-app SOS currently alerts administrators and provides 112 calling.
- Obtain legal review of the testing privacy/terms drafts, define POPIA retention periods, and process deletion requests using a protected server-side worker.
- Configure custom SMTP, production Auth redirect/deep links, crash reporting, uptime alerts, backups, Android/iOS signing, and store disclosures before launch.
