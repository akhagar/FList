# OurStock

A shared family list of what’s missing at home. Anyone in the household can add an item, then mark it back in stock when it’s on the shelf again.

OurStock is a native iPhone and iPad app. Lists sync over iCloud with [CloudKit](https://developer.apple.com/icloud/cloudkit/). Without iCloud, you can still keep a list on that device.

## Features

- One shared shortage list, with **Needed** and **Back in stock**
- Add a name, quantity, optional note, and photo
- Mark an item back in stock, with an optional note if something wasn’t as described — that note is sent to the person who added the item
- Cart button to tell the family you’re going shopping, so they can add anything that’s missing
- Pick missing items onto your own **To buy** list, so you know what you’ll get at the store
- Invite others with iCloud sharing (they keep their own Apple ID)
- Choose who gets a notification when someone adds a missing item
- Search Needed and Back in stock together
- Shared recipes: save a dish with groceries (what to buy, plus how this recipe uses it) and how to prepare it, then add those groceries to the missing list
- Paste a grocery list or a recipe from Notes or Messages, preview it, then save
- Light, dark, or system appearance, plus accent colors (this device only)
- English, Hebrew, and Russian, following the device language

## Using OurStock

1. Sign in to iCloud on the device (Settings → [Your Name] → iCloud).
2. Create a family list, or join one you were invited to.
3. Tap **+** when you run out of something, or **Paste items** for a whole list from Notes or Messages.
4. When it’s back, mark it **Back in stock**. You can leave a note for the person who asked for it.
5. Tap the cart when you’re heading to the store. You can pick items for **To buy**, or notify the family.

Open **Settings** (gear) to rename the list, edit people, choose who is notified about new items, and invite the rest of the family. The **Recipes** tab is for dishes the household cooks — adding groceries from a recipe uses the same merge as typing them on the list. You can also **Paste recipe**: first line is the title, then a short description, grocery lines such as `Tomatoes — 4 chopped`, then how to prepare.

### Inviting someone

1. In Settings, tap **Show invite code**.
2. Send the code in a message, or let the other person scan the QR in OurStock.
3. They paste the code (or scan the QR) and tap **Join**.

The code is the iCloud share token — the same as the old invite link, just shorter to type. A Messages invitation can expire and often can’t be pasted. Both devices need the same kind of build (Xcode or TestFlight). After they join, the list shows under **Shared** on their iCloud account — not as a second private copy.

Language is not chosen inside the app. Change it in **Settings → General → Language & Region**, or under **Settings → OurStock** if you set a language just for this app.

## Building

1. Open `FList.xcodeproj` in Xcode.
2. Select your development team.
3. Run on an iPhone or iPad signed into iCloud. Sharing and live sync work more reliably on a device than in the simulator.

| | |
| --- | --- |
| Bundle ID | `com.tocnet.FList` |
| CloudKit container | `iCloud.com.tocnet.FList` |
| Version | 1.4.2 |

The CloudKit container ID in `FList/AppConfig.swift` must stay in sync with the app entitlements. Debug builds use the Development environment; Release/TestFlight uses Production. New CloudKit record types or fields need a schema deploy in CloudKit Console before they work in Production.

Recipes and personal buy lists reuse the existing `ShortageItem` type and leave the `name` field empty, so phones still on 1.3.1 ignore them instead of showing them as groceries.

## Privacy

OurStock does not use tracking. List data lives in your iCloud account (and on the device as a local cache). Camera and photo library access are only for optional pictures of items, recipes, or people on the list.
