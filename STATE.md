# psion5Ios — state as of 2026-10-28

## What this is
A native iOS app that runs WindEmu (the Psion 5mx emulator) full screen and landscape,
built for the iPhone Duo with a Bluetooth folding keyboard. It also has a Psion-style
Claude app that answers questions on the Psion's screen and can type the answer into
the Psion app you were using. Public at https://github.com/jhammant/psion5Ios.

## Where it stands
Done:
- The emulator app: hardware keyboard bridge, full screen on both Duo displays, camera-cutout aware.
- The Claude app: your own API key in the Keychain, streamed answers (claude-opus-5-5), Ctrl+T types into the Psion.
- Claude's icon replaces Email on the Psion's silkscreen (cb744b6). Tap it or press Cmd+Return; any other icon closes it.
- TestFlight build 202610241050 uploaded (internal testers only, because the build bundles Psion's ROM).
- Tested end-to-end in the iPhone Duo simulator, folded and unfolded, against scripts/mock-claude.py.

Not yet tested:
- The real Anthropic API, and a real iPhone Duo.

Known oddity, not investigated:
- In the simulator, unfolded and held upright, the inner display showed the app in portrait
  (the Psion squeezed into the top third) despite the landscape-only setting. It predates the
  silkscreen change.

## Next steps
1. Install TestFlight build 202610241050 on the Duo and check the Claude icon and the Psion's own silkscreen icons respond to finger taps.
2. Ask Claude a real question with a real API key on the phone and Ctrl+T the answer into Jotter.
3. Check whether the unfolded inner display really renders portrait on the device; fix supportedInterfaceOrientations or the scene setup if it does.

## Open questions
- Should Claude stay in Email's slot, or take another icon's place (Sheet, Contacts)? Email was chosen because it can't work without a modem.

## Ideas worth keeping
- Rewrite a third-party SVG at load (DOMParser, swap one element, XMLSerializer, Blob URL) to
  re-skin artwork you can't redistribute, with a fallback to the original if the element isn't found.
- An overlay div above an Emscripten SDL canvas catches taps before the emulated machine sees
  them, so a host app can add its own hot zones to an emulator's touch surface.

---
_Updated by `forkcode close` on 2026-10-28T22:34+00:00_
