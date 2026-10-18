# For IT and quality teams

Someone on your team wants to train a model on your documents. Before
you say yes, you will want to know where things run, what is kept, what
leaves the building, who decides, and what the record shows afterwards.
This page answers those questions, and says plainly what is not there
yet.

## Where it runs

Everything runs on the machine where R runs: a laptop, a workstation, or
a Posit Connect server. The models are open-weight models from Hugging
Face, pinned to exact versions, loaded from safetensors files only. The
Python side runs in its own environment, built from a lock of pinned
packages with hashes (see [Install without the
internet](https://dragonfarm.dev/articles/offline-install.md)).

Nothing needs a dragonfarm server. There is no dragonfarm cloud service.

## What is kept

All of it sits in one folder, the runs folder:

- document sets: the text read from your files, cut into chunks, and a
  search index;
- training runs: the data used, the settings, the trained adapter, the
  evaluation;
- a catalogue: a small database of what happened.

On a laptop the catalogue is a SQLite file in that folder. A team can
point everyone at one Postgres database instead, with one setting.

## What leaves the machine

Nothing, unless someone chooses a service that is elsewhere:

- asking Claude to judge or write questions (Anthropic);
- reading a web page as a document;
- publishing a model to Hugging Face;
- a model server on another machine;
- a free-tier model provider, after a person has opted in, with a daily
  cap;
- training on a cloud GPU (Kaggle, Lightning AI), with the user’s own
  key.

Every one of these goes through one check first. It is written to the
record (where, why, how much), and an admin can limit the hosts it may
reach, down to none at all.

## Who decides

A policy says what each automated helper (agent) may do. Training a
model, proposing a model version, deleting, and anything that leaves the
machine wait for a person. People see these requests in a “Waiting for
you” card: approve, and it runs in their name; decline, and it never
runs.

Only an admin changes the policy, in the app or from R. Every change is
a new version with who made it and why; older versions stay readable.

A trained model becomes a numbered version of a named model only when a
person signs it off, with what the approval means (“approved for
answering questions on our SOPs”). The policy can require that the
signer is not the person who proposed it.

## What the record shows

The catalogue keeps an entry for each:

- tool call, with its arguments and a fingerprint of the result;
- answer from documents, with the exact chunks, the reader version, the
  model and its pinned version, the settings, every excerpt shown to the
  model, and the answer;
- approval request and decision;
- policy version, model version and sign-off;
- call that left the machine;
- check for personal data (counts only, never the values).

The database refuses to change or delete these entries. That holds for
SQLite and for Postgres.

## Checking and reproducing

- **Re-read check.** A document set can be read again and compared with
  what was saved. On our own sets, including ones made by older versions
  of the reader, they came back byte for byte.
- **Replay.** A recorded search, answer or agent task can be run again
  and compared with the original. When it differs, the record says
  whether the documents were re-read or the model changed.
- **Personal data.** A set can be checked for email addresses, phone
  numbers, US social security numbers, card numbers, and labelled dates
  of birth and patient or record ids, by fixed patterns. Every hit is
  listed for a person to judge.

## Keys

Keys for outside services are kept in the operating system’s keychain
(Windows Credential Manager, macOS Keychain), never in scripts or
project files. A key set by an admin in the environment takes
precedence.

## Not there yet

- **Identity.** The record names the operating system user. There is no
  link to single sign-on yet, so a sign-off is not an electronic
  signature in the sense of 21 CFR Part 11.
- **Validation.** There is no validation pack. The building blocks
  (pinned models and packages, re-read checks, replay, an append-only
  record) are what such a pack would rest on.
- **Personal data.** Names, street addresses and non-US national
  identifiers are not detected.
- **Planted instructions.** Text inside a document can still steer an
  answer now and then. Our larger models resist it better than our
  smaller ones, and no helper can act outside its policy, but answers
  should be read with their sources.
- **Encryption.** Files are protected by the machine’s own disk
  encryption and permissions; dragonfarm adds none of its own.
