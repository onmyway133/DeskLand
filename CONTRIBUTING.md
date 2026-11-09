# Contributing

Thanks for helping out.

## Reporting a problem

Open an issue with:

- your macOS version and Mac model
- the theme you were using
- what you expected and what happened
- for icon layout problems: your Finder desktop icon size and whether Stage Manager is on

## Making a change

1. Fork the repo and create a branch.
2. Build with Xcode 27.2 and run the app.
3. Run snapshot mode and check both themes still render:
   `DESKLAND_SNAPSHOT=/tmp/deskland-shots DerivedData/Build/Products/Debug/DeskLand.app/Contents/MacOS/DeskLand`
4. Keep pull requests small and focused, with a short description of what changed and why.

## Theme pages

`WebContent/` holds upstream Deskland's theme pages. Prefer keeping them unchanged and handling macOS differences in the Swift host, so upstream updates stay easy to bring in. If a page has to change, list the change in `NOTICE`.

## License

By contributing, you agree that your contributions are licensed under GPL-3.0.
