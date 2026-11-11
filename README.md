# OurStock

A shared family list of what’s missing at home. Anyone in the household can add an item, then mark it back in stock when it’s on the shelf again.

OurStock is a native iPhone, iPad, and Apple Watch app. Lists sync over iCloud with [CloudKit](https://developer.apple.com/icloud/cloudkit/). Without iCloud, you can still keep a list on iPhone or iPad. Apple Watch talks to the same iCloud household directly — the iPhone does not need to be nearby.

## Features

- One shared shortage list, with **Needed** and **Back in stock**
- **Needed** and **To buy** widgets on iPhone and iPad, with small, medium, and large Home Screen layouts plus circular, rectangular, and inline Lock Screen layouts
- Add a name, quantity, optional note, photo, and which store you can buy it from
- Add a missing item with Siri or Shortcuts on iPhone and iPad
- As you type an item name on iPhone or iPad, get up to five matching suggestions from Back in stock, with items you originally added first. Tap a suggestion to fill the name, then tap Add to mark the existing item as Needed. Suggestions work offline and do not change your quantity, note, photo, or store selections.
- Scan a product barcode to look it up in Open Food Facts (worldwide and Israel), Open Beauty Facts, Open Pet Food Facts, Open Products Facts, UPC Item DB, and GS1, then add it to Needed. The Israel lookup requests Hebrew product details alongside the worldwide lookup in the app's language; both use the same Open Food Facts database and need no API key. SaveMyCart is used only if none of those catalogs have the barcode and a key has been added in Settings → Barcode lookup keys.
- Tap an item to mark it back in stock. Long-press to edit, or to leave a note if something wasn’t as described — that note is sent to the person who added the item
- Cart button to tell the family you’re going shopping, so they can add anything that’s missing
- Shared **Stores**: name and optional location. When you go shopping you can mention one or more shops. If you’re at a store, items tagged for it move to the top of Needed
- Pick missing items onto your own **To buy** list, so you know what you’ll get at the store
- Invite others with iCloud sharing (they keep their own Apple ID)
- Choose who gets a notification when someone adds a missing item
- Search Needed and Back in stock together
- Shared recipes: save a dish with groceries (what to buy, plus how this recipe uses it) and how to prepare it, then add those groceries to the missing list
- Paste a grocery list or a recipe from Notes or Messages, preview it, then save
- Light, dark, or system appearance, plus accent colors (this device only)
- Apple Watch: **Needed** list, tap to mark back in stock, and add an item (dictation). Recipes, stores, photos, invites, and settings stay on iPhone
- English, Hebrew, and Russian, following the device language

## Using OurStock

1. Sign in to iCloud on the device (Settings → [Your Name] → iCloud).
2. Create a family list, or join one you were invited to.
3. Tap **+** when you run out of something, **Scan barcode** to look up a package, or **Paste items** for a whole list from Notes or Messages.
4. When it’s back, tap the item. Long-press to edit it, or to leave a note for the person who asked for it.
5. Tap the cart when you’re heading to the store. You can pick items for **To buy**, or notify the family — and optionally say which shop or shops you’re going to.

Open **Settings** (gear) to rename the list, manage **Stores**, edit people, choose who is notified about new items, and invite the rest of the family. The **Recipes** tab is for dishes the household cooks — adding groceries from a recipe uses the same merge as typing them on the list. You can also **Paste recipe**: first line is the title, then a short description, grocery lines such as `Tomatoes — 4 chopped`, then how to prepare.

### Inviting someone

1. In Settings, tap **Show invite code**.
2. Send the code in a message, or let the other person scan the QR in OurStock.
3. They paste the code (or scan the QR) and tap **Join**.

The code is the iCloud share token — the same as the old invite link, just shorter to type. A Messages invitation can expire and often can’t be pasted. Both devices need the same kind of build (Xcode or TestFlight). After they join, the list shows under **Shared** on their iCloud account — not as a second private copy.

On Apple Watch, OurStock shows the same Needed list. Tap an item to mark it back in stock; use **+** to add a name. Create or join the family list on iPhone first, and sign in to the same iCloud account on the Watch.

Language is not chosen inside the app. Change it in **Settings → General → Language & Region**, or under **Settings → OurStock** if you set a language just for this app.

### Widgets

Open OurStock once after installing this version and select your list. Then use the Home Screen's **Edit → Add Widget**, search for **OurStock**, and choose **Needed** or **To buy**. You can also add the compact versions when customizing the Lock Screen. Tap a widget to open its matching list, including if the app was showing recipes or settings. Widget labels follow the app language selected in iPhone/iPad Settings; Hebrew uses right-to-left layout.

Widgets show the currently selected household and your personal To buy selections. They display the latest data saved by the app, including quantities. The app requests an update after saving changes or receiving a background sync; unchanged polls do not request extra updates. iOS controls widget refresh timing, and widgets do not independently fetch from CloudKit. If another person's change hasn't synced yet, open OurStock to refresh. These are list previews: marking items back in stock still happens inside the app.

The extension reads a small snapshot from the App Group `group.com.tocnet.FList`, without photos, notes, or credentials. Existing local files and CloudKit records stay compatible with older releases. Leaving or deleting the selected list clears both widgets. This extension targets iPhone/iPad; the existing Watch app is unchanged.

Before running on a physical device or archiving, select the same development team for **FList** and **FListWidgets**. In **Signing & Capabilities → App Groups**, register/select `group.com.tocnet.FList` for both targets (Debug and Release entitlements are already included). The extension bundle ID is `com.tocnet.FList.widgets`; automatic signing must provision it and the shared group. No CloudKit schema deployment or paid service is needed.

Run local snapshot and link-routing checks:

```sh
xcrun swiftc -parse-as-library FList/L10n.swift FList/Models/ShortageItem.swift FList/Widgets/WidgetSnapshot.swift FList/Widgets/WidgetSnapshotBuilder.swift FList/Widgets/WidgetSnapshotStore.swift Tests/WidgetSnapshotTests.swift -o /tmp/ourstock-widget-tests
/tmp/ourstock-widget-tests
```

### Siri and Shortcuts

Open OurStock once and create or select your household. Then say **“Hey Siri, add an item in OurStock.”** Siri asks which item you need. This action opens OurStock and adds one of that item to the currently selected list. You may need to unlock the device. In Shortcuts, find **OurStock → Add missing item** to supply an item name and an optional quantity from 1 to 999.

**“Hey Siri, add missing item to OurStock”** is also registered explicitly, along with variants using “a missing item” and “in OurStock.” Install this build and open OurStock once before testing a newly added phrase. If Siri says it cannot add items directly to the app, first run **Add missing item** by tapping it in Shortcuts. If it is absent, the installed build or its shortcut registration needs checking. If tapping works but speaking does not, check the exact phrase and Siri language; the refusal alone does not establish that saving failed.

To omit the app name when speaking, create a personal shortcut once on your iPhone:

1. Open **Shortcuts**, tap **+**, and add the **OurStock → Add missing item** action.
2. Set **Item name** to **Ask Each Time**, and leave **Quantity** at **1**.
3. Give the personal shortcut a distinctive name, such as **Family basket**, and save it.
4. Try **“Hey Siri, run Family basket.”** Once the shortcut starts, answer its item-name prompt.

You can instead name it **סל משפחתי** or **Семейная корзина** to match your Siri language. Apple requires the app name in an app's built-in [App Shortcut phrases](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts), but personal shortcuts can be [invoked by their chosen name](https://support.apple.com/en-mide/guide/shortcuts/apd07c25bb38/ios). This is a two-step conversation: say the shortcut name, then answer with the item. The action still opens OurStock and may require unlocking the device.

If the action is still displayed as **Add missing item** after changing Siri to Hebrew or Russian, you can use it as-is: the action's display label does not restrict the language of item names. Siri's language setting does not automatically translate the Shortcuts interface or rename a saved shortcut. Create a personal shortcut using the action, set **Item name → Ask Each Time**, then use the shortcut editor's **Rename** command to give your personal shortcut a Hebrew or Russian name. The action inside it can keep its English label. For Hebrew, name the personal shortcut **סל משפחתי**, then try **“סירי, הפעילי את הקיצור סל משפחתי”** and answer the item prompt with **חלב**. See [Apple's shortcut-renaming instructions](https://support.apple.com/en-euro/guide/shortcuts/apdd57094696/ios).

If tapping the saved shortcut works but Siri tries to add a reminder, the voice request is being routed to a different action. Renaming the personal shortcut and explicitly asking Siri to run it is a diagnostic step, not a guaranteed fix. Wait until the shortcut asks for the item before saying its name. If routing still fails, compare the exact shortcut name with Siri's transcription, then try typing that same request to Siri: a successful typed request narrows the issue to speech recognition; failure of both leaves shortcut matching or registration to investigate. Do not infer a CloudKit save failure from a request that never started OurStock's action.

An item already in Needed gets its quantity increased. An item in Back in stock moves to Needed, with you as its author. Existing notes, photos, and store tags are retained. Siri confirms only after saving; an unavailable iCloud list produces an error instead of saving to a different list or a local copy. If a save cannot be confirmed, check the list before retrying.

Prompts and shortcut phrases are included in English, Hebrew, and Russian. The Siri app-name aliases are **Our Stock**, **אורסטוק**, and **Аурсток**; the visible app name remains OurStock. Use a phrase in Siri's configured language, then answer its item-name prompt:

- Hebrew: **“הוסיפי פריט חסר לאורסטוק”**, then **“חלב”** or **“גבינה לבנה”**.
- Russian: **“Добавь товар в Аурсток”**, then **“молоко”** or **“сметана”**.
- English: **“Add missing item to OurStock”**, then the item name.

Set Siri's language under **iPhone Settings → Siri (or Apple Intelligence & Siri) → Language**, as described in [Apple's language settings guide](https://support.apple.com/en-ie/120499). Changing OurStock's app language alone does not select Siri's speech-recognition language. The app accepts Hebrew, Russian, English, and mixed-script names regardless of its display language and preserves the text it receives; it does not translate item names. Recognition of multiple spoken languages in the same session depends on Siri and isn't guaranteed by the app. The earlier Shortcuts registration check still applies if Siri refuses to run the action before asking for an item.

This implementation is for iPhone and iPad, and uses the existing CloudKit records without a schema change or separate service.

Run item-merging, selected-list, and local-save regression checks:

```sh
xcrun swiftc -parse-as-library FList/L10n.swift FList/AppConfig.swift FList/Models/ShortageItem.swift FList/Models/ItemAddition.swift FList/Models/ItemShortcutRequest.swift FList/Models/ItemNotificationEvent.swift FList/Models/FamilyMember.swift FList/Models/Recipe.swift FList/Models/Shop.swift FList/Store/CloudKitService.swift FList/Store/LocalPersistence.swift Tests/ItemShortcutTests.swift -o /tmp/ourstock-siri-tests
/tmp/ourstock-siri-tests
```

Before release, test spoken invocation on a physical device in each supported language, including a cold launch, a locked device, an invited household, a renamed profile, and an unavailable network. Verify the Shortcuts action also works with an explicit quantity. Build and model checks do not verify Siri recognition or production iCloud connectivity.

### Notifications

In Settings, enable **General list update alerts** to receive a visible CloudKit alert before the app finishes synchronizing. This uses the existing iCloud setup: there is no additional server, subscription, or hosting service. The option is off by default and applies to this iCloud account's devices for the selected private/shared database. It covers changes across those lists, including recipes and settings; the recipient switches below it apply to detailed new-item messages, not these general alerts.

While the app is open, synchronization generates detailed messages instead of a second general banner. When general alerts are enabled, background/catch-up synchronization does not repeat the same activity as detailed alerts. With general alerts off, invited-member and restock notifications still depend on iOS allowing background execution. Neither mode overrides disabled notifications, Focus, or Apple's delivery limits.

Item status changes now save an immutable notification event in the same CloudKit transaction as the item. Events use the existing `ShortageItem` record type and `note` field, with no `name` or `addedByRecordName`, so 1.4+ clients ignore them. New clients retain status-comparison fallback for older writers. Event-based delivery preserves the actual person who changed an item, intermediate changes between syncs, and restock notes. Duplicate history is scoped to the household and account and survives relaunches.

Apple Watch registers for CloudKit pushes and refreshes its cache in the background when watchOS grants execution. It preserves the iPhone-configured subscriptions. Notification presentation on a paired Watch remains subject to Apple's iPhone/Watch routing and notification settings.

If notification setup fails, Settings shows a **Retry** button. Developer diagnostics are logged under `com.tocnet.FList` with the categories `Notifications`, `CloudKitNotifications`, `NotificationSync`, and `WatchNotifications`. Do not assume a successful item save means that another person's device displayed an alert.

### Notification regression checks

Run the device-independent compatibility and recipient-rule checks from the project folder:

```sh
xcrun swiftc -parse-as-library FList/L10n.swift FList/AppConfig.swift FList/Models/ShortageItem.swift FList/Models/ItemNotificationEvent.swift Tests/NotificationRegressionTests.swift -o /tmp/ourstock-notification-tests
/tmp/ourstock-notification-tests
```

The CloudKit record-encoding checks also run locally, without signing in or contacting iCloud:

```sh
xcrun swiftc -parse-as-library FList/L10n.swift FList/AppConfig.swift FList/Models/ShortageItem.swift FList/Models/ItemNotificationEvent.swift FList/Models/FamilyMember.swift FList/Models/Recipe.swift FList/Models/Shop.swift FList/Store/CloudKitService.swift Tests/CloudNotificationRecordTests.swift -o /tmp/ourstock-cloud-record-tests
/tmp/ourstock-cloud-record-tests
```

Before shipping, test with two Apple IDs on physical devices: owner and invitee, foreground and locked, new items and repeated needed/restocked transitions, restock notes, shopping announcements, general alerts on/off, and a phone still running 1.4+. Also verify Watch refresh with the phone app closed and notification permissions denied/re-enabled. Simulator builds and the regression checks do not verify production CloudKit subscriptions or APNs delivery.

## Building

1. Open `FList.xcodeproj` in Xcode.
2. Select your development team.
3. Run on an iPhone or iPad signed into iCloud. Sharing and live sync work more reliably on a device than in the simulator.
4. To run the Watch app, choose the **FListWatch** scheme and a Watch destination. The Watch target is also embedded in the iPhone app, so an iPhone install includes OurStock for Watch.

| | |
| --- | --- |
| Bundle ID | `com.tocnet.FList` |
| Watch bundle ID | `com.tocnet.FList.watchkitapp` |
| CloudKit container | `iCloud.com.tocnet.FList` |
| Version | 1.6.9 |

The CloudKit container ID in `FList/AppConfig.swift` must stay in sync with the app entitlements. Debug builds use the Development environment; Release/TestFlight uses Production. New CloudKit record types or fields need a schema deploy in CloudKit Console before they work in Production.

Recipes, personal buy lists, and stores reuse the existing `ShortageItem` type and leave the `name` field empty, so phones still on 1.4 (and 1.3.1) ignore them instead of showing them as groceries. Store tags on items are extra JSON next to the existing restock note, which 1.4 already hides from the item text.

## Privacy

OurStock does not use tracking. List data lives in your iCloud account (and on the device as a local cache). Camera and photo library access are only for optional pictures of items, recipes, or people on the list, invite QR codes, and product barcodes. Scanning a barcode sends the number to Open Food Facts (worldwide and Israel food catalogs, beauty, pet food, and household catalogs), UPC Item DB, and GS1. If none of those have the product and a SaveMyCart key is configured, it is sent to SaveMyCart. Add the key in Settings → Barcode lookup keys ([SaveMyCart developer portal](https://savemycart.net/developers)); it is shared with the iCloud list or stored in this device's Keychain for local-only lists. Optional `SaveMyCartAPIBaseURL` defaults to `https://savemycart.net`. Location is used on this device only, to recognize when you’re at one of your stores and sort that shop’s items to the top.
