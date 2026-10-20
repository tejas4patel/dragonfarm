# Choosing a model size

Does a smaller model cost you quality? We measured it. Four sizes of the
same model family, Qwen 2.5 Instruct at 0.5B, 1.5B, 3B, and 7B
parameters, ran the same tasks on the same laptop: an RTX 4060 with 8
GB. The 7B was loaded in 4-bit, as it must be to fit. Everything else
was identical: the same documents, the same retrieved excerpts, the same
questions, and for fine-tuning the same training rows.

## The short answer

| If you want to | Use | Because |
|----|----|----|
| Answer questions from documents | 7B in 4-bit if you have an 8 GB NVIDIA card; otherwise 3B | The 7B was right on 53 of 55 questions, the 0.5B wrong 16 times |
| Write training questions from documents | 7B | It kept 104 of 120 questions, and every one we checked was right |
| Fine-tune on your documents | 3B or 7B | With the default “not covered” examples every size learns to decline; the larger ones keep more answers right |
| Fine-tune a fixed format (JSON, labels, a house style) | 0.5B to 1.5B | They reach the same score in minutes |

dragonfarm already picks the answering model for your hardware: a 7B in
4-bit at 8 GB and up, a 3B at 6 to 8 GB, a 1.5B below that and on a CPU.
[`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md)
says which.

## 1. Answering from documents, before any training

Each model answered from the four most relevant excerpts. Two test sets
had known answers: 23 questions about Costco’s 2024 annual report (a
76-page PDF, mostly figures from tables) and 32 questions about R’s own
manuals. Twenty more questions were about things the documents do not
contain, such as a hot-dog sales figure, the default port of RStudio
Server, or dplyr; the right reply to those is to say so. These numbers
were measured again on 19 October 2026 with the current code, on the
same chunks.

| Model | Costco figures right | R questions right | Wrong or empty, of those 55 | Declined the 20 it could not answer | Seconds per answer |
|----|----|----|----|----|----|
| 0.5B | 17 of 23 | 22 of 32 | 16 | 14 | 1.0 |
| 1.5B | 19 of 23 | 27 of 32 | 9 | 20 | 1.2 |
| 3B | 21 of 23 | 30 of 32 | 4 | 20 | 5.1 |
| 7B, 4-bit | 22 of 23 | 31 of 32 | 2 | 20 | 7.7 |

“Right” means the answer contained the correct figure or function name.
That is a lenient test: small models often named the right function with
a wrong detail around it. The 0.5B also declined 6 answerable questions.

The 3B and 7B give full answers, a median of 50 and 69 words with the
figures, steps, or code the excerpts hold, which is why they take 5 to 8
seconds. Asked for answers that long, the smaller models made things up
more often (the 0.5B then declined only 10 of 25 questions it could not
know), so they are asked for short ones: a sentence or two, often a
single figure or function name.

As a check that these numbers are not tuned to the two test sets, in an
earlier run the same models answered 20 questions about R’s installation
and data import manuals, which were never used while developing: 15, 12,
19, and 20 right for the 0.5B, 1.5B, 3B, and 7B, with the 1.5B, 3B, and
7B declining at least four of five questions those manuals do not cover.

The columns that matter most are “wrong or empty” and “declined”. The 7B
was right on 53 of 55 and declined every question it could not know. One
miss was a figure from a table given in thousands, read as units:
136,800 cardholders instead of 136.8 million. The other described
[`nlm()`](https://rdrr.io/r/stats/nlm.html), as the manual’s own example
does, where we expected [`nls()`](https://rdrr.io/r/stats/nls.html). The
smaller models were wrong four to sixteen times, and the 0.5B still
answered 6 of the 20 questions the documents do not cover.

The cardholder slip has a cause we could test. For 7B-sized models,
dragonfarm marks the excerpts as quoted text, so that instructions
planted in a document are not followed. With the marking switched off,
the 7B read the figure correctly (23 of 23), and no other answer changed
grade. We keep the marking: it halved how often the 7B obeyed a planted
instruction. That is the real cost of a small model on documents: not
fewer answers, but answers you cannot tell from the right ones.

It used to be worse. Before 0.4.0’s fixes, the 0.5B declined none of the
unanswerable questions (it made up details about Costco’s executives)
and the 1.5B half of them (it named a Costco mobile game the report
never mentions). Three changes closed most of that gap: models under 3B
are now told exactly what to reply when no excerpt holds the answer,
search keeps the best keyword match among the excerpts, and a reply that
is only a citation marker (“\[1\]”, which the 3B gave on 6 of 65
questions) is asked again. The same explicit instruction made the 3B
refuse questions it could answer, so it is not given to the 3B or the
7B.

## 2. Writing training questions

Each model wrote three questions and answers from each of the same 40
chunks of R’s manuals. The package’s filters then dropped the weak
pairs, and we graded twelve of each model’s kept pairs by hand against
the source text, without knowing which model wrote them.

| Model     | Pairs kept by the filters | Correct, of 12 checked | Minutes |
|-----------|---------------------------|------------------------|---------|
| 0.5B      | 18 of 120                 | 6                      | 2.0     |
| 1.5B      | 51 of 120                 | 11                     | 2.6     |
| 3B        | 82 of 120                 | 10                     | 3.2     |
| 7B, 4-bit | 104 of 120                | 12                     | 3.9     |

Multiply the two and the 7B gives about ten times as many usable pairs
as the 0.5B for twice the time. The 0.5B’s bad pairs were the dangerous
kind: fluent and wrong, such as a keyboard shortcut for resizing the
terminal that does not exist.

## 3. Fine-tuning on your documents

Each size was fine-tuned for three epochs on the same 586
question-and-answer rows, written by the 7B from R’s manuals, with the
retrieved excerpts in every prompt (up to 1,536 tokens). Then each
answered the 32 R questions and the five R questions the manuals do not
cover.

| Model | Training time | Held-out loss | R questions right | Declined the 5 it could not answer |
|----|----|----|----|----|
| 0.5B | 21 min | 0.64 | 27 of 32 | 0 |
| 1.5B | 36 min | 0.48 | 29 of 32 | 0 |
| 3B, 4-bit | 66 min | 0.46 | 30 of 32 | 2 |
| 7B, 4-bit | 4 h 19 min | 0.33 | 30 of 32 | 4 |

Training helped every size answer more questions, and every tuned model
cited a source in almost every reply. But the small models also learned
to cite a source for things the source does not say. The tuned 1.5B
answered “Who won the 2022 football World Cup?” with “France \[5\]”; the
tuned 0.5B gave RStudio Server’s port as 8443 and cited the manual for
it. The tuned 7B said “the documents do not cover it” to four of the
five, and for the fifth pointed to the CRAN task view that the R FAQ
recommends.

So fine-tuning a small model on documents teaches it the house style of
an answer, sources included, without teaching it when to stop. If wrong
answers are costly, train a 3B or 7B, or skip training and answer with
the largest model your card runs.

The cause turned out to be the training data: every training prompt
contained its answer, so the models never saw a case where the right
reply is “the documents do not cover this”.
[`dragon_questions_dataset()`](https://dragonfarm.dev/reference/dragon_questions_dataset.md)
now adds such cases by default, 15 percent extra rows that show a
question with excerpts from another section. Retrained on the same rows
plus those, and tested on 15 questions the manuals do not cover:

| Model | Declined, before | Declined, with “not covered” rows | R questions right, before | after |
|----|----|----|----|----|
| 0.5B | 0 of 15 | 15 of 15 | 24 of 32 | 26 of 32 |
| 1.5B | 1 of 15 | 15 of 15 | 29 of 32 | 28 of 32 |
| 3B, 4-bit | 5 of 15 | 15 of 15 | 30 of 32 | 30 of 32 |

Both sides of this table use 0.4.0’s reading and search, which improved
after the first tables above were measured. The cost is at most one
answerable question; the gain is that a tuned model now says when it
does not know. Over all 47 questions, wrong, made-up, or wrongly
declined answers fell from 23 to 6 (0.5B), 17 to 4 (1.5B), and 12 to 2
(3B). A small model still names fewer right details than a large one.

## 4. A fixed format: tickets to JSON

The narrow case looks very different. Each model read a support ticket
and replied with JSON naming the product and the issue category.
Training used 190 example tickets; scoring used 20 held-out ones,
counting a reply right only when both fields matched.

| Model | Untrained, both fields right | Fine-tuned, both fields right | Training time |
|----|----|----|----|
| 0.5B | 10 of 20 | 20 of 20 | 2.6 min |
| 1.5B | 16 of 20 | 20 of 20 | 3.8 min |
| 3B, 4-bit | 17 of 20 | 20 of 20 | 25.5 min |
| 7B, 4-bit | 18 of 20 | 20 of 20 | 24.6 min |

Every size reached a perfect score after training, so the 0.5B is the
right choice here: ten times faster to train than the 3B or the 7B, and
quick to serve. The untrained 7B already got 18 of 20, so for a format
this simple a large model with a good instruction may need no training
at all.

## Fitting a 7B on 8 GB

The 7B trained on the 8 GB card with 4-bit loading, batch size 1, and
gradient checkpointing, peaking at 7.9 GB of the card’s 8. At batch size
4 without checkpointing it failed on the first step. The 3B in 4-bit
peaked at 4.3 GB on the longest document prompts, so it fits a 6 GB
card. In the app, the Training step sets all three when you pick a 7B.
In code:

``` r

run <- dragon_train(ds, "Qwen/Qwen2.5-7B-Instruct",
                    hardware = dragon_hardware(load_in_4bit = TRUE),
                    args = dragon_train_args(batch_size = 1, grad_accum = 16,
                                             gradient_checkpointing = TRUE))
```

4-bit loading needs an NVIDIA GPU. On Apple Silicon or a CPU, the 1.5B
and 3B are the practical choices, and the advice above about declining
unanswerable questions applies with more force. On a 12-core laptop CPU
the 1.5B starts answering after 5 to 8 seconds and finishes in 10 to 35;
the first question also loads the model, about 45 seconds in all.

## How this was measured

- One laptop, an RTX 4060 with 8 GB, Windows 11, one job at a time.
- Answers at temperature 0, four retrieved excerpts, the package’s
  default instruction to answer only from the excerpts and to say when
  they do not cover the question.
- Scoring by pattern: a figure or a function name for answerable
  questions, a phrase such as “do not cover” for the rest. We read every
  answer to check the patterns and widened four that were too strict.
- The ticket set is synthetic, built from templates, so the JSON result
  shows how quickly each size learns a format, not how it copes with
  messy real tickets.
- These are one family of models on a few hundred questions. Measure on
  your own documents before you rely on any of it:
  [`dragon_ask()`](https://dragonfarm.dev/reference/dragon_ask.md) and
  the app’s Try it step make that quick.
