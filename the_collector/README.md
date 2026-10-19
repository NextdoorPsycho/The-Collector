# The Collector

Use Flutter 3.47.7 or newer, with Dart 3.13. The app depends on the local `magic_card`, `collector_models`, and `vendor/arcane` packages.

This workspace has Flutter 3.47.7 installed at `~/Developer/flutter`. Select it for your shell:

```sh
export PATH="$HOME/Developer/flutter/bin:$PATH"
```

Install dependencies from the repository root:

```sh
(cd collector_models && dart pub get)
(cd magic_card && flutter pub get)
(cd the_collector && flutter pub get)
```

Generate model serializers and run their tests:

```sh
cd collector_models
dart run build_runner build
dart analyze
dart test
```

Model generation runs in its own package because Arcane's transitive builders require incompatible analyzer versions.

Direct app dependencies and the vendored Arcane runtime use the latest compatible releases. Six transitive packages remain below their newest published version because Flutter or upstream plugins constrain them: cli_util, cross_file, equatable, material_color_utilities, test_api, and xml. The unused code-highlighting and native clipboard dependency chain has been removed. Do not force them with dependency overrides; their upstream packages need coordinated API updates.

Check and build the app:

```sh
cd the_collector
flutter analyze
flutter build web
flutter build apk --debug
flutter build ios --debug --no-codesign
```

Android requires API 24 or newer. iOS requires 15.5 or newer.

iOS plugins use Swift Package Manager. CocoaPods integration has been removed from the iOS project; retain the generated Swift package and the Runner scheme's Flutter preparation pre-action. See the [Flutter Swift Package Manager guide](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers).

## Firebase authentication

Firebase project `the-collector-app` enables email/password and Google authentication. Web authentication uses the Firebase Google popup. Apple and Android authentication use the native Google sign-in SDK.

Both Apple targets use bundle ID `com.volmit.collector`, registered in Firebase project `the-collector-app`. The bundled `GoogleService-Info.plist`, `lib/firebase_options.dart`, Google client ID, callback URL scheme, and Keychain Sharing capability are aligned. Update them together if the Firebase app registration changes.

Use an Apple Development certificate for native authentication. Google sign-in on macOS requires an Apple-issued signing certificate. Open `macos/Runner.xcworkspace` and select your team in the Runner target. Rebuild and restart the app after configuring signing and Keychain Sharing.

To run on an iPhone:

1. Connect and unlock the iPhone.
2. Enable Settings > Privacy & Security > Developer Mode on the phone.
3. Restart the phone and confirm Developer Mode.
4. Open `ios/Runner.xcworkspace` in Xcode.
5. Select your team under Runner > Signing & Capabilities, with automatic signing enabled.
6. Select the connected iPhone as the run destination.

After you configure signing, use `flutter devices` and `flutter run -d <device-id>`. The unsigned iOS build command above checks compilation only. It cannot install an app on a phone.

For an installed iPhone app that opens from its icon without Flutter or Xcode attached, build `flutter build ios --release --target lib/main.dart` and install the signed `build/ios/iphoneos/Runner.app`. A debug build requires a tooling-assisted launch on physical iOS devices. Update the existing installation without uninstalling it to preserve account data and permissions.

Native Google sign-in supplies the configured web OAuth client ID to the Google SDK. Android also requires a Firebase registration matching `art.arcane.the_collector` and the signing certificate's SHA-1. The bundled Android registration still names `com.example.model_app`, and the audit found no registered fingerprints. Get the development fingerprint with `(cd android && ./gradlew signingReport)`. Register the correct package and fingerprint, then download the updated `google-services.json`. Release signing certificates need their own registrations.

Android release signing reads a private `android/key.properties`:

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

Relative keystore paths resolve from `android/`. Properties and keystore files are ignored by Git. Without this configuration, release output is unsigned and must be signed before installation or publication. Register the production app-signing certificate with Firebase for Google sign-in.

See the official [Flutter iPhone setup](https://docs.flutter.dev/platform-integration/ios/setup) and [Google Apple SDK setup](https://developers.google.com/identity/sign-in/ios/start-integrating).

## Release requirements

Android still needs the matching Firebase package and certificate registration described above. Release output requires a private signing key; there is no debug-key fallback.

App Store distribution still needs an equivalent private-email login option and an accessible published privacy policy. In-app account deletion is implemented locally but remains disabled until the backend and rules are deployed. See [Apple’s login and privacy requirements](https://developer.apple.com/app-store/review/guidelines/#login-services). Apple sign-in is implemented with the Firebase SDK and remains hidden until enabled with `--dart-define=APPLE_SIGN_IN_ENABLED=true`. Its monochrome button uses the unmodified logo artwork from [Apple’s button endpoint](https://developer.apple.com/documentation/signinwithapplerestapi/get-a-sign-in-with-apple-button-that-contains-just-the-apple-logo.). It requests email only and uses the native provider on iOS/macOS or a popup on web. A read-only production check on October 10, 2026 confirmed that Firebase already enables the Apple provider. The provider has no Service ID or OAuth code-flow configuration. Configure Sign in with Apple on the distribution team and add the matching app entitlement before enabling the build flag. Web sign-in and authorization-code revocation also require the Apple Service ID, team ID, key ID, and private-key configuration in Firebase. Personal Team development builds keep their existing entitlements. See the [Firebase Apple setup](https://firebase.google.com/docs/auth/flutter/federated-auth#apple). The local deletion backend removes nested Firestore data, owned Storage objects, and shared-game memberships before deleting Auth. See `../functions/README.md` for tested behavior and the separately authorized deployment steps.

Apple account deletion uses native authorization-code revocation on iOS/macOS and Apple access-token revocation on web. The web request uses Firebase's public API key and the same account's refreshed ID token. Missing credentials, linked providers verified through another method, and revocation failures show manual Apple access-removal instructions before a second deletion confirmation. The user can retry verification or continue deleting app data. See [Apple's missing-token guidance](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple) and [Firebase web revocation](https://firebase.google.com/docs/auth/web/apple#token_revocation).

Simulator tests verify native recognition against image fixtures and the actual collection, deck, dice, life, preferences, and rules flows. They do not verify camera focus, glare, sleeves, or sustained physical scanning throughput. Storage rule changes have passed local emulator tests but have not been deployed.

## Firebase rules tests

The repository contains Firestore and Storage rules. Collections, decks, ingestion receipts, and price observations stay private to their owner. Administrators can list profiles and manage other users' administrator permissions; they cannot read another user's private collection or change their own permission. Shared games use an unlisted random invitation code and allow joined players to update life totals and names. Existing Storage `public` and `decks` folders allow public reads. The app does not use Storage.

From the repository root, run the local rules tests with Node 24.12 or newer and the Firebase CLI:

```sh
npm --prefix firebase_tests ci
firebase emulators:exec --project demo-the-collector --only firestore,storage 'npm --prefix firebase_tests test'
```

The tests use demo projects on loopback ports 18080 and 19199. They cover owner access, isolation, immutable ingestion receipts, role protection, shared games, and public/private Storage access.

Production Firestore uses the approved receipt and shared-game rules. The account-deletion guards and Storage rule changes still require separate deployment.

## Collection and scanning

The app restores the original inverted triangle, typewriter text, labeled navigation, and launcher artwork using Arcane. Email registration includes password confirmation; password reset has its own screen. Google sign-in remains available.

Collection search filters name, type, set, color, rarity, and finish. Manual entry reviews the exact printing, language, finish, and quantity before saving. Deck entries keep their own quantities and sections; changing a deck does not change inventory. Deck checks report size, copy-limit, color-identity, and card-legality issues; advanced Commander combinations still require the applicable rules.

On iPhone, Scan uses Apple Vision to find up to eight cards per photo, correct perspective, and read text on-device. Detection uses a smaller image. Card crops and footer OCR use the original photo. Exact printing lookup uses the observed set code and collector number before name or artwork matching. A number without a set does not establish a printing. Conflicting names, numbers, or languages prevent automatic approval.

The camera shows the full sensor frame and requests JPEG quality 95. iOS selects the largest supported photo size at or below 12.6 megapixels when available. This limits capture and decoding cost without changing the active lens or preview geometry. Physical timing for this resolution change still needs measurement.

Capture, detailed OCR, and printing lookup run as separate bounded jobs. Original photos and captured regions remain in account-specific local storage until removal or a completed addition. Crop readers use two native workers. A slow card lookup does not delay a successful neighboring result. Admission pauses when the pending-work or 512 MiB image budget is full. Existing captures remain available.

The bundled catalog contains printing metadata and artwork references for offline matching. Only physical printings appear in scanner results. Text, collector numbers, and artwork supply separate evidence. Artwork similarity can suggest a card without approving its printing. Remote lookup can supplement the catalog, but a failed request does not discard a capture. The optional cloud text reader is disabled by default.

Captured cards appear in a drawer over the live camera. Add the suggested printing directly, or expand the drawer to choose a printing and finish, retry recognition, or remove a capture. Normal is the default when supported. The camera stays open, and editing a card pauses automatic addition for that card. “Next card” means useful capture evidence is safely retained and the physical card can move; “Added” means its addition is durably queued for the selected destination, with ten seconds to Undo. Reading and unmatched captures cannot be added until a valid printing is available.

A card in an unread photo's unchanged physical region waits for that photo's crop result before another automatic capture can include it. Cards in separate regions can capture while the earlier photo is still processing; protected regions remain excluded from the new photo's review items. If a completed photo omits a live-proven card, the camera can refocus that same still-visible card and take a targeted follow-up photo, retaining the other cards' saved regions. Recovery handles one missing card at a time and allows at most two follow-ups per unchanged physical card. An existing crop, even with unreadable text, goes to printing review rather than adding another copy through automatic recapture. Stale geometry, replacement cards, failed photo reads, and storage errors cannot trigger this recovery.

Saved-region exclusion also handles modest, centered crop expansion after border repair, while keeping adjacent cards separate. Frozen capture geometry retains the largest actual observed outline when multiple detections cover the same card. Illustrator credits remain footer evidence even when perspective raises them into the rules region. A verified historical body can identify one card when rules keywords, type, illustrator, and copyright year agree across a complete candidate list; its printing still needs review. That verified identity stays with the draft when the compact review keeps only three printing choices. Incomplete searches do not establish this proof. Native partial-card recovery can retain an actually observed full title when the overview omitted one leading letter, but only with a matching type and two independently readable body rows. A subsequent native tracking result must reach 0.85 confidence before its partial outline can support capture.

Saved multi-card recognition can repair a clipped title or footer within a bounded card footprint, preserving the crop warning and rejecting expansion into a neighboring card. Literal historical types such as Enchant Creature are recognized. A tiny uniformly bright, textless region is discarded only when multiple readable card regions independently establish the scene. Weak footer reads stay out of exact lookup and confirmation; conflicting reliable set, language, or number reads withhold those hints. Bounded fuzzy-title and rules searches retrieve the complete printing list rather than keeping only one representative set.

When a verified saved crop has a strong observed title, matching type and rules, but a blurred multi-digit footer, a unique one-digit number difference can order a review suggestion. This requires a complete single-identity printing list sharing one set and one known illustration. Multiple close numbers, valid observed alternatives, reliable footer conflicts, or different artwork prevent it. The original OCR remains unchanged, the similarity adds no confidence score, and the printing cannot be approved as exact. A corroborated parenthesized energy-counter description can distinguish repeated OCR digits for energy symbols from genuine gameplay quantities.

Manual and explicitly configured stationary capture can refocus across up to five unprocessed card positions. These photos form one durable scene; recognition keeps the strongest crop at each physical card position so focus passes do not add duplicate quantities. Current card evidence and recent strong text proof guide focus; already saved positions are excluded. Automatic focus uses detected card positions, and overlapping detections share one focus pass. Live tracking probes additional focus regions. If a confirmed card stays blurred at the Wide lens’s nearest focus limit, it can try Ultra-wide once before the first capture; manual lens selection takes precedence. After capture ownership is established, automatic focus keeps the same physical lens so reopening the camera cannot erase duplicate protection. Choose Wide, Ultra-wide, or Telephoto when the device exposes those rear lenses. Tap the preview to focus and expose; use focus lock, zoom, exposure compensation, and torch controls when supported. Visible titles, rules text, and collector-number footers help identify partially obscured cards. Hidden identifiers can still require recapture or manual printing selection.

New unprocessed focus regions get one immediate probe after two observations over at least 400 ms. Existing per-region budgets prevent jitter from retriggering that probe; the four-second timer remains available for a bounded follow-up. Capture readiness, manual focus, pause, controls, and unsaved photos take precedence.

When a completed owned photo contains an unreadable crop that was discarded from review, that same still-visible physical region can receive two additional focus probes. The raw geometry history is immutable and bounded; selected review items, saved cards, unread photos, stale geometry, and foreign regions cannot grant recovery. Each region receives this allowance once, independently of other cards in the photo. Refocusing alone never triggers a shutter: fresh strong card evidence must still satisfy automatic capture admission.

iPhone focus points use the effective preview orientation, including when a mount leaves the phone facing up or down. Stationary focus-stack shots acquire one-shot autofocus and wait for the lens to settle. Sweep discovery and recovery keep autofocus continuous as the phone moves. Before an outline-only shutter, an active discovery focus request must finish and fresh geometry must still match the current camera. A blurry, unowned card at the Wide lens's nearest focus limit can trigger one Ultra-wide trial before capture. Manual lens selection, focus lock, and existing capture ownership prevent that automatic switch.

Stationary iPhone focus checks run every 100ms and require three consecutive stable lens and exposure observations. Sweep recovery uses a shorter settling budget and requires stable focus without waiting for continuous exposure adjustment. Fresh readable cards can capture after the existing two-frame evidence gate without an extra dwell or focus pass while catalog lookup runs. Retained unread targets can still receive bounded focus recovery. Verified live identities can continue without another focus pass or photo. Recent proven card positions can guide remaining focus passes when a full contour disappears. Those positions cannot mark a card as saved.

Automatic glare compensation samples the title and footer of complete detected cards, excluding their artwork. Repeated clipped, washed-out readings can lower exposure in small steps, bounded to 1.5 EV below neutral; sustained normal, dark, or empty scenes restore it gradually. Already capture-ready cards retain the fast path. Manual exposure takes precedence through camera pause and resume. Automatic camera commands have a 400ms shutter gate; failure or timeout disables further automatic exposure attempts for that camera. Native OCR can make one targeted contrast-stretched read of a washed-out title or footer, while preserving the original image and literal OCR rows. Contradictory title reads remain uncertain. Fully clipped text cannot be recovered by contrast correction.

Saved-photo identification can recover a missing marker only for its own acknowledged capture, matching identity evidence, and fresh, uniquely associated geometry. Outline-only captures also require strong live OCR from a frame whose analysis started after the local save acknowledgement. Geometry or a saved crop alone cannot turn an unread live card green. Small rules-panel outlines also need current matching type and rules text. A new capture does not invalidate other owned acknowledgements still waiting for recognition. Scene resets, observed removals or replacements, and conflicting card evidence invalidate the affected binding.

Scan matching excludes duplicate OCR observations over a confidently parsed type line from rules searches. Short overlapping fragments of recognized flavor text cannot invent contradictory rules.

When live OCR reads a literal card self-reference in the rules, a bounded printing lookup can recover its identity without a visible title. This requires three independent gameplay rows, a matching type, actual illustrator and copyright evidence, and one supported canonical card across a complete catalog response. The observed title list remains empty, and no title-match or exact-printing evidence is invented. Quoted flavor text, alternative-only text, conflicting metadata, incomplete searches, and mixed card regions cannot establish this identity.

Late catalog responses retain the geometry where strong text was actually read. They cannot attach old text to a smaller later outline. An already acknowledged outline can match a larger saved crop only with tightly aligned, contained geometry, the same type, and at least two distinctive rules lines. Those lines must match exactly unless the independently observed full names match, which permits one OCR character error per line. Conflicting colors, footers, or ambiguous overlapping targets reject the match. Title matching prefers the leftmost nameplate over nearby symbol text. An acknowledged card can remain tracked through a clipped title only when a long matching title prefix and two independent rules prefixes corroborate it; that preservation cannot create a receipt or identify a new card.

Stable native card contours can trigger a photo before text is readable. This path saves one photo for background matching and keeps a yellow pane over the retained region while that card remains present. Background matching can identify retained cards for review while the live pane waits for corroboration.

Automatic outline capture prioritizes its first two accepted geometry observations before live OCR. Geometry admission runs at a 100ms minimum interval, with an independent 400ms text admission limit and the existing one-second text schedule. Later unstable contours can defer due OCR for at most two accepted geometry frames. One live analysis runs at a time, so a busy OCR request can still delay later geometry. Metadata resolution uses two workers, each processing at most two crops concurrently. Saved-photo card crops use two bounded native workers; live tracking retains its own serial lane.

Green and the capture sound mean the app has retained useful evidence for that physical card. They do not confirm its printing. A saved crop must pass framing and readable-content checks before it can acknowledge an otherwise unidentified card. Rectangle geometry or a saved file alone is insufficient. Capture feedback retains its physical-region ownership checks and a sound grace period.

Coarse 8×12 appearance samples can collide between different cards. Appearance changes can reject or retire a receipt, but appearance similarity cannot prove card identity. Saved multi-card photos also receive a bounded OCR pass outside complete card outlines. A visible title, parsed type, and following rules text can recover a card whose border is clipped. These partial crops always require printing review. Lens, torch, focus lock, and adjustments sit in one compact control row, with zoom and exposure sliders shown on demand.

The preview places one uniform pane over each detected card. White means detected, yellow means processing the capture, and green means safe to move. The app preserves the pane's perspective through short occlusions. There are no floating card numbers or names. Screen-reader labels describe the capture state. Tap to focus. Lens, torch, focus lock, zoom, and exposure remain available in camera controls.

On iPhone, separate serial native queues allow live text and tracking to continue alongside saved-photo OCR. Busy live analysis drops new frames instead of accumulating a backlog. On iOS 16 or later, the local camera fork limits analysis buffer edges to 1920 pixels. It delivers at most 10 FPS before copying pixels into Flutter. Preview updates and maximum still-photo dimensions remain intact.

A green pane retires after three seconds. Its physical receipt remains in a bounded local set to prevent repeat capture. Completed regions usually skip OCR, and all saved regions skip focus. Each accepted text frame exposes one rotating completed region when the current ROI mask would cover all owners. If the ROI budget already leaves owners unmasked, its existing fair rotation supplies those reads without another extra region. Conflicting OCR can therefore release a replaced card even when its appearance sample resembles the previous card.

Appearance comparisons use fixed receipt polygons so focus-related contour jitter cannot compare unrelated image areas. Observed removal or replacement releases that position for another card, including an identical copy after an observed removal. Pending receipts preserve the actual durable acknowledgement while lookup is slow. The new raw-capture confirmation and completed-region verification gates still require physical camera validation.

Live text lookup is throttled and cached. Name, rules text, type, set, collector number, and language guide matching; high-resolution photos provide optional evidence and local diagnostic references. Ambiguous photos can also compare artwork and expansion symbols with cached Scryfall references. Visual similarity never confirms a printing by itself, and clean exact text matches skip those comparisons. Identified-card paging and printing review show catalog artwork, with no captured-photo comparison or original-photo panel. Android live geometry uses experimental border detection; iPhone uses Vision rectangles.

A footer lookup that contradicts the observed name or rules now searches that identity instead of displaying the unrelated footer card. The original set and collector-number conflicts remain visible, and recovered printing suggestions require review. Explicit user corrections remain authoritative. Printing searches coalesce identical requests and cache immutable results for 15 minutes, bounded to 64 queries and 2,048 cards per catalog. Query options and paging stay distinct; failed requests remain retryable. Shared Scryfall request pacing and backoff remain unchanged. Default builds perform image analysis locally and retrieve reference metadata and images from Scryfall; Firebase image inference remains disabled.

Camera Review opens the printing panes directly. Tapping the artwork flips it to the initial suggestion, actual matching and conflicting evidence, rank score, visual distances and confidence status. Ranking points are not probability percentages, and the initial suggestion remains visible after choosing another printing. Keyboard activation and reduced motion are supported.

Text-supported automatic capture persists unresolved card observations before attempting a diagnostic photo or waiting for catalog lookup. Identification continues after the card leaves view. Stable physical receipt IDs survive restart and merge later photo evidence into the same quantity. Refocusing an unread target binds the new photo to its original receipt instead of adding another quantity. Outline-only capture saves the original photo for the ordinary background reader without inventing an identity; failed saving preserves the original for retry. Storage failure stops admission and retries the original receipt; unresolved persistence cannot turn a pane green. Yellow and green panes use stronger uniform fills so captured cards remain visible against the camera preview.

An optional cloud transcription fallback is available behind `CLOUD_CARD_HINTS_ENABLED=true`. It sends a bounded saved card crop to the authenticated, App Check protected `suggestCardHints` callable and checks returned names and printing identifiers against Scryfall. Cloud suggestions remain uncalibrated review candidates with zero ranking weight; they cannot establish exact-print confidence or approve a card. Default builds send no images to this service. Cloud-enabled builds also require explicit per-account permission in Settings, which starts off. Revocation, sign-out, account changes, and account deletion invalidate pending suggestions; local deletion removes the saved permission. Model configuration, provider registration and deployment remain operator steps described in [the backend README](../functions/README.md). This pilot does not include an all-card artwork index or a trained printing classifier.

Manual additions and scan review support Collection, decks, binders, boxes, folders and lists. Each group offers Scan cards, and new groups offer Create and scan. Scanning from a group locks that destination; the final explicit printing confirmation saves the reviewed batch to the local upload queue and returns to the group without another Add step. Cancellation retains drafts without committing the batch. Group additions also update the collection inventory atomically with the same operation receipt. Only decks offer deck sections.

When older printed rules differ from Oracle wording, matching can make one bounded keyword search using four observed words across two readable rules lines. Broad results are rejected; close title agreement can rank candidates, but these results require printing review. Distinctive body-only crops remain available for review when the title or type is unreadable. A bounded still-photo border repair can recover a clipped title only when the recovered title, type, and rules agree with the original crop. Partial proposals cannot pair a title with another card's type across an observed footer.

Tracking retains at most eight candidates. Unreadable background detections cannot displace recently proven cards or saved receipts. A captured text-panel outline can regain its full-card footprint only when that capture's unique strong proof, the identified saved photo, and fresh full-card text agree. Saved identification survives unreadable live text; a conflicting title, type, language, set, or collector number clears it. Small OCR title differences require independent matching rules and type; larger per-word differences additionally require a nearly identical footprint and the same observed color.

The camera warms a compact public Scryfall card-name index while it opens. Names cache for 24 hours and are indexed off the UI isolate. Unique bounded OCR corrections can search the complete printing list directly, while ambiguous or failed index lookups use the existing catalog flow. Original OCR remains unchanged and corrections require review. Artwork and symbol reference loading overlaps with four global load slots and two comparison slots. The next reference pair downloads during current comparisons; admitted work drains before active cache files release.

Saved multi-card photos first read at most two padded card regions concurrently. Each actual text and glyph quadrilateral maps back to the original photo and must belong entirely to one card before it can seed that crop. Weak, rotated, or missing evidence retains independent crop OCR. Missing basic-land outlines receive bounded local geometry retries and independent title, type, and physical-footer verification. A verified complete basic land with an unread collector number stays available for artwork review. If its observed set yields no printing, a bounded complete name lookup can compare paper printings while retaining the original set mismatch. Border recovery independently verifies its expanded crop, and an accurate full-photo check still searches outside the card regions. Full-resolution crop images and original OCR confidence remain intact.

An ambiguous scene footer can survive an accepted border repair only when its original glyph belongs uniquely to that card, the recovered title agrees, and strong rules rows repeat. A literal token containing an interior letter can rank one nearby catalog number for review across a complete shared-name, shared-set, shared-art printing list. The observed text and confidence remain unchanged; this similarity adds no score and cannot establish an exact printing or green confirmation.

An earlier benchmark of the supplied four-card photo improved the same iPhone 16 Pro simulator workload from 26.32 to 13.25 seconds median for all four first printing suggestions (p95: 26.63 to 13.29 seconds). OCR alone improved from 20.48 to 10.89 seconds. Both runs used five warmups and seven measured trials; every trial retained the correct MH1/252, ICE/18, MH3/509, and ICE/13 suggestions without altering the photo. These measurements use real Vision OCR and Scryfall references, exclude build time, and do not establish five-second identification or physical-camera throughput on an iPhone.

The subsequent physical iPhone test identifies all four supplied printings in 5.19 seconds median and 5.39 seconds p95, with OCR at 1.33 seconds median. Five warmups and seven measured trials all pass; each trial uses fresh printing and reference caches. The cold first run takes 6.95 seconds. The ambiguous foil footer and misread basic-land set remain review evidence. Complete verified printing lists sharing one illustration and set skip artwork/symbol comparisons because those shared references cannot separate their printings. These are saved-photo identification timings, not live shutter or sweep-scanning throughput.

When primary exact title lookups fail, matching can retry at most two close title alternatives actually returned by native OCR. Confidence, title proximity, color, type, and gameplay text constrain these retries; they never approve a printing. Correcting a widened saved footprint or a titleless rules-panel receipt requires its own acknowledged capture, unique fresh geometry, and matching saved evidence. An unrelated capture, conflicting printing, or competing card cannot supply that correction.

A clipped title can also use a literal self-reference read from the rules, such as “As Nevermore enters the battlefield,” when the photographed title prefix, type, and three separate body rows agree. Automatic lookup replaces a contradictory title result only when the self-reference has an exact catalog identity with matching type and rules. Manual searches keep the supplied name. Adjacent fragments of an illustrator credit can join only when their footer position, confidence, and spacing agree; artist names are not guessed.

A verified historical body can bind a repaired inner crop to its actual pre-shutter card contour when the crop is centered, almost entirely contained, and occupies 60–90% of that contour. The frozen contour must still match one fresh current contour, with no competing receipt or conflicting card evidence. This changes capture ownership only; OCR and artwork retain the original crop coordinates, and printing still requires review. Unverified crops retain the usual geometry checks.

Automatic capture keeps Review/count, pause, and camera controls visible. Lens, torch, focus lock, zoom, exposure, and Clear captures sit in the controls tray. Clear removes the local capture batch and its tracking receipts so the same physical cards can be scanned again; it preserves saved collection entries and additions waiting to upload. In-flight photo handoffs drain before clearing, late recognition results cannot restore the removed batch, and storage failures leave captures available for retry. The batch screen also provides Clear. Automatic capture has no shutter or Next cards button. Verified live identities persist before diagnostic photos finish, and later photos merge into the same physical-card receipts. Admitted metadata survives camera movement without painting a replacement card green. Owned regions exclude already captured cards from later quantities. Saved-photo evidence can also identify a card when it has a unique fresh live association; completed associations stop their focus requests. Diagnostic failures and photo backlog do not block new live identities. Pause and metadata-storage failures stop admission; a compact Retry cards action retries failed metadata using the original receipt IDs. Manual photo capture retains explicit retry and discard controls. Large gallery batches import one photo at a time so recognition can start before import finishes.

Titleless historical live reads require physically aligned rules rows, a literal observed card type, exact artist credit and copyright year, and complete catalog discovery supporting one card identity. The native type-band probe preserves observed text bounds and glyph size. This route identifies the card without confirming a printing or foil finish.

Unresolved sweep targets receive a focus pass before their diagnostic shutter; verified identities can bypass that work. Focus lock and recent manual focus take priority. Photo matching rejects narrowly bounded approximate partial crops covering an explicitly owned earlier card region, without combining different physical cards by name.

Batch review shows catalog artwork and one card at a time with an inline finish choice and Confirm & next. Normal is the default when supported; explicit saved finishes are retained, foil-only printings use their sole supported finish, and other unsupported choices remain unselected. Copies, destination, and section stay inline at normal text sizes and move to Options on short screens or with enlarged text. Batch destination defaults carry into unapproved reviews; existing approvals keep their original choices. Individual review can change printing, language, finish, quantity, and deck section. Printing previews retain the card name, set and collector number during image loading or failure. Named Previous and Next controls switch versions directly; Find printing opens correction, and Cancel or Back remains reachable without a route title bar. Manual printing selection defaults to Normal when supported and keeps a bounded preview, finish and copies inline at normal text sizes; keyboard and enlarged-text layouts may scroll. Unapproved captures and reviewed selections survive restart in account-specific local drafts. Android photo recognition handles one card without iPhone perspective correction or multi-card segmentation. Desktop and web provide manual printing review.

Strong exact matches enter the addition queue automatically, with a ten-second Undo window. Normal is the default finish when supported. Other captures remain available for review. An unmatched review shows the captured image with Retry, Later, Rescan, Remove, and optional Search. It does not require manual card details. Retry waits for that card's result instead of the entire batch.

Approved additions enter an account-specific local queue before upload. Stable operation IDs prevent duplicate quantities after a lost acknowledgement. Collection and destination updates commit together. Local matching works offline. Upload requires Firebase access. Camera originals remain until their durable copy exists, and gallery originals remain untouched. Failed lookups retain the photo for retry.

Saved originals and crops resolve within the account's current image directory when reopened, including focus-stack retries and cleanup. An iOS app-container relocation during an update does not invalidate retained photo references. The directory must match the owning account and the filename must match its draft ID; unrelated files are never substituted.

Review offers Remove capture and Clear captures in every pane. Remove advances to the remaining card; Clear ends the review batch without another prompt and preserves pending uploads. Failed restoration still exposes Clear, and failed reset leaves the current printing and finish available for retry. Background identification updates untouched review panes; corrections retain the chosen printing, finish, quantity, and destination. Saved approvals restore their actual printing ID instead of selecting a different first result.

Submitted additions are immutable while pending upload. On restoration, an exactly matching submitted draft is retired; conflicting drafts remain locked and can be dismissed without changing the queued addition. Uploads arriving during a running pass trigger a subsequent pass. Automatic uploads preserve pauses and skip previous failures; explicit retry includes those failures and reports known authentication, permission, destination, receipt, or local-cleanup errors. Source cleanup reads only its ownership fields, while explicit capture reset can remove invalid draft records without decoding them.

Scan photo metadata now requires the `diagnosticOnly` boolean to distinguish optional diagnostic photos from ordinary captures awaiting identification. Existing photo metadata without this field is not migrated. This change does not delete installed photos or collection data.

Prices use printing- and finish-specific Scryfall quotes. Refresh records daily collection values and per-printing observations; history begins with the first refresh. Unknown finishes and unavailable prices remain unpriced. Shop discovery opens Google Maps searches and the Wizards Store & Event Locator. Rules includes card rulings and searchable official Comprehensive Rules, cached after download.

Tabletop supports d4 through d100, up to ten dice per roll, and individual results. Number mode picks an integer from an inclusive range with endpoints between -999999 and 999999. Dice and Number each retain up to twelve local results. Results use a 240ms numeric reveal; reduced motion presents them immediately. Each press creates exactly one result, and existing results retain their original dice or number-range configuration when the controls change. Local life counters survive reopening the app. Commander modes are hidden until Commander is enabled in Settings. A life counter can create a wireless session or join one with its invitation code. The owner can end the shared session.

The interface keeps the original triangle and monochrome Arcane surfaces. Tab pages omit duplicate title and back bars. iPhone routes use the native edge-swipe gesture instead of visible back buttons; review subpanels return to printing selection before leaving the review. Desktop and Android retain visible route controls. A compact bottom dock keeps 44px touch targets and switches to icons at larger text sizes. Collection search, filters, and add share one row. Scan opens the camera directly; captured cards and printing review use bounded paging with fixed primary actions. Tabletop has no top mode bar: Dice, Number, Life, and Sessions share a footer picker beside Roll or Pick, with a stacked footer at larger text sizes. Animated results remain central, and Rules shows one search result at a time before opening the complete rule. Card utilities are direct actions; group utilities remain in Options. Review quantity and correction actions remain visible above the keyboard. Normal phone account, game, and settings layouts fit without scrolling. Inventory, history, complete rule text, and privacy disclosures retain scrolling; keyboard and accessibility layouts can scroll when needed.

## Groups and Moxfield import

Organize contains decks, binders, boxes, folders and lists. Folders hold nested groups and can contain cards directly. Collection and Value card taps open a swipe-down sheet with Overview, Markets and Owned panes. It shows quantity, rules and available card stats, same-card inventory across printings and finishes, and container memberships. Markets separates TCGplayer USD and Cardmarket EUR estimates; Cardhoarder TIX remains a digital reference. Quotes match the saved finish, missing values remain unpriced, and overlapping container memberships do not increase ownership. Drawer refresh fetches quotes without changing inventory or writing price history; recorded history comes from Value refreshes. Organize, Artwork and confirmed deletion remain in the sheet. Organize sets a printing's total copies in a group; saving the same quantity again does not add copies. Removing membership or deleting a group leaves owned inventory unchanged. Imported condition rows remain separate; increasing their combined quantity adds unclassified copies.

Use Organize → Import to choose a Moxfield CSV/text export, paste an export, or try a public deck link. Public-link access depends on Moxfield allowing its unauthenticated endpoint; private or blocked links require an export. Export files are the reliable import path. See [Moxfield's export options](https://github.com/moxfield/moxfield-public/wiki/Features). Preview quantities, sections and printings before saving. Missing printing details require explicit approval or a printing correction; unresolved or invalid lines block import. Imports preserve language, finish, condition and mainboard, sideboard, commander, maybeboard and companion sections. They create a group without adding owned cards. Scanner destinations use mainboard, sideboard or commander; use Organize to place existing cards in maybeboard or companion. Source format names are retained; only supported deck formats receive legality checks.

Imports accept files up to 2 MB and 10,000 rows. Each group must fit in one Firestore document; oversized groups show a split-list error before any write. Matching uses exact IDs, set/collector numbers or exact names, with catalog requests batched at 75 cards. Atomic group creation uses a stable operation ID so retrying a lost acknowledgement cannot duplicate the group. Group data uses the existing owner-only `user/{uid}/decks` rules; this feature requires no rules deployment.

## Local app verification

Run the app against the disposable Firebase emulators without touching the production project:

```sh
firebase emulators:start --project demo-the-collector --only auth,firestore,storage
cd the_collector
flutter run -d chrome --dart-define=USE_FIREBASE_EMULATORS=true
```

Web emulator builds must use debug mode and a `http://localhost` URL. Firebase Auth reconnects to the emulator after a browser refresh only on that hostname; `127.0.0.1` and profile web builds are rejected before Firebase starts. Native emulator builds support debug and profile modes. Production builds keep their normal Firebase configuration.

Use `FIREBASE_EMULATOR_HOST` for a device that cannot reach the Mac through loopback. Emulator mode is rejected in release builds. Run Flutter tests with `flutter test`; run the actual iPhone Vision fixture with `flutter test integration_test/native_scanner_test.dart -d <device-id> --no-uninstall`. Keep the phone app installed between builds to retain permissions and developer trust, and restore `lib/main.dart` after running a fixture. The fixture checks camera controls and resolution, tilted artwork, multiple cards, collector-number footers, and rotated photos through the native adapter. A simulator can run OCR fixtures but cannot verify camera hardware. Physical testing has verified rear-lens controls, 48MP capture, local burst retention, and one-shutter focus-stack capture of a mounted Circle of Protection: Blue, Nevermore, and a rear Mirkwood Bats at different depths, with exactly three draft cards. The same mounted scene also passed automatic live identification of all three cards across the focus cycle. Glare, sleeves, obscured cards, exact printing accuracy, and sustained scanning still need broader physical coverage.

A supplied 5712×3213 desk photo now has a regression through native Vision and real Scryfall metadata/artwork, with no expected identities passed into recognition. Its four first printing suggestions are Snow-Covered Swamp MH1 #252, Cooperation ICE #18, Jolted Awake MH3 #509, and Circle of Protection: Blue ICE #13. All require review. Jolted Awake uses the conservative number-similarity suggestion described above because its foil footer remains blurred. The cold simulator run took 21.3 seconds for OCR and 27.3 seconds through matching; this is not a real-camera throughput result.

The earlier automatic mounted-scene check saved one four-photo scene with exactly three correct card results. All three saved-photo identities reached green, all active outlines retired, and a 20-second stationary check produced no extra photos or captures. The photos were ready 17.2 seconds after opening the camera, with durable handoff 0.1 seconds later; that interval includes camera startup and discovery. The current sweep regressions check tracking during delayed shutter and saving, capture before previous OCR finishes, replacement-card safety, and bounded admission. Simulator native fixtures verify live text recognition alongside saved-photo OCR. These checks do not measure sustained thousand-card throughput or focus quality while moving a physical phone.

The package and workflow audit covered 964 app checks across the full run and a focused rerun, with one opt-in skip. The full run found two failures in new fixtures. Both passed after test-only corrections, with production source unchanged between runs. Production and scoped native-fixture analysis are clean. Models, card renderer, and Arcane framework checks also pass.

The subsequent native workflow audit found a price-history listener being replaced when delayed card and deck data changed preceding list children. A stable history child now preserves that subscription. The regression failed before the fix; all seven price-page tests pass afterward, including that additional case. This brings the combined app coverage to 965 cases. Ten native simulator scanner checks also pass; the two physical-camera checks remain skipped.

A later scanner latency benchmark uses a two-card scene on an iPhone 16 Pro simulator, actual Apple Vision OCR, durable local storage, and real Scryfall lookups. Across seven measured trials after two warmups, median first-frame-to-photo-request latency fell from 6.56 seconds to 0.37 seconds (p95: 6.87 to 0.47 seconds). Median time to identify both cards fell from 13.55 seconds to 9.58 seconds (p95: 15.14 to 9.81 seconds). All nine final trials produced one photo and the correct two card identities; exact print approval was not asserted. The fixture supplies an existing image immediately at the shutter request and simulates focus, so these numbers measure software latency rather than physical camera speed or sustained sweep throughput. Cold identification still is not instant. Repeating the same corrected-footer pair lookup fell from a 501ms median without the new query cache to 3.24ms with it. The final six cache/resolver/session suites pass all 204 cases; the broader preceding scanner run and focused fixture corrections cover detector and capture behavior. Scoped analysis and the normal iOS simulator build pass.

The latest October 11 wired mounted-scene test retained Nevermore at 9.7 seconds and Mirkwood Bats at 23.0 seconds, with two distinct drafts, no neighboring duplicates, and unchanged diagnostic originals after reopening. Circle of Protection: Blue remained unreadable throughout the 180-second observation, so the three-card physical gate did not pass. An earlier run identified all three and ranked Ice Age 13 first for Circle, but needed 165 seconds for that card. Those results show variable focus and recognition at different depths; they do not establish reliable sweep throughput. The next hardware investigation is bounded automatic focus recovery for a visible region with unreadable live text.

The previous manual mounted-scene check captured three focused photos in 5.7 seconds, handed the complete scene to durable local storage in 5.8 seconds, and retained three green saved-photo-identified outlines through fresh live frames. All three card names were correct, with exactly three draft cards; their printings still require review. These timings describe that earlier manual check of one scene, not the automatic workflow or a sustained scanning rate. The compact workflow audit covers every route source plus unit and widget regressions. Native simulator checkpoints cover account forms, collection navigation, filters, retained batches, printing review with keyboards, Tabletop, Rules, Settings, shared games, privacy, and rejected admin access on small and large iPhone layouts. Nested card/deck utilities, manual entry, valuation, and authorized admin screens rely on host regressions and earlier native checks. Isolated UI fixtures do not establish live provider login or destructive account-deletion behavior.

The opt-in `partial_card_recognition_test.dart` fixture replays locally supplied `scene.jpg` and `desk.png` from the app's temporary `collector_partial_qa` folder. Enable it with `--dart-define=PARTIAL_CARD_QA=true`. It checks a retained clipped Nevermore photo alongside Circle of Protection: Blue, duplicate prevention, bounded crops, unchanged originals, and rejection of partial-card proposals from desk text. It deletes only its own generated crops and report; it does not write to an account or upload the photos.

The opt-in `focus_stack_capture_test.dart` fixture uses a mounted Nevermore, Circle of Protection: Blue, and Mirkwood Bats at different depths. Run it on a connected iPhone with `--no-uninstall --dart-define=PHYSICAL_CARD_QA=true --dart-define=AUTOMATIC_CARD_QA=true` to check automatic capture without a shutter, retained verified identities, optional photo matching, marker retirement, and duplicate prevention. Omit `AUTOMATIC_CARD_QA` for the manual benchmark; add `--dart-define=LIVE_CARD_QA=true` to that manual mode to check live identification before capture and retained identified markers afterward. Both modes require all three catalog matches and exactly three draft cards across the focus passes. Photos and OCR evidence stay in an isolated temporary local draft store, with no account writes. Corrected geometry and partial-card results still require printing review.

The iOS `native_live_exclusion_test.dart` fixture checks native appearance samples and the completed-region OCR exclusion primitive. Appearance observations remain available while the camera masks a region. The camera separately rotates completed regions through OCR verification as described above. Run the fixture on an iPhone or iOS simulator with `flutter test integration_test/native_live_exclusion_test.dart -d <device-id> --no-uninstall`. It uses generated local images and performs no account writes or remote card lookup.

`partial_card_recognition_test.dart` also supports `--dart-define=PARTIAL_DIAGNOSTIC_QA=true` with an owned image at `tmp/collector_partial_qa/diagnostic.jpg`. It exports full-scene text, partial-card proposals, and localized verification without changing recognition. Add `--dart-define=PARTIAL_DIAGNOSTIC_EXPECT_NAME=<name>` to require a supported title, type, and at least two rules lines; the input image remains unchanged.

The simulator capture fixture uses public card artwork as camera frames with the real native detector, tracker, and catalog resolver:

```sh
flutter test integration_test/live_camera_ui_test.dart -d <simulator-id> --no-uninstall
```

Camera hardware is simulated in this fixture. It checks preview alignment, focus coordinates, control calls, capture lifecycle, and large text layout. Restore the normal app afterward with `flutter run -d <simulator-id> -t lib/main.dart`. Neither fixture verifies physical lens focus, glare handling, or sustained live-camera throughput.

Exercise the normal mobile app against local Auth and Firestore with:

```sh
firebase emulators:exec --project demo-the-collector --config ../firebase.json --only auth,firestore 'flutter test integration_test/mobile_app_test.dart -d <simulator-id> --dart-define=USE_FIREBASE_EMULATORS=true --no-uninstall'
```

Run this from `the_collector` on a Simulator with no signed-in account. It checks native offline profile retry, collection filters and details, deck edits without changing inventory, saved prices, dice, persisted life counters, theme and Commander preferences, and live card and comprehensive rules lookup. It uses a disposable emulator account, removes its test data afterward, and refuses to replace an existing sign-in. Card art and rules lookup use their public sources. Restore `lib/main.dart` after the fixture.

Check concurrent native saves and receipt retries against local Firebase with:

```sh
flutter test integration_test/ingestion_emulator_test.dart -d <simulator-id> --dart-define=USE_FIREBASE_EMULATORS=true --no-uninstall
```

This test refuses to run without emulator mode. It uses a separate named Firebase app and disposable local account, preserving the normal app's signed-in account. It verifies that concurrent additions preserve existing inventory and deck counts, repeated operations do not add copies again, and a missing destination leaves inventory unchanged.

Verify wireless games on the simulator with two independent Firebase clients:

```sh
flutter test integration_test/shared_game_emulator_test.dart -d <simulator-id> --dart-define=USE_FIREBASE_EMULATORS=true --no-uninstall
```

The guest joins through the real dialog, updates a life counter, and observes the owner ending the room. The test verifies both clients against the local Firestore rules and removes its room and accounts afterward.

The native Apple sign-in UI fixture uses a simulated provider and does not contact Apple or Firebase:

```sh
flutter test integration_test/apple_sign_in_ui_test.dart -d <simulator-id> --no-uninstall
```

It verifies that both provider buttons remain reachable with large text in both themes, blocks duplicate actions during authorization, and restores the form after cancellation. Real Apple authorization remains a release check after capability/provider configuration.

See `vendor/arcane/README.md` for the framework source and current Flutter compatibility fixes.

## Account deletion rollout

The Privacy & data page is available before sign-in and in Settings. It describes actual local and cloud data handling; it is not a published legal privacy policy.

After the publisher approves and publishes a privacy policy, build with `--dart-define=PRIVACY_POLICY_URL=<published-https-url>` to show its link on that page. The flag defaults to empty, which hides the link. The URL must use HTTPS, include a host, and contain no credentials; invalid configuration throws an `ArgumentError` when the page opens. The app opens the policy outside the app and supports retry if the link cannot open. This setting does not publish a policy or verify its content or availability.

Account deletion requires coordinated deployment of the new Firestore/Storage rules, indexes, and all three functions described in [the backend README](../functions/README.md). Until that rollout is verified, normal app builds do not read the new job collection or show deletion controls. This keeps current authentication working with the existing deployed rules. Build with `--dart-define=ACCOUNT_DELETION_ENABLED=true` only after verification. Local emulator builds enable the feature automatically with `--dart-define=USE_FIREBASE_EMULATORS=true`.

Deletion requires same-account reauthentication and explicit confirmation. The callable binds that confirmation to the authenticated UID. Once accepted, the app closes account views, removes only that account's canonical local queues/photos/game preferences, signs out, and clears Firestore persistence. Web builds reload after clearing the terminated Firestore instance. A transport timeout retains a durable pending marker; it never proves that the server rejected the request. Cleanup retries cannot restore account writes or wait indefinitely for offline upload futures. Completed local markers remain blocked without repeating cache cleanup at every launch.

Queue storage reads only its canonical v2 format. Retired queue formats are not imported or removed automatically.
