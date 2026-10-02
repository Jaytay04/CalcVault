# TTKillerPlus 2.2: static reverse-engineering reference

**Review date:** 2026-10-02

**Inspected target:** publisher-linked TikTok 47.0 / TTKillerPlus 2.2 package, ARM64
**Purpose:** preserve a traceable description of the add-on's observed design for future compatibility research. This is not an endorsement, source recovery, runtime validation, or authorization for new feature hooks, licensing changes, or expanded CalcVault access.

## Evidence and scope

The preserved IPA is 470,033,098 bytes with SHA-256 `8e6744fd00d01cb44ae22301df992d439761b163f79b67de6e352df4ab9c3198`. Its TikTok app metadata identifies version 47.0.0, build 470044, bundle ID `com.zhiliaoapp.musically`; the archive has 3,518 entries and all entry CRC checks passed. The embedded `Payload/TikTok.app/Frameworks/TTKPlus.dylib` is 812,816 bytes, SHA-256 `e99888d3d7e2c37839f5361ccfe2abafcfb1c20ef72c82d9062beb4ed1ab6a55`. The dylib's ARM64 preflight reports `cryptid=0`. These digests establish identity of the inspected bytes, not publisher trust or safety.

The package came from the publisher-linked archive and is preserved unchanged beside the outer Calculator workspace under `Projects/iKarwan-IPAs/2026-10-02`; the preservation record and `SHA256SUMS.txt` are alongside it. The inspected dylib was copied to `build/ttkiller-feature-review-20261002/TTKPlus.original.dylib` and has the same digest. Inspection was limited to archive/plist metadata, Objective-C metadata, imports, compile-time strings, and bounded ARM64 disassembly. No package code was executed, installed, patched, decrypted, or sent a request. No private account, media, credential, key material, or authentication endpoint details were used or recorded.

This document separates evidence levels:

| Label | What the evidence supports |
|---|---|
| **Direct static path** | A specific registration, call, branch, or API sequence exists in these exact bytes. It does not prove the path is reached successfully on a device. |
| **Declared/UI evidence** | A class, selector, preference key, or localized label exists. It does not by itself prove a feature works or is enabled. |
| **Unverified behavior** | Control flow, failure handling, compatibility, or effects not established by this bounded inspection. |

The static parser found 18 classes, one category, 578 declared methods, 978 Objective-C selector stubs, and 1,732 function starts. Expanded registration analysis found 238 method-add/hook sites in the two analyzed registration regions. The registration parser follows straight-line register values across those bounded regions; it is not a whole-program control-flow proof. The direct-call tracer identifies ARM64 branches into selector stubs and associates them with function starts. The listed addresses below are **unslid Mach-O VM addresses for this exact dylib only**. They are documentation coordinates, not live patch locations, and cannot be carried over to a different build.

The durable [inspection tool](tools/inventory.py) reproduces the metadata, direct-selector-call and optional LLVM registration inventory. Its input-specific decoding and exclusions are documented in the [package guide](README.md) and [evidence record](EVIDENCE_AND_LIMITS.md). Earlier ignored helpers supplied initial triage; the packaged tool is the reusable entry point. None of these tools is a runtime emulator, complete control-flow proof or ABI compatibility check.

## High-level design

TTKillerPlus is an injected Objective-C tweak loaded into TikTok, not a separate downloader application. The inspected dylib links CydiaSubstrate and imports `MSHookMessageEx` and `MSHookFunction`, along with Foundation, UIKit, Photos, AVFoundation, ImageIO, WebKit, Security, and CoreTelephony. Ordinary platform media APIs appear downstream of private TikTok class and selector hooks. This is therefore not evidence of a generic web-page scraper, a supported TikTok SDK integration, or an independently demonstrated external downloader service.

The visible feature shape is: add controls to selected native TikTok surfaces; obtain model or story media candidates through TikTok objects; download media through Foundation networking; optionally present or save results through Photos; and alter selected profile/story view-reporting callbacks when preferences are enabled. Hooking private app classes makes behavior dependent on TikTok's internal class names, selector signatures, object layout, and lifecycle. Static presence says nothing about whether the exact target app will instantiate those classes or whether the UI remains usable.

## Scope and coverage of the full add on

This expanded review covers **the entire TTKillerPlus add-on**, not only the
owner's requested download and profile-privacy features. The host TikTok
application and its large `MusicallyCore` framework are dependencies, not
reconstructed source for this add-on. RxTikTok, iNKillerPlus and YTKillerPlus
are separate products and are not substituted into this analysis.

A searchable [machine-readable component index](research/TTKILLERPLUS_2_2_STATIC_INDEX.json)
is part of this reference. It records every declared method with its Objective-C
type encoding, compiler-delimited function size and observed direct
selector-stub calls, every selector stub, all extracted TTKPlus preference names,
linked libraries, and the recovered method-registration candidates. It contains
names/metadata, not endpoint URLs, credentials, resource payloads or patch code.

| Inventory | Count | Meaning and limit |
|---|---:|---|
| Declared classes / categories | 18 / 1 | All class/category-list entries in this exact dylib were parsed. |
| Declared methods | 578 | Includes accessors, destructors and bundled utility methods; not 578 distinct features. |
| Compiler function starts | 1,732 | Includes hooks, helpers and block bodies; not recovered source or semantic completeness. |
| Selector stubs | 978 | All validated 32-byte ObjC stubs in this input; selector name does not establish receiver or reachability. |
| Direct branches to selector stubs | 8,061 | Whole text-section scan; includes tail branches and repeated calls. |
| Functions containing these calls | 976 | Other functions may use C calls, indirect dispatch or no external calls. |
| Method hook / added-method sites | 165 / 73 | 238 static call sites, cross-checked against LLVM stub references; successful registration is not established. |
| C function hook call sites | 5 | Four calls and one tail branch to `MSHookFunction`; not five independently verified runtime effects. |
| Literal TTKPlus preference names | 23 | This prefix is not the entire storage-key inventory; identity, language, cache and authentication state can use other keys. |

The earlier 237-site figure omitted the registration at `0x12ff8` because the
second parser range began at `0x13000`. Expanding that range to `0x12000`
accounts for all 238 method-registration call sites seen by LLVM. This is a
coverage correction, not a discovered runtime fix. Registration identities
remain straight-line dataflow candidates, not a control-flow/ABI proof.

### All declared components

| Component | Methods | Reconstructed responsibility |
|---|---:|---|
| `RootOptionsController` | 72 | Feature switches/segments, settings table, icon theme, language picker, cache size/controls, compatibility footer and gestures. |
| `DownloadsControllerttk` | 32 | Despite its name, activation/restore/device-unlink/license checks, error/loading UI and settings-entry verification. It is not the album downloader. |
| `ModernWebViewController` | 40 | HTML checkout modes, JavaScript payment messages, payment navigation, retry/loading/error UI and delegate cleanup. |
| `CountryTable` | 13 | Country/region selection table and current carrier/region diagnostic. |
| `IconSelectorViewController` | 14 | Theme collection, selected-theme state and completion callback. |
| `IconCell` | 9 | Icon image, name and selection indicator presentation. |
| `YTKPlusLanguageManager` | 7 | Auto/manual language state, preferred-language selection and available localizations. |
| `TTKAlbumPickerVC` | 35 | Album model/URL arrays, selection, cached images, optional music processing and Photos saves. |
| `TTKAvatarFullscreenVC` | 12 | Fullscreen avatar loading, display, dismiss and Photos save. |
| `TTKLAutoClickButton` | 29 | Live interaction control, drag/long press, count selection, timer and repeated interaction dispatch. |
| `FCUUID` | 37 | Session/installation/vendor/device identifiers, defaults/Keychain support, migration and iCloud identifier-list machinery. |
| `FCUUID` category | 1 | Additional `uuid` method. |
| `UICKeyChainStore` | 130 | Generic/Internet-password wrappers, query/attribute construction, add/read/update/delete, access options and shared-web-credential APIs. |
| `MBProgressHUD` | 99 | Progress overlay lifecycle, timing, animations, layout, labels/buttons and progress observation. |
| `MBBackgroundView` | 13 | HUD background color/blur/style presentation. |
| `MBBarProgressView` | 13 | Bar progress drawing and colors. |
| `MBRoundProgressView` | 13 | Circular/annular progress drawing and colors. |
| `MBProgressHUDRoundedButton` | 5 | HUD button layout/highlight/title-color presentation. |
| `MBProgressHUDRoundedButton2` | 4 | Second HUD button presentation variant. |

Responsibilities are inferred from declared methods plus their direct calls;
the index retains the full names so future research need not start again.
Utility-library method presence does not establish that all those capabilities
are exercised by the tweak.

### Runtime additions are a separate component family

Most TikTok-facing behavior is **not** declared on those 18 classes. It is
registered onto existing TikTok/platform classes and implemented by otherwise
unlabelled functions. The index therefore keeps registration candidates
separately from declared methods. Important families are:

- `AppDelegate`: startup, authentication checks, installation/activation reporting,
  inspection-detection methods and cache clearing.
- `TTKTabBar`: tab layout/visibility, settings and activation entry, plus cleaner,
  reset and Keychain-wipe actions.
- Feed/profile/avatar/model/URL classes: UI controls, metadata/model changes,
  downloads and profile augmentation.
- Story managers/network service/metadata and message-read operators:
  selected viewed/read-state interception and explicit mark-read controls.
- Live audience controller and window events: live auto-click control lifecycle.
- Carrier/region/install/store/cache classes: region override inputs.
- Platform and SDK environment helpers: file/scheme/receipt/app identity and
  environment-query interception.

These are process-wide changes inside the guest, not isolated Swift screens.

### Locators for the additional traced paths

These coordinates supplement the named registration candidates in the index;
they are for inspection of the pinned binary, not instructions to patch it.

| Path | Unslid implementation coordinates | Evidence read |
|---|---|---|
| Ad model filtering | `0x26010`, `0x260d0` | Preference gates, ad selectors, conditional nil/original result. |
| Recommendation skipping | `0x329ec`, `0x32aac` | Preference gates, current model/card check, direct next-video selector call. |
| Region selection and representative getters | `0x41c34`, `0x2c734`, `0x2c8ac`, `0x2ca24` | Defaults object/code read/write and original fallback. |
| Live control attachment and cleanup | `0x32688`, `0x327a0` | Feature gates, control creation/removal and cleared state. |
| Message read wrappers | `0x31d3c` through `0x320c4` (six registered implementations) | Global/message gates, pass-through flag and original/skip branches. |
| Warning suppression | `0x32b50`, `0x32bc0`, `0x32c30` | Feature gates and original-call suppression. |
| Follow/video-like/comment-like confirmation | `0x32da4`, `0x32ea4`, `0x32fa4`, `0x33048` | Feature gates and custom/original dispatch. |
| Directory and Keychain clearing | `0x1cea8`, `0x1ccc8` | File deletion API and class-wide Security deletion query construction. |

Story collection advance hooks (`TTKStory2FeedCollectionView` and
`TTKStoryContainerCollectionView`) are inventoried alongside the read-state
hooks, but their complete effects on auto-advance and seen-state transitions
are unresolved. `AWESecurity.resetCollectMode` and
`MSManagerOV/MSConfigOV.setMode` are registered environment/collection-control
interceptions; their exact meaning and data-collection impact are likewise
unclassified. Neither names nor the registration itself justify claiming that
all telemetry, inspection or view reporting has been disabled.

## Settings, appearance and support infrastructure

### Settings stored in preferences

All 21 declared Boolean toggle handlers in `RootOptionsController` have direct
calls to `isOn`, `standardUserDefaults`, `setBool:forKey:` and `synchronize`.
`loopModeChanged:` uses a selected segment and `setInteger:forKey:`.
The Friends/Create/Inbox toggle handlers also call `relayoutTabBar`.
The generic switch/segment builders read a stored value or supplied default
and configure enabled/alpha/UI state. Those calls establish settings mechanics,
not the exact eligibility rule for each disabled cell.

The 23 prefixed keys cover global enablement; ads; profile/story/message read
behavior; avatar/bio gestures; country/follow/video-count/grid metadata; clear
display; three hidden tabs; follow/video-like/comment-like confirmation;
warnings; recommendation skipping; feed loop mode; download control; and live
auto-clicking. Inspect the index for exact spellings. Do not assume every
setting is independently licensed, immediately applied or persisted safely
merely because a switch exists.

### Themes and app icon changes

`IconSelectorViewController` uses a collection and completion handler;
`RootOptionsController` keeps the chosen theme in a defaults suite and updates
its icon button. `areCustomIconsAvailable` reads the main bundle's info
dictionary. `changeAppIcon:` reaches
`supportsAlternateIcons`/`setAlternateIconName:completionHandler:`, but also
has a separate `manuallyChangeIcon:` path. That path reads a dictionary below
the bundle path, mutates dictionary fields and calls `writeToFile:atomically:`.
Its exact target and writability are not established here. This fallback must
not be described as a supported or successful icon change on stock iOS.

### Language and UI utilities

The language manager reads defaults, supports automatic selection from
`preferredLanguages`, and lists bundle localizations. UI paths resolve a
language-specific bundle and `localizedStringForKey:value:table:`.
The root controller includes a language picker, seasonal footer message, tap
count/reset timer, haptics, compatibility-label generation and confirmation
gestures. Compatibility labels are locally computed presentation, not proof
of OS/device support.

HUD classes provide animation, timing, constraint layout and progress-object
updates. Their many accessors account for a substantial part of the declared
method count. They are support code, not hidden additional social features.

## Feature families beyond downloads

| Family | Registration/declaration evidence | Remaining boundary |
|---|---|---|
| Tab visibility and spacing | `TTKTabBar` layout/reload hooks and added `ttk_applyTabVisibility`/`ttk_fixTabLabelSpacing`; three settings write preferences and request relayout. | Exact tab-identification logic, accessibility and every layout version require validation. |
| Profile badges/counts/region | `TTKProfileHeaderAdaptor` config/update hooks, follow-badge and flag actions; `AWEUserNameLabel` layout/constraint/hit-test hooks and flag placement/removal helpers. | A displayed flag is inferred metadata, not verified location; badge/count accuracy is not demonstrated. |
| Bio copy and avatar gestures | Added bio long-press installer/handler and the separate avatar fullscreen path. | Clipboard contents, sanitization and availability need per-path validation. |
| Grid dates | `AWEUserWorkCollectionViewCell` configuration/reuse hooks and added `ttk_updateDateLabel`. | Exact date source/timezone and reuse behavior are not fully traced. |
| Feed progress/model behavior | `AWEAwemeModel` initialization, progress visibility/draggability, viewed setters and live-model-transformer hooks. | Model side effects and fallback handling are distinct from adding a save button. |
| Clear display | Feed exit-clear, stable-clear flag, reuse and feed/detail appearance hooks. | Persistence and restoration of normal controls are not proven. |
| Loop/auto-scroll | `TTKFeedAutoScrollModeComponent.playerWillLoopPlay:` and new-feed display/appearance hooks. | Mapping segment values to exact playback/advance behavior requires branch validation. |
| Recommendations/ads | Corresponding preference writers and feed/model hooks exist. | Exact filtering decisions and complete ad/recommendation coverage are not established by names alone. |
| Warning/mask controls | Warning image/label/update hooks and `AWEMaskInfoModel` show-mask getter/setter hooks. | Does not remove provider policy or establish safe/unrestricted playback. |
| Follow/video-like/comment-like confirmations | Hooks on follow-click, double-tap/button-like and comment-like entry points, with corresponding settings. | Confirmation/cancellation forwarding and duplicate-action handling need per-hook control-flow verification. |
| Message read behavior | `AWEIMMessageBaseViewController` appearance/disappearance hooks, added eye/mark-read controls, six `TIMMessageMarkAsReadOperator` methods. | Local/client/server read-index paths are separate; no guarantee of invisible messaging or suppression of every receipt. |
| Story viewing/marking | Controller eye controls, state managers, network-service reporters and viewed metadata setters. | See the traced preference paths below; server-observed privacy remains unverified. |
| Live auto-click | Audience-controller appearance/disappearance hooks, `UIWindow.sendEvent:` hook and `TTKLAutoClickButton`. | This can perform account-affecting actions; no live execution or safe-use certification was performed. |

### Traced non media feature gates

The feature registrations are not merely UI labels. Additional disassembly
traces establish these local branches in the exact inspected build:

- **Ads:** with global enablement and AdBlock on, the dictionary model initializer
  checks `isAds`, `isSoftAds` and `hasAd`; flagged models can yield nil.
  The plain initializer checks only `isAds`. This is model filtering, not
  a network-wide blocker, and callers' handling of nil remains a compatibility risk.
- **Recommendations:** enabled SkipRecommendations hooks obtain `currentAweme`,
  test `isUserRecommendBigCard` and call `scrollToNextVideo` when true.
  This is a specific recommendation-card path, not all suggested content.
- **Warnings:** enabled DisableWarnings wrappers suppress selected original
  warning image/label/update implementations. Mask hooks are a separate family.
- **Follow and likes:** enabled FollowConfirmation, LikeConfirmation and
  LikeCommentConfirmation wrappers enter custom confirmation paths; otherwise
  saved original implementations are invoked. The exact accept/cancel/block
  callbacks and duplicate-action behavior still need tracing.
- **Live control lifecycle:** Enabled plus LiveAutoClick permits creation/
  attachment on live audience appearance; disappearance invalidates/removes
  the control and clears related state. This does not prove every interruption
  or background transition reaches that cleanup.
- **Message read callbacks:** Enabled defaults true and MsgEye defaults false.
  Under both enabled preferences, an internal pass-through bit decides whether
  the six inspected read-operator wrappers forward or suppress original calls.
  The server wrapper can return false/nil on the suppressed path. The separate
  eye/manual-mark action is consistent with this design, but its complete
  state-transition protocol and provider-side effect are not established.

These observations reconstruct local mechanisms. They do not prove all live
classes/selectors remain compatible, every event is intercepted, or any privacy
setting makes account activity invisible to the service.

### Live automatic interaction control

The declared live control installs tap/pan/long-press gestures and an observer.
Pan handling updates the center/drag state; long press presents a count picker.
`startClicking` reads the selected count, sets running/remaining state, calls
`fireClick`, and schedules a repeating timer.
`fireClick` calls recursive `findDiggGesture:`, reaches
`touchesBegan:withEvent:`, updates remaining count and can call
`stopClicking`. Stop invalidates the timer and updates appearance; deallocation
also invalidates and removes the observer. This is stronger evidence than a
localized “auto-click” label, but it does not prove accepted likes, timing limits,
successful cleanup on every dismissal or provider compliance. No likes were sent.

## Region selection and identity boundaries

`CountryTable.tableView:didSelectRowAtIndexPath:` obtains the chosen region,
writes defaults, synchronizes, reloads and returns through navigation.
`testCurrentRegion` reads carrier name/ISO code/MCC/MNC through telephony objects
and displays a diagnostic. Registered interceptions span `CTCarrier`,
`TIKTOKRegionManager`, `TTKStoreRegionService/Model`,
`TTKPassportAppStoreRegionModel`, `ATSRegionCacheManager`,
`TTInstallIDManager` and `BDInstallGlobalConfig`, including getters/setters.
There are also `AWEUserModel` region/country setters and profile flag UI.

Representative region-manager getters read the selected defaults object under
`region`, then its `code` field, and fall back to saved original implementations
when no override is present. The CountryPill preference is a separate profile
flag-display control, defaulting false under the global enablement gate; it is
not the stored region override itself.

This is local input substitution/presentation, not a VPN, IP relocation,
GPS change or demonstrated server-side region change. Carrier diagnostics
inside the same hooked process may reflect the substitutions being tested.

`FCUUID` distinguishes session, installation, vendor and device identifiers.
Its helpers read/write defaults and a Keychain wrapper; device-identifier
migration and synchronizable/iCloud-list machinery are declared and have
direct storage calls. Licensing methods directly call `uuidForDevice`.
Do not call this a hardware identifier, guaranteed stable identity across
re-signing/reinstallation, anonymous identity or confirmed cloud sync.
The Keychain utility supports more operations than this review proves are used.

## Feature-to-path map

| Area | Static path evidence | What remains unproven |
|---|---|---|
| Feed download control | `TTKFeedInteractionStackView` hooks `layoutSubviews` and adds `ttk_addDLButton`; selectors include `ttk_dlTapped:`, `ttk_showLegacySheet:model:vc:`, `ttk_downloadToPhotos:`, `ttk_downloadAndShare:sender:vc:`, and `ttk_downloadMusicShare:sender:vc:`. `ttk_addDLButton` reaches UIKit button, constraints, and target/action setup. | Which feeds or cards expose it; actual presentation, errors, or successful save on-device. This does not establish Explore coverage. |
| Feed/story media selection | `ttk_dlTapped:` reads story markers and KVC properties such as `photoAlbum`, `photos`, `originPhotoURL`, `originURLList`, `recommendUrl`, and `thumbnailPhotoURL`; it builds a `TTKAlbumPickerVC` with model, photo URLs, thumbnail URLs, video flags, and cached images, then presents a sheet/popover. It also directly calls story helpers. | Every model shape, story type, photo carousel, or feed surface working. |
| Story candidate traversal | Helpers at `0x3b3f4` and `0x3b578` inspect `currentPlayingStory`, `nextResponder`, window/root controller, child controllers, and presented controllers. Story-action helper `0x3bac4` reads `video`, `playURL`, and `bestURLtoDownload`, including KVC and array sorting. | The complete fallback ordering, view lifecycle coverage, or all stories being downloadable. |
| URL choice | `AWEURLModel` gains `bestURLtoDownload` at `0x25b94`. It calls `originURLList`; returns nil for an empty list; tries entries containing `1080` and length at least 11, then `720`, then reverse-enumerates alternatives containing `video_mp4`, `.mp4`, or an `http` prefix (also length at least 11), finally falling back to the first entry before `URLWithString`. | True bitrate/resolution ranking, no-watermark output, URL validity, HTTPS-only filtering, or successful access. The `http` test is not HTTPS-exclusive. |
| Album selection/save | `TTKAlbumPickerVC` declares initialization, select-all, download, and `saveImage:okCount:group:` methods. The save helper uses Photos changes and `creationRequestForAssetFromImage`. `downloadTapped` reads selected indexes, music-switch state, cached images and visible collection cells; a cached/displayed image fallback is present, but its ordering is not fully established. | Exact image/video fallback behavior, permission/error UI, partial completion, or cleanup. |
| Video to Photos | `ttk_downloadToPhotos:` at `0x253b0` uses `sharedSession`, `downloadTaskWithURL:completionHandler:`, and `resume`. A constant completion block invokes helper `0x3e458`, which reaches Photos `performChanges:` and nested helper `0x3e854` calls `creationRequestForAssetFromVideoAtFileURL:`. The completion helper also uses temporary-file and file-manager selectors, including path construction, removal, and copy operations. | Exact temp path, error branches, cleanup lifetime, response validation, redirects, MIME/size limits, and permission-denial handling. Presence of cleanup calls does not prove cleanup on every exit. |
| Share and music actions | Feed helpers `ttk_downloadAndShare:sender:vc:` and `ttk_downloadMusicShare:sender:vc:` exist; the former also uses a URL download task, while the latter uses `downloadTaskWithRequest:`. | Complete share flow or music extraction pipeline. Do not infer a particular extraction provider or network protocol. |
| Avatar saving | `TTKProfileAvatarNormalComponent` hooks `loadComponentView` and `updateUI`; adds long-press gesture methods. `TTKAvatarFullscreenVC` includes `ttkLoadImage` (data task) and `ttkSavePhoto` (Photos changes and image-asset creation). | General profile-image coverage. This is evidence for a specific avatar path, not every image or profile surface. |
| Profile-view preference | Hooks on `TTKProfileViewsVisitor` include `p_shouldReportProfileView`, `p_shouldReportHasVeiwedProfileForUser:`, `reportProfileView`, `visit:`, and two `logCanNot...` methods. `TTKPlus_Enabled` defaults true; `TTKPlus_AnonymousProfileView` defaults false. The helper at `0x38638` reads `standardUserDefaults` and `boolForKey:`. With both preferences on, inspected branches return false or skip original reporting/logging paths; with the preference off, saved original implementations are called. | Provider-level anonymity, suppression of every event, or a network anonymity guarantee. It is local selective callback suppression, not a demonstrated proxy or protocol feature. |
| Story-view preference | A separate `TTKPlus_StoryEye` preference defaults false. Hooks include story-state/manager methods, `TTKStoryNetworkService` class methods for report callbacks, and metadata-viewed setters. Manual eye-button hooks are declared for photo/video story controllers; inspected network-service callback branches skip original calls under the relevant enabled preferences. | Actual provider-side privacy, every story-version path, or completion callback behavior when a call is skipped. Do not equate a hidden eye control with guaranteed unseen viewing. |
| Settings | `RootOptionsController` and `DownloadsControllerttk` are declared, alongside language, country, icon, web-view, and HUD classes. Traced toggle handlers for anonymous profile view, download button, and story eye call `isOn`, `standardUserDefaults`, `setBool:forKey:`, and `synchronize`; runtime helpers read preferences. | Full settings UX, persistence across every OS/app state, or operation of all listed switches. |

The add-on declares settings for ad blocking, profile/story view behavior, avatar long press, bio/display options, download-button visibility, feed tabs, warnings, follow/like confirmations, recommendation behavior, and other UI preferences. These names describe claimed or intended controls only. In particular, a declared auto-action or warning setting is not proof it works, is safe, or should be reproduced.

## Settings entry, state, and optional processing

The owner reports that the gear icon opens settings in the installed CalcVault
candidate. This is owner-operated evidence, not an independently reproduced
phone test. The previously reported white page is therefore not, by itself,
proof of a settings or licensing block. Static registration also adds
`ttk_installProfileLongPress`, `ttk_profileTabLongPressed:`, and
`openDownloadsController` to `TTKTabBar`, providing evidence of another intended
settings entry. It does not prove both entry paths work on every layout.

The three traced switch handlers write their values to standard preferences;
the feature-side Boolean helper reads a value or uses its supplied default.
This links settings to behavior more strongly than localized strings alone.
Preferences are not authentication or a vault boundary. Whether a general
apply/restart action changes other cached state remains unverified.

The album path is not just a single-image downloader. Its initialization carries
parallel photo/thumbnail/video-flag arrays and cached images. Selection state,
select-all handling, collection-cell image access, and a music switch are
visible in its methods. AVAssetWriter, H.264 writer settings, AVAssetExportSession,
and audio/video composition APIs are also present. Together with the declared
slideshow/music UI, these support an optional media-composition capability;
exact timing, dimensions, compression, music acquisition, and completion behavior
were not reconstructed. Saving a downloaded original and generating a slideshow
are different operations; the latter must not be described as lossless.

`YTKPlusLanguageManager` is the actual language-manager class name in this TikTok
package. That name alone is not evidence of a YouTube integration. Likewise,
linked WebKit/Security/CoreTelephony APIs and license-related classes do not
prove that every feature uses those frameworks or that any bundled identity is
a licensing credential.

## One native video-to-Photos flow

The clearest media path statically supported is the feed video save action:

```text
feed button tap
  → inspect selected TikTok model/story objects for URL candidates
  → choose a candidate URL with bestURLtoDownload
  → URLSession download task and resume
  → completion helper copies/handles the temporary downloaded file
  → Photos performChanges
  → creationRequestForAssetFromVideoAtFileURL
```

This establishes a code path aimed at creating a video asset in the system Photos library. It does not establish a successful end-to-end save, source-quality guarantees, error recovery, or preservation/deletion behavior for every temporary file. The album-picker image path is a distinct flow using image data and Photos image-asset creation. Neither path writes to CalcVault's encrypted repository.

## Startup, environment interception and process lifecycle

The main executable weak-loads the tweak; its startup code registers platform,
SDK and TikTok-class interceptions through Substrate and adds methods to
existing classes. One registration hooks
`AppDelegate.application:didFinishLaunchingWithOptions:`.
Added delegate methods cover authentication/verification/state clearing,
installation statistics, activation logging, cache clearing and methods named
`disableFrida`, `detectFridaGadget`, and `detectModification`.
Their existence is not evidence of an effective security boundary.

A separate startup family intercepts file existence/readability/writability/
directory listing, URL opening, bundle resource/receipt queries, SDK
jailbreak/App Store/channel/bundle-identifier queries, sandbox test flags and
startup timing. There are also five C-function hook call sites.
This family changes the environment observed by code running in the process.
It must not be mistaken for ordinary download functionality, actual device
security status or a trustworthy indicator that the package is unmodified.
Specific replacement constants and restriction-bypass procedures are omitted.

Several feature wrappers consult `TTKPlus_Enabled` together with their own
preference; this was traced for selected paths, not established universally.
Other control planes include authentication state, globals/associated objects,
timers, observers and controller lifecycle. Turning off one switch is not proof
that all installed platform hooks are removed. Added download-session/button
properties and other `ttk_*` methods can exist on host classes without appearing
in the declared-class inventory.

For embedding, every process-wide interception matters: settings/privacy/media
and startup environment behavior execute in the same guest process. CalcVault
host protection must remain independent of tweak preferences or third-party
authentication results. Current phone observations about isolation are recorded
elsewhere; this static inventory is not a new sandbox or lifecycle test.

## Licensing, checkout and state architecture

The add-on has **two distinct UI roles**, not one monolithic settings page:

1. `RootOptionsController` builds feature/settings controls and an activation
   cell; root/tab/delegate code supplies entry and verification routes.
2. `DownloadsControllerttk` supplies activation, restore, device-unlink and
   verification UI/networking. `ModernWebViewController` supplies checkout.

### Local inputs, remote verification and refresh

Declared activation inputs include email and license key, with device identifier,
session token, expiration and timestamp state fields. Email validation reaches
an `NSPredicate`; license-key validation calls a length selector. These are
local input checks, not proof a license is valid.

Email lookup, restore, unlink, authentication and verification methods reach
`ephemeralSessionConfiguration`, `sessionWithConfiguration:`,
`dataTaskWithRequest:completionHandler:` and `resume`. They build request
bodies and headers, percent-encode string inputs and, in applicable paths,
include a timestamp/device UUID. A TLS-minimum setter is called; this reference
does not infer its numeric value, certificate pinning or full transport safety
from selector presence. Exact endpoints/credentials/request signatures are
intentionally not exported and no requests were made.

`checkAuthenticationStatus` calls verification and state-save methods.
The save method uses a dictionary, string operations and standard-defaults
removal/synchronization; helpers and completion blocks determine the actual
state serialization, integrity handling and success/failure transitions.
The bundled Keychain utility and HMAC import do not alone prove that licensing
secrets are Keychain-protected or that stored state is tamper-proof.
A `dailyCheckTimer` property exists; actual scheduling and refresh frequency
must be traced rather than inferred from its name.

The delegate and tab bar additionally receive authentication methods through
runtime registration. Thus declared methods on `DownloadsControllerttk` are
not the complete authentication surface. No claim is made that every feature
shares the same gate, that a successful local flag grants server authorization,
or that removing a prompt enables all functionality.

### Checkout web view

`ModernWebViewController` selects among new-purchase, subscription/renewal,
store-purchase and store-add HTML modes. It builds a WKWebView configuration,
adds a script-message handler, loads generated HTML, and dispatches message
body fields through `handlePaymentWithScheme:method:`.
Payment handlers select a URL and call `loadPaymentURL:openExternally:`,
which can load a WK request or call UIApplication URL opening.

Loading/error delegates control a spinner, retry label/button and error
presentation. Navigation policy reads URL scheme/host and performs string
tests; exact policy completeness/origin validation is not established.
JavaScript alert handling presents a native alert. Deallocation removes the
script handler and clears web delegates.

This is a **checkout JavaScript-to-native bridge**, not a demonstrated
CalcVault bridge or general downloader API. It is a separate attack surface:
origin/argument validation, external navigation, retained handlers and checkout
state deserve review. Inline playback and inspectability setters exist but
do not establish this surface's runtime configuration on every OS.
No purchase, subscription, account unlink or checkout was performed.

## Local storage, caches and maintenance

| State/data family | Static evidence | Important distinction |
|---|---|---|
| Feature settings | Standard defaults Boolean/integer writers/readers. | Not encrypted Vault storage or authentication. |
| Icon theme | Named defaults-suite calls and selected-theme fields. | Different from alternate-icon resources/main-bundle mutation fallback. |
| Language/region | Defaults-backed language/region selection. | Does not alter IP location or prove server-region eligibility. |
| License state | State-save/read/verification methods and structured state field names. | Exact protection/serialization requires tracing helpers; no credential values exported. |
| Device identity | FCUUID defaults/Keychain/migration/cloud-list routines; license requests call device UUID. | Not proof of hardware identity or actual iCloud availability. |
| Media | URLSession downloads, temporary file operations, image buffers, Photos writes/share UI. | Outside Vault encryption; composition can re-encode. |
| Caches | Cache-size enumeration, startup/now settings, delegate cache-clearing method. | Displayed size or selector name does not establish safe deletion scope. |
| Reset/cleaner | Added tab-bar alert/action methods for several wipe/reset levels and Keychain clearing. | Potentially destructive operations, not just cache cleanup. |

### Cleaner and reset surface

The tab bar receives `showCleanerOptions`, `showUnbanModeAlert` /
`performUnbanMode`, fast/deep wipe alerts/actions, Keychain-only wipe,
complete reset, `clearKeychain`, `clearDirectory:`, and success-alert
methods including a `shouldExit:` variant. These are part of the whole
add-on and were absent from the first media-focused reference.

No cleaner/reset action was run. Names such as “unban” do not establish an
ability to change a provider restriction. Deletion/identity-reset effects and
boundaries must be reconstructed from each body, never from the option label.
In a hosted guest, a process-wide reset or unscoped Keychain operation can
have a materially different impact than in a standalone app.

Two underlying helpers were traced beyond their names. `clearDirectory:`
(`0x1cea8`) accepts a directory enum, resolves the first user-domain path through
`NSSearchPathForDirectoriesInDomains`, enumerates its children and invokes
`removeItemAtPath:error:` on them. No add-on-owned subdirectory restriction was
established in that body. `clearKeychain` (`0x1ccc8`)
loops the five Security item classes (generic password, Internet password,
certificate, key and identity), builds a query containing only the current
item class, and calls `SecItemDelete` for each. No service, account or access-group
filter appears in that helper. This is class-wide deletion **within the caller's
OS-authorized Keychain access**, not proof it can delete every app's secrets.
It is also not a narrowly scoped TTKillerPlus cache operation. No deletion was
attempted and entitlement-dependent effects were not tested.

The confirmation handlers dispatch cleanup work asynchronously. Traced worker
blocks distinguish the reset levels:

| Action | Worker locator | Reconstructed local effects |
|---|---|---|
| Fast wipe | `0x39df0` | Directory enums9/13/5 (Documents/Caches/Library), temporary-path enumeration/removal and main-bundle/suite defaults clearing. |
| Deep wipe | `0x3a190` | Directory enums9/13/5, class-wide Keychain helper and main-bundle/suite defaults clearing; temporary-directory enumeration was not seen in this block. |
| Complete reset | `0x3a638` | Directory enums9/13/5/14 (adds Application Support), temporary-path removal, Keychain helper and main-bundle/suite defaults clearing. |
| Unban action | Added action `0x1abb0` | Main-bundle/suite defaults clearing; no evidence of changing a server-side restriction. |

These are standard process-visible data locations, not proven tweak-private
folders. The routines can remove unrelated app data within the process's
effective filesystem access. In an embedded guest, actual container remapping
and entitlements determine the damage scope; these were not tested by this
study. Do not expose the original cleaner actions to Vault data.

Cache-size calculation enumerates a URL with file-size/directory resource keys
and sums sizes, then formats a byte count. Manual clear and startup-clear
controls are declared separately. Neither is evidence that the encrypted
Vault can safely be placed in any tweak-visible directory.

The delegate's `clearCaches` (`0x17fbc`) checks preference/date state and schedules
a block, but its deletion worker and target paths remain unresolved.
`sendInstallationStats` (`0x16cf4`) and `logActivation` (`0x174ec`) construct
requests with method/header/body setters, create URL-session tasks and resume
them. This establishes outbound reporting flows, not their purpose, payload,
endpoint policy or success. No request was sent. Authentication-state saving
has direct defaults/removal/synchronization evidence; nested helper writes
remain unresolved. FCUUID's use of UICKeyChainStore does not prove that license
state uses Keychain.

## Data flows and side effects across the add on

The principal paths are not all media paths:

```text
weak-loaded tweak -> startup registrations -> existing TikTok/platform classes
  settings UI -> preferences -> selected feature wrappers/UI/model interception
  activation UI -> device identity + remote check -> local authentication state
  checkout HTML -> WK script handler -> payment navigation/external URL
  selected media -> model URL/album selection -> download/composition -> Photos/share
  privacy switches -> selected profile/story/message read/report callbacks
  region selection -> defaults -> carrier/region inputs + profile presentation
  cleaner/reset UI -> local cache/data/identity/Keychain side effects
```

This map describes statically evidenced component relationships. It is not an
end-to-end tested sequence and does not mean every branch shares a single
authorization gate. The guest receives sensitive inputs for its own license
flows; CalcVault must never treat those inputs or identities as Vault credentials.

## Bundled PKCS#12 boundary and public references

Prior bounded research recorded in [the prior PKCS12 findings](EVIDENCE_AND_LIMITS.md#prior-pkcs12-findings) places a SessionCheck PKCS#12 resource in `MusicallyCore`, with resource/identity-import and network-challenge references there, not in `TTKPlus`. This is prior static evidence, not a new identity-use test. Its exact purpose remains unproven; it must not be treated as the TTKillerPlus license key. It was not decrypted or imported in this review. The localized strings file and public repository can corroborate names and UI vocabulary, but UI text does not prove implementation: [publisher's public repository](https://github.com/iKarwan/TTKillerPlus) and [English localization file](https://raw.githubusercontent.com/iKarwan/TTKillerPlus/main/en.lproj/Localizable.strings).

## Relationship to CalcVault and safe next probes

CalcVault's project rules prohibit unofficial social APIs, credential/cookie copying, and a JavaScript-to-native vault/filesystem bridge. They do not impose a blanket ban on every runtime hook: earlier native research has its own reviewed, narrowly pinned experimental scope. That scope is not blanket permission for new media extraction or privacy hooks. Existing browser downloads use host confirmation and bounded import into the vault; the native guest interface currently exposes lifecycle controls but no media event. These static findings do not expand the already approved package integration or authorize new hooks, arbitrary vault/filesystem access, or use of licensing/session material. Browser downloading and native private-model acquisition are separate trust decisions.

### Requested Vault destination: reusable host path, missing guest boundary

The following host-source observations refer to the research worktree under
`build/startup-diagnostics2`, not an assertion that the outer/root source tree
has the same native-integration revision.

The owner explicitly wants downloads inside the encrypted Vault rather than
Photos. TTKillerPlus's observed Photos save functions cannot provide that by
changing a display label or filename. The host already has the necessary final
import machinery:

- `CalcVault/App/AppCoordinator.swift`, `importFiles`, requires an active vault
  access, repository, stager, temporary-file manager, and session root key. Its
  staging and repository commits use cancellation and revocable session permits.
- `CalcVault/Vault/VaultFileStager.swift` performs coordinated regular-file reads,
  enforces the object-size bound, and checks exact copied length.
- `CalcVault/App/SocialDownloadView.swift` demonstrates confirmed browser media
  delivery into that importer, using protected host-owned temporary storage and
  a 1 GiB download limit. Its extension/MIME checks are not a complete validator
  for hostile native-guest input.
- `NativeGuestRuntime` and `CVLPGuestSession` expose presentation/start/revoke and
  diagnostics, not a selected-media callback or file-transfer endpoint.

A future independently written native feature would therefore require two
separate pieces: safely identify/acquire the owner's selected media in the guest,
then hand off only that media to the authenticated host. The host—not the
untrusted guest—must resolve a predetermined transfer location, validate and copy
the file, ask for confirmation under a current session, and encrypt it through
the existing repository. No arbitrary guest-supplied absolute path, vault path,
key, repository, credential, cookie, or generic command channel should cross.
An opaque one-use transfer ID and tightly bounded file transport are preferable
to sending a large media object through an unrestricted message interface.

Before real-media integration, synthetic tests need to reject symlinks/path
escapes, unsupported or mismatched media, empty/oversized/changing files, duplicate
or stale transfers, and post-lock callbacks. Lock/background must revoke pending
work and clean up only transfer copies, never source library originals. The
transport must not widen existing bookmarks/App Groups or add products/App IDs
without review. No such handoff was implemented or tested in this documentation
turn. The owner's requested subscription-free feature layer is a future goal,
not a demonstrated implementation; this reference is not permission to copy
paid code or patch activation.

If future research is authorized, prioritize owner-assisted synthetic/no-account validation of: (1) feed versus Explore/story controller coverage; (2) download completion, HTTP error/redirect/content-type/size handling and all cleanup branches; (3) Photos permission denial and partial saves; (4) album-picker index and cached-image fallback ordering; and (5) compatibility of each private class/selector and ABI against a specifically preserved target build. No real account credentials or private media are needed to inspect local branches; live behavior requires a deliberate owner-operated test and must be reported separately from static evidence.

No exact source coverage percentage, complete source reconstruction, legal conclusion, compatibility certification, security certification, or successful device behavior is claimed here.
