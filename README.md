<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Nightstand icon"></p>

# Nightstand

A modern, native Mac app for your e-book library. Organise your books, keep ratings and notes on what you
read, and send books to your e-reader — without the clutter.

- **Library** — cover grid or list, search, sort, and browse by series, author, tag or reading status.
- **Your reading life** — star ratings, reading status, finish dates and free-form notes for every book.
- **Edit details and covers** — title, authors, series, tags and more; drop an image on a book to change its cover.
- **Send to your e-reader** — plug in a Kobo or Kindle and send books in one click. Other readers that mount
  as a drive (PocketBook, Tolino, Nook…) can be added in Settings.
- **Built-in KEPUB conversion** — EPUBs are converted to Kobo's KEPUB format on the way to a Kobo, with your
  metadata, series and cover written in.
- **Formatting** — optionally restyle books as they are sent: base font size, line spacing, alignment,
  paragraph style, margins and hyphenation.
- **Import from Calibre** — brings over your books, covers, series, tags and ratings. Calibre is left untouched.
- **Clean up details** — fixes "Wong, Tao" style author names, pulls series out of titles like
  "Rebel Star (System Apocalypse Book 8)" and settles on one spelling per author and series. You review
  every change first.
- **Look up details online** — search Open Library and Google Books for a book and choose which details and
  cover to take. Runs only when you ask.
- **Import from Goodreads** — fills in ratings, read status, dates read, reviews and shelves for books you
  already have, from your Goodreads library export.

Supported formats: EPUB, KEPUB, PDF, MOBI, AZW3, AZW, FB2, CBZ, CBR, DjVu and TXT.

## Install

Download the latest `.dmg` from [Releases](../../releases), open it and drag Nightstand to Applications.
Requires macOS 14 or later.

Release builds are not notarised by Apple yet, so the first time you open the app macOS will block it:
open **System Settings → Privacy & Security** and click **Open Anyway**.

## How it works

Your library is a plain folder, `~/Nightstand Library`. Each book has its own folder holding the original
file and its cover, and `library.json` holds your details, ratings and notes. Back up that folder and you
have backed up everything.

Nightstand never modifies the files in your library. When you send or export a book it builds a fresh copy
with your metadata, cover and formatting applied, so you can change your mind and send again.

### Devices and conversion

| Reader | Detected | What gets sent |
| --- | --- | --- |
| Kobo | Automatically | EPUB → KEPUB (optional); PDF, MOBI, CBZ, TXT as they are |
| Kindle (models that mount as a drive) | Automatically | MOBI, AZW3, PDF, TXT as they are |
| PocketBook, Tolino, Nook, others | Add in Settings → Devices | EPUB and most other formats as they are |

Nightstand converts EPUB to KEPUB itself. For other conversions (for example EPUB to AZW3 for a Kindle) it
uses Calibre's `ebook-convert` if Calibre is installed; otherwise those books are skipped with a message.
Kindles released from 2024 onwards connect over MTP and do not appear as a drive on a Mac, so they cannot be
used over USB.

## Build from source

Requires Xcode 16 or later.

```bash
scripts/build-app.sh                    # dist/Nightstand.app for this Mac
scripts/build-app.sh --universal --dmg  # universal app and dist/Nightstand-<version>.dmg
swift test                              # unit tests
```

You can also open `Package.swift` in Xcode and run the `Nightstand` scheme. Set `NIGHTSTAND_LIBRARY` to use
a different library folder while developing.

## License

MIT — see [LICENSE](LICENSE).
