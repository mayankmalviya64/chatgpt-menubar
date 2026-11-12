# ChatGPT Bar

A small macOS menu bar app that keeps ChatGPT one shortcut away and can bring in the page you're reading.

- **⌥Space** (or the menu bar icon) shows / hides a ChatGPT window, bottom-right by default.
- Resizable; reopens exactly where you left it, at the same size.
- Log in once to your own ChatGPT account; uploads, voice, downloads all work.
- **Page context**: reads the page open in **Safari**, **Chrome**, or a PDF in **Preview**
  (your selected text if any, otherwise the main text) and puts it into the message box.
  - **Auto**: adds the page each time you open the window on a new page.
  - **Add page**: adds it on demand.
  - **👁 privacy switch**: turns all reading off. Per-app ticks are in the menu bar icon's right-click menu.

## Build

No Xcode project and no paid Apple developer account needed, just the Command Line Tools.

```sh
./build.sh
open "build/ChatGPT Bar.app"
```

## One-time setup

- Click **Allow** when macOS asks whether ChatGPT Bar may control Safari / Chrome / Preview
  (or System Settings → Privacy & Security → Automation).
- For web page **text** (not just title + link):
  - Safari: Settings → Advanced → "Show features for web developers", then Develop → "Allow JavaScript from Apple Events".
  - Chrome: View → Developer → "Allow JavaScript from Apple Events".
- The official ChatGPT app also uses ⌥Space; please change its shortcut if you use both.

Rebuilding changes the app's free local signature, so macOS may ask for the Automation permission again after a rebuild.
