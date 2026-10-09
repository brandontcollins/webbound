# WebBound

Turn public web stories into clean, well-structured EPUBs.

WebBound is a command-line utility that takes the URL of a freely
accessible book or webnovel and turns its chapters into a polished EPUB.
It focuses on removing unwanted page content, correcting extraction
artifacts, and organizing chapters into a comfortable reading experience.

## Project status

WebBound is under development. Installation instructions, command syntax,
and supported sources will be documented as the implementation stabilizes.

## Goals

- Extract book and chapter content from supported public websites.
- Remove navigation, advertisements, repeated boilerplate, and other
  non-story content.
- Clean up extraction artifacts while preserving the author's text.
- Preserve chapter order, titles, and meaningful formatting.
- Generate a well-formatted EPUB with a navigable table of contents.
- Provide a straightforward command-line workflow.

## Intended workflow

1. Provide the URL of a book or webnovel.
2. WebBound discovers and retrieves its chapters.
3. Chapter content is extracted, cleaned, and organized.
4. The finished book is packaged as an EPUB.

Source support and extraction quality will depend on the structure of
each website. WebBound is not intended to rewrite or summarize stories.

## Installation and usage

Coming soon.

## Responsible use

WebBound is intended for content you are authorized to download and
convert. Free public access does not necessarily mean a work is in the
public domain or may be redistributed.

Respect authors' rights, applicable website terms, and reasonable request
rates. Do not use WebBound to bypass paywalls or access controls.

## Contributing

The project is in its early stages. Bug reports, source-support requests,
and improvements to extraction, cleanup, and EPUB formatting are welcome.

When reporting an extraction issue, include:

- The source URL.
- What went wrong.
- What the expected output should look like.
- A small example, when you are permitted to share it.

## License

WebBound is licensed under the MIT License. See [LICENSE](LICENSE) for
the full text.

This license applies to WebBound's software, not to books or other content
processed with it. Those works remain subject to their respective rights
and licenses.
