# Raise your own dragon.

![The dragonfarm dragon: a minimal orange dragon head in profile, with
amber horns and neck spikes](dragon.svg)

R package · on CRAN · MIT licensed · mostly fireproof

Turn your documents into an AI model you own, without leaving RStudio.
Check its answers against their sources, review the practice questions
it writes, and train on your own GPU or a free cloud one. No Python to
write, no API bill, and nothing leaves your machine unless you allow it.

`install.packages("dragonfarm")`

Copy

[Start hatching](https://dragonfarm.dev/articles/quickstart.md) [View on
GitHub](https://github.com/tejas4patel/dragonfarm)

![](data:image/svg+xml;base64,PHN2ZyBpZD0iZGYtc3RlcHBlciIgcm9sZT0iaW1nIiBhcmlhLWxhYmVsPSJUaGUgc2l4IHN0ZXBzOiBEb2N1bWVudHMsIEFzaywgVGVhY2gsIFRyYWluLCBNb25pdG9yLCBUcnkgaXQiPjwvc3ZnPg==)

*dragon_app()*

![Step 1, Documents: a set of PDFs and pages read into
chunks](demo/01-documents.png)![Step 2, Ask: an answer with numbered
sources under it](demo/02-ask.png)![Step 3, Teach: generated questions
grouped by chunk, with checkboxes and the reasons for rejected
ones](demo/03-teach.png)![Step 4, Train: training settings with the
training rows built from the reviewed
questions](demo/04-train.png)![Step 5, Monitor: the loss curve of a
finished run](demo/05-monitor.png)![Step 6, Try it: the fine-tuned and
base model replies side by side, each with sources](demo/06-tryit.png)

Why raise one here

## Own your model. Don’t rent one.

The AI tools in your IDE rent someone else’s model. dragonfarm raises
one that is yours, from the documents you already have, without a
training set or a Python setup.

Own, don’t rent

### Your documents become your model

It reads your documents and writes practice questions and answers; you
keep the good ones, then train. A 7B model fits an 8 GB laptop GPU, and
no GPU means a free one in the cloud.

Your workflow

### Never leave RStudio

Clicks and drag and drop in an RStudio add-in, and every step is also an
R function. Unsloth is built in: fine-tuning ran 1.5 to 2.8 times faster
than the standard trainer on the same laptop.

Built for audits

### Answers you can check

Every answer comes with its sources, and it says “not covered” rather
than guess. Answers are recorded and can be replayed, and nothing leaves
your machine unless you allow it.

Using ellmer or ragnar? dragonfarm is the next step after RAG: training
your own model from the same documents. Its tools also plug into ellmer
and MCP.

Same dragon, same ticket

## Teach it some manners.

A 0.5B-parameter model, before and after training on 190 example support
tickets. This ticket was not in the training data. It is the median of
the 10 held-out tickets by word overlap with the reference reply, and
both replies are at temperature 0.

**Ticket**Lumen bulb pack arrived damaged. Opened my Lumen bulb pack
today and the casing is split. The packaging looked fine from the
outside so it must have happened before shipping.

Wild dragon (base model)I’m sorry to hear that your Lumen bulb pack has
been damaged. It’s important to take any damage seriously and report it
to the manufacturer or seller as soon as possible. Here are some steps
you can follow: 1. **Contact the Manufacturer**: Reach out to the
company that sold you the Lumen bulb pack. They may be able to provide a
replacement or offer a repair service. 2. **Report the Damage**: …
(shortened)

Trained dragon (after fine-tuning)I’m sorry your Lumen bulb pack arrived
damaged. We will replace it at no cost. Please reply with a photo of the
damage and one of the shipping label so we can file the carrier claim on
our side. As soon as we have those, we ship a replacement Lumen bulb
pack with a prepaid return label for the damaged unit. Usually a
business day after the return is scanned in.Policy and tone are right.
The last sentence mixes in a detail from another ticket type (the real
policy is two business days), which is why small models still need
review.

The example tickets are synthetic and built from templates, so this
shows a model picking up a house style and policy, not open-ended
reliability. Use your own data and check the output before relying on
it.

Three ways to hatch one

## Pick your nest.

Documents first, a table if you have one, the cloud if your laptop is
more pebble than volcano. Everything the app does is also an R function,
and every dragon lives in a plain folder you can inspect.

Documents

### Feed it, then teach it

Drop in files or pages, ask anything, review the practice questions it
writes, fine-tune.

    docs <- dragon_documents("policies/")
    dragon_ask(docs, "How long is the
      return window?")
    qa <- dragon_questions(docs)   # review
    run <- dragon_train(
      dragon_questions_dataset(qa, docs),
      "Qwen/Qwen2.5-0.5B-Instruct")

App

### No code, no fire hazard

Opens on Documents: drop files, ask, review the practice questions,
train, try, chat. Have a table instead? One link switches to the
drag-and-drop route.

    library(dragonfarm)
    dragon_app()

Cloud

### No GPU? Borrow a volcano.

Send the run to a free Colab or Kaggle GPU and bring the dragon home.
Colab trains the example in about four minutes.

    run <- dragon_bundle(tickets,
      "Qwen/Qwen2.5-0.5B-Instruct")
    dragon_remote(run, "colab")
    dragon_import(run, "results.zip")

Advanced dragon training

## When one lesson isn’t enough.

Preference tuning, reinforcement learning with rewards you can check,
judges, chat, and publishing to the Hugging Face Hub. Treats and tough
love, both included.

[](https://dragonfarm.dev/articles/post-training-loop.md)

### Fine-tune, judge, prefer, repeat

DPO and ORPO on top of a fine-tuned run, with a judge that checks the
result.

[](https://dragonfarm.dev/articles/reinforcement-learning.md)

### Treats it has to earn

GRPO with exact, numeric, JSON, length, and test-runner rewards.

[](https://dragonfarm.dev/reference/index.md)

### The full spellbook

Every function documented, from `dragon_check()` to `dragon_publish()`.

## Your first dragon is ten minutes away.

Install the package, run
[`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md),
and open the app. The first run builds the nest (a Python environment)
for you.

`install.packages("dragonfarm")`

Copy

[Start hatching](https://dragonfarm.dev/articles/quickstart.md)

[CRAN](https://CRAN.R-project.org/package=dragonfarm)[GitHub](https://github.com/tejas4patel/dragonfarm)[News](https://dragonfarm.dev/news/index.md)[Report
an issue](https://github.com/tejas4patel/dragonfarm/issues)
