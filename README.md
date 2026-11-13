# GPT Menubar

A small macOS menu bar app that keeps ChatGPT one shortcut away and can bring in what you're
reading or listening to. (Formerly called "ChatGPT Bar"; settings carry over automatically.)

- **⌥Space** (or the menu bar icon) shows / hides a ChatGPT window, bottom-right by default.
- Resizable; reopens exactly where you left it, at the same size.
- Log in once to your own ChatGPT account; uploads, voice, downloads all work.
- **Page context**: reads
  - the page open in **Safari**, **Chrome** or **Microsoft Edge** (your selected text if any, otherwise the main text),
  - a PDF in **Preview**,
  - the song playing in **Spotify** (track, artist, album, position, link),
  - the song playing on **YouTube Music** (music.youtube.com in Safari, Chrome or Edge: track, artist / album,
    position, and the lyrics if the Lyrics tab has them),

  and puts it into the message box.
  - **☑ checkbox** (start of the toolbar): ticked when the current page / song has been read into the
    message box, unticked otherwise. Click it to add the page.
  - **Auto**: adds the page each time you open the window on a new page or song.
  - **Ask about a selection**: select text in Safari, Chrome, Edge or Preview → right-click → **Ask ChatGPT**
    (under Services if macOS groups it there). The selection is sent with the whole page/PDF as
    background, and the cursor waits for your question. ⌥Space with text selected in a browser does the same.
  - Turn all reading off, or untick single apps, from the menu bar icon's right-click menu
    (*Read Pages from Apps*).

## Privacy

- **Private windows are never read.** Chrome Incognito and Edge InPrivate are detected directly. Safari Private is
  detected through macOS Accessibility (grant it once); without that permission Safari is simply not read (fail-safe).
  In a private window, right-click → Ask ChatGPT sends **only the text you selected**, never the page, title or link.
- **Blocked sites** (email, banks, payments, password managers, health, sign-in pages…) are treated the same way.
  Edit the list from the menu bar icon's right-click menu → *Edit Blocked Sites…*
- **Temporary Chat by default**: every new chat (app start and New Chat ⌘N) opens as a ChatGPT Temporary Chat
  (not saved to history or memory), and page context always goes into one. Switch off from the right-click menu →
  *Always Start in Temporary Chat*.
- **Hidden details**: emails, phone numbers, card numbers, 12-digit ID numbers and link tokens (`?…`) are
  masked in page text before it is inserted. Your own selected text is sent as-is.
- Spotify only shares the song details (no private-session detection is possible through Spotify's AppleScript).
- All of these can be switched in the right-click menu.

## Build

No Xcode project and no paid Apple developer account needed, just the Command Line Tools.

```sh
./build.sh
```

This builds the app and installs it as **/Applications/GPT Menubar.app** (or ~/Applications if /Applications
isn't writable). To open it:

- **Spotlight**: ⌘Space → type `GPT Menubar` or `ChatGPT menu bar` → Return
- **Finder**: Applications → GPT Menubar
- **Terminal**: `open "/Applications/GPT Menubar.app"`

It has no Dock icon; look for the speech-bubble icon in the menu bar (top-right), or press **⌥Space**.

## One-time setup

- Click **Allow** when macOS asks whether GPT Menubar may control Safari / Chrome / Edge / Preview / Spotify
  (or System Settings → Privacy & Security → Automation).
- For web page **text** (not just title + link), including YouTube Music:
  - Safari: Settings → Advanced → "Show features for web developers", then Develop → "Allow JavaScript from Apple Events".
  - Chrome / Edge: View → Developer → "Allow JavaScript from Apple Events".
- The official ChatGPT app also uses ⌥Space; please change its shortcut if you use both.

Rebuilding changes the app's free local signature, so macOS may ask for the Automation permission again after a rebuild.
