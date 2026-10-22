# OurStock

A shared family list of what’s missing at home. Anyone in the household can add an item, then mark it back in stock when it’s on the shelf again.

OurStock is a native iPhone, iPad, and Apple Watch app. Lists sync over iCloud with [CloudKit](https://developer.apple.com/icloud/cloudkit/). Without iCloud, you can still keep a list on iPhone or iPad. Apple Watch talks to the same iCloud household directly — the iPhone does not need to be nearby.

## Features

- One shared shortage list, with **Needed** and **Back in stock**
- Add a name, quantity, optional note, photo, and which store you can buy it from
- Scan a product barcode to look it up in Open Food Facts, Open Beauty Facts, Open Pet Food Facts, Open Products Facts, UPC Item DB, and GS1, then add it to Needed. SaveMyCart is used only if none of those catalogs have the barcode. SaveMyCart and Barcode Lookup run only if you add API keys in Info.plist
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
| Version | 1.6.4 |

The CloudKit container ID in `FList/AppConfig.swift` must stay in sync with the app entitlements. Debug builds use the Development environment; Release/TestFlight uses Production. New CloudKit record types or fields need a schema deploy in CloudKit Console before they work in Production.

Recipes, personal buy lists, and stores reuse the existing `ShortageItem` type and leave the `name` field empty, so phones still on 1.4 (and 1.3.1) ignore them instead of showing them as groceries. Store tags on items are extra JSON next to the existing restock note, which 1.4 already hides from the item text.

## Privacy

OurStock does not use tracking. List data lives in your iCloud account (and on the device as a local cache). Camera and photo library access are only for optional pictures of items, recipes, or people on the list, invite QR codes, and product barcodes. Scanning a barcode sends the number to Open Food Facts (food, beauty, pet food, and household catalogs), UPC Item DB, and GS1. If none of those have the product, it is sent to SaveMyCart. SaveMyCart needs `SaveMyCartAPIKey` (free key from [savemycart.net/developers](https://savemycart.net/developers); `X-API-Key`). Optional `SaveMyCartAPIBaseURL` defaults to `https://savemycart.net`. Barcode Lookup needs `BarcodeLookupAPIKey`. Location is used on this device only, to recognize when you’re at one of your stores and sort that shop’s items to the top.
