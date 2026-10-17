# Package index

## Setup

- [`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md) :
  Check the Python environment and hardware
- [`dragon_python_requirements()`](https://dragonfarm.dev/reference/dragon_python_requirements.md)
  : Python requirements used by dragonfarm
- [`dragon_presets()`](https://dragonfarm.dev/reference/dragon_presets.md)
  : Recommended base models

## Documents

Drop in documents, ask them questions, write and review training
questions, build the training set.

- [`dragon_documents()`](https://dragonfarm.dev/reference/dragon_documents.md)
  : Read documents into a document set
- [`dragon_documents_load()`](https://dragonfarm.dev/reference/dragon_documents_load.md)
  : Reopen a saved document set
- [`dragon_documents_list()`](https://dragonfarm.dev/reference/dragon_documents_list.md)
  : List saved document sets
- [`dragon_example_documents()`](https://dragonfarm.dev/reference/dragon_example_documents.md)
  : Example documents
- [`dragon_chunks()`](https://dragonfarm.dev/reference/dragon_chunks.md)
  : The chunks of a document set
- [`dragon_index()`](https://dragonfarm.dev/reference/dragon_index.md) :
  Index a document set for retrieval
- [`dragon_retrieve()`](https://dragonfarm.dev/reference/dragon_retrieve.md)
  : Find the chunks most relevant to a question
- [`dragon_ask()`](https://dragonfarm.dev/reference/dragon_ask.md) : Ask
  a question of your documents
- [`dragon_ellmer_tools()`](https://dragonfarm.dev/reference/dragon_ellmer_tools.md)
  : dragonfarm's tools for an ellmer chat or an MCP client
- [`dragon_mcp_server()`](https://dragonfarm.dev/reference/dragon_mcp_server.md)
  : Serve dragonfarm's tools to MCP clients
- [`dragon_questions()`](https://dragonfarm.dev/reference/dragon_questions.md)
  [`dragon_questions_progress()`](https://dragonfarm.dev/reference/dragon_questions.md)
  [`dragon_questions_wait()`](https://dragonfarm.dev/reference/dragon_questions.md)
  : Write questions and answers from a document set
- [`dragon_questions_load()`](https://dragonfarm.dev/reference/dragon_questions_load.md)
  [`dragon_questions_save()`](https://dragonfarm.dev/reference/dragon_questions_load.md)
  [`dragon_questions_list()`](https://dragonfarm.dev/reference/dragon_questions_load.md)
  : Load, save, and list question sets
- [`dragon_questions_dataset()`](https://dragonfarm.dev/reference/dragon_questions_dataset.md)
  : Training data from reviewed questions

## Data

- [`dragon_dataset()`](https://dragonfarm.dev/reference/dragon_dataset.md)
  : Create a dataset for fine-tuning
- [`dragon_map()`](https://dragonfarm.dev/reference/dragon_map.md) : Map
  dataset columns to prompt, response, and system text
- [`dragon_map_pairs()`](https://dragonfarm.dev/reference/dragon_map_pairs.md)
  : Map columns for preference optimization
- [`dragon_map_prompts()`](https://dragonfarm.dev/reference/dragon_map_prompts.md)
  : Map columns for reinforcement learning
- [`dragon_conversations()`](https://dragonfarm.dev/reference/dragon_conversations.md)
  : Multi-turn conversations as training data
- [`dragon_synthesize()`](https://dragonfarm.dev/reference/dragon_synthesize.md)
  : Write fine-tuning data with a teacher model
- [`dragon_synthesize_pairs()`](https://dragonfarm.dev/reference/dragon_synthesize_pairs.md)
  : Build preference pairs from a model's own samples
- [`dragon_prompts()`](https://dragonfarm.dev/reference/dragon_prompts.md)
  : Prompts from a run's data files
- [`dragon_preview()`](https://dragonfarm.dev/reference/dragon_preview.md)
  : Preview mapped rows as chat turns
- [`dragon_split()`](https://dragonfarm.dev/reference/dragon_split.md) :
  Hold out rows for evaluation
- [`dragon_example_data()`](https://dragonfarm.dev/reference/dragon_example_data.md)
  : Path to the bundled example dataset

## Settings

- [`dragon_lora()`](https://dragonfarm.dev/reference/dragon_lora.md) :
  LoRA settings
- [`dragon_train_args()`](https://dragonfarm.dev/reference/dragon_train_args.md)
  : Training settings
- [`dragon_hardware()`](https://dragonfarm.dev/reference/dragon_hardware.md)
  : Hardware settings

## Training stages

- [`dragon_train()`](https://dragonfarm.dev/reference/dragon_train.md) :
  Fine-tune a model with LoRA
- [`dragon_prefer()`](https://dragonfarm.dev/reference/dragon_prefer.md)
  : Preference optimization with DPO or ORPO
- [`dragon_reinforce()`](https://dragonfarm.dev/reference/dragon_reinforce.md)
  : Reinforcement learning with verifiable rewards (GRPO)
- [`dragon_reward()`](https://dragonfarm.dev/reference/dragon_reward.md)
  : Verifiable rewards for reinforcement learning
- [`dragon_resume()`](https://dragonfarm.dev/reference/dragon_resume.md)
  : Resume a run from its latest checkpoint
- [`dragon_wait()`](https://dragonfarm.dev/reference/dragon_wait.md) :
  Wait for a run to finish
- [`dragon_cancel()`](https://dragonfarm.dev/reference/dragon_cancel.md)
  : Cancel a run

## Runs

- [`dragon_run()`](https://dragonfarm.dev/reference/dragon_run.md) :
  Reopen an existing run
- [`dragon_runs()`](https://dragonfarm.dev/reference/dragon_runs.md) :
  List runs
- [`dragon_archived_runs()`](https://dragonfarm.dev/reference/dragon_archived_runs.md)
  : Archived runs
- [`dragon_archive_run()`](https://dragonfarm.dev/reference/dragon_archive_run.md)
  [`dragon_unarchive_run()`](https://dragonfarm.dev/reference/dragon_archive_run.md)
  [`dragon_delete_run()`](https://dragonfarm.dev/reference/dragon_archive_run.md)
  : Archive, restore, or delete a run
- [`dragon_runs_dir()`](https://dragonfarm.dev/reference/dragon_runs_dir.md)
  : Directory where runs are stored
- [`dragon_status()`](https://dragonfarm.dev/reference/dragon_status.md)
  [`dragon_progress()`](https://dragonfarm.dev/reference/dragon_status.md)
  [`dragon_logs()`](https://dragonfarm.dev/reference/dragon_status.md) :
  Inspect a run
- [`dragon_code()`](https://dragonfarm.dev/reference/dragon_code.md) : R
  code that reproduces a run

## Evaluation

- [`dragon_evaluate()`](https://dragonfarm.dev/reference/dragon_evaluate.md)
  : Evaluate a finished run
- [`dragon_metrics()`](https://dragonfarm.dev/reference/dragon_metrics.md)
  [`dragon_metric_regex()`](https://dragonfarm.dev/reference/dragon_metrics.md)
  : Task metrics for generated replies
- [`dragon_judge()`](https://dragonfarm.dev/reference/dragon_judge.md) :
  Judge a run's replies with a language model
- [`dragon_llm_anthropic()`](https://dragonfarm.dev/reference/dragon_llm_anthropic.md)
  [`dragon_judge_anthropic()`](https://dragonfarm.dev/reference/dragon_llm_anthropic.md)
  [`dragon_llm_ellmer()`](https://dragonfarm.dev/reference/dragon_llm_anthropic.md)
  [`dragon_judge_ellmer()`](https://dragonfarm.dev/reference/dragon_llm_anthropic.md)
  : Language models as functions: the Claude API and ellmer
- [`dragon_compare()`](https://dragonfarm.dev/reference/dragon_compare.md)
  : Compare runs side by side

## Inference and chat

- [`dragon_backend_local()`](https://dragonfarm.dev/reference/dragon_backend.md)
  [`dragon_backend_server()`](https://dragonfarm.dev/reference/dragon_backend.md)
  [`dragon_backend_ollama()`](https://dragonfarm.dev/reference/dragon_backend.md)
  [`dragon_backend()`](https://dragonfarm.dev/reference/dragon_backend.md)
  : Inference backends
- [`dragon_serve_ollama()`](https://dragonfarm.dev/reference/dragon_serve_ollama.md)
  : Serve a run's model with Ollama
- [`dragon_worker_stop()`](https://dragonfarm.dev/reference/dragon_worker_stop.md)
  : Stop the local inference worker
- [`dragon_chat()`](https://dragonfarm.dev/reference/dragon_chat.md)
  [`dragon_chat_load()`](https://dragonfarm.dev/reference/dragon_chat.md)
  : Talk to a model, with memory of the conversation
- [`dragon_feedback()`](https://dragonfarm.dev/reference/dragon_feedback.md)
  : Training data from chat feedback

## After training

- [`dragon_generate()`](https://dragonfarm.dev/reference/dragon_generate.md)
  : Generate replies from a fine-tuned model
- [`dragon_merge()`](https://dragonfarm.dev/reference/dragon_merge.md) :
  Merge the adapter into the base model
- [`dragon_export_gguf()`](https://dragonfarm.dev/reference/dragon_export_gguf.md)
  : Export a merged model to GGUF
- [`dragon_publish()`](https://dragonfarm.dev/reference/dragon_publish.md)
  : Push a run's model to the Hugging Face Hub

## Pipelines

- [`dragon_pipeline()`](https://dragonfarm.dev/reference/dragon_pipeline.md)
  : Run several post-training stages as one pipeline
- [`dragon_step_train()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_prefer()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_synthesize_pairs()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_reinforce()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_judge()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_evaluate()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_merge()`](https://dragonfarm.dev/reference/dragon_step.md)
  [`dragon_step_publish()`](https://dragonfarm.dev/reference/dragon_step.md)
  : Steps of a post-training pipeline
- [`dragon_pipeline_status()`](https://dragonfarm.dev/reference/dragon_pipeline_status.md)
  : Progress of a pipeline
- [`dragon_pipeline_cancel()`](https://dragonfarm.dev/reference/dragon_pipeline_cancel.md)
  : Cancel a pipeline

## Cloud GPUs

- [`dragon_bundle()`](https://dragonfarm.dev/reference/dragon_bundle.md)
  : Package a run for a cloud GPU
- [`dragon_remote()`](https://dragonfarm.dev/reference/dragon_remote.md)
  : Open a cloud GPU provider for a bundled run
- [`dragon_import()`](https://dragonfarm.dev/reference/dragon_import.md)
  : Import results trained on another machine
- [`dragon_remote_providers()`](https://dragonfarm.dev/reference/dragon_remote_providers.md)
  : Cloud GPU providers

## App

- [`dragon_app()`](https://dragonfarm.dev/reference/dragon_app.md) :
  Launch the dragonfarm app
