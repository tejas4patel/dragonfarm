# Security

## Reporting a problem

Please do not open a public issue for a security problem. Email the
maintainer listed in the package’s DESCRIPTION file with what you found,
how to reproduce it, and which version you used. You will get an answer
as soon as possible; support is best effort, by one person.

## Supported versions

The latest release on CRAN and the `main` branch on GitHub.

## What dragonfarm does to keep you safe

The [threat model](https://dragonfarm.dev/architecture/threat-model.md)
lists what we defend against, how, what we measured, and what is still
open. In short: models are pinned and loaded from safetensors only;
Python packages are locked with hashes; agents can only do what the
policy allows, and training, promotion, deletion and anything that
leaves the machine wait for a person; everything that leaves the machine
passes one check and is recorded; the record cannot be edited through
dragonfarm or the database’s normal statements; keys live in the
operating system’s keychain.
