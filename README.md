# Felix

Menu-bar autocorrect for macOS. Fixes typos as you type, with a subtle glow under corrected words.

- **Local only:** no cloud or saved typing history.
- **Early prototype:** app support varies, and corrections can be wrong.

## Download

**[Download for Apple Silicon](https://github.com/deanosmith/felix/releases/download/v0.1.0/Felix-0.1.0-macOS-arm64.zip)** (macOS 13+).

Unzip and move Felix to Applications. Not notarized: see the [first-launch instructions](https://github.com/deanosmith/felix/releases/tag/v0.1.0).
Enable **Accessibility** access and allow **Input Monitoring** if prompted.

## Features

- Custom replacements more advanced than macOS's native keyboard replacements.
- Learned words to ignore.
- Choose which apps get corrected via inclusion or exclusion lists.
- Custom correction glow colour.

## Build from source

Requires **macOS 13+** and **Swift 6+**. Also an option for Intel Macs.

```sh
git clone https://github.com/deanosmith/felix.git
cd felix
zsh scripts/build-app.sh
open dist/Felix.app
```
