#!/bin/bash

# This file is both an integration test that runs once a day on a v4-8 and documentation for how to get started with Gemma-2b. 

# The flow of this file is as follows:
# 1. Convert the checkpoint downloaded from Kaggle to make it compatible with MaxText
# 2. Run decoding, finetuning of Gemma 2B with the converted checkpoint. Also, run pretraining of Gemma 2B
# 3. Convert the scanned checkpoint from step 1 into unscanned checkpoint format and run more efficient decoding.
# 4. Run decoding from the finetuned checkpoint from step 2
# 5. Ahead of Time Compilation for running Gemma 2B on v5e-256


set -ex
idx=$(date +%Y-%m-%d-%H-%M)
export MODEL_VARIATION='2b'

# After downloading checkpoints, copy them to GCS bucket at $CHKPT_BUCKET \
# Non-Googlers please remember to use seperate GCS paths for uploading model weights from kaggle ($CHKPT_BUCKET) and MaxText compatible weights ($MODEL_BUCKET).
# Non-Googlers please remember to point these variables to GCS buckets that you own, this script uses internal buckets for testing.
export CHKPT_BUCKET=gs://maxtext-gemma/flax
export MODEL_BUCKET=gs://maxtext-gemma
python MaxText/convert_gemma_chkpt.py --base_model_path ${CHKPT_BUCKET}/${MODEL_VARIATION} --maxtext_model_path ${MODEL_BUCKET}/${MODEL_VARIATION}/${idx} --model_size ${MODEL_VARIATION}

# Non-Googlers please remember to point `DATASET_PATH` to the GCS bucket where you have your training data
export DATASET_PATH=gs://maxtext-dataset
# Non-Googlers please remember to point `BASE_OUTPUT_DIRECTORY` to a GCS bucket that you own, this bucket will store all the files generated by MaxText during a run
export BASE_OUTPUT_DIRECTORY=gs://runner-maxtext-logs
# We define `CONVERTED_CHECKPOINT` to refer to the checkpoint subdirectory. This way it is easier to use this path in the `train.py` and `decode.py` commands
export CONVERTED_CHECKPOINT=${MODEL_BUCKET}/${MODEL_VARIATION}/${idx}/0/items
export RUN_NAME=unscanned_chkpt_${idx}
# Note that the `CONVERTED_CHECKPOINT` is in a `scanned` format which is great for training but for efficient decoding performance we want the checkpoint in an `unscanned` format.
# We can do this by running `MaxText/generate_param_only_checkpoint.py` on `CONVERTED_CHECKPOINT` with `force_unroll=true`. 
python MaxText/generate_param_only_checkpoint.py MaxText/configs/base.yml base_output_directory=${BASE_OUTPUT_DIRECTORY} load_parameters_path=${CONVERTED_CHECKPOINT} run_name=${RUN_NAME} model_name='gemma-2b' force_unroll=true

export UNSCANNED_CKPT_PATH=${BASE_OUTPUT_DIRECTORY}/${RUN_NAME}/checkpoints/0/items

# We run decoding on the `UNSCANNED_CKPT_PATH` for efficient decoding on the unscanned version of the checkpoint. Note that this checkpoint only has parameters and no optimizer state. 
# So, we use it by specifying`load_parameters_path=${CONVERTED_CHECKPOINT}`
# We compare our decoded results by asserting with golden outputs using `autoregressive_decode_assert`
python MaxText/decode.py MaxText/configs/base.yml tokenizer_path=assets/tokenizer.gemma load_parameters_path=${UNSCANNED_CKPT_PATH} per_device_batch_size=1 run_name=runner_$(date +%Y-%m-%d-%H-%M) max_prefill_predict_length=8 max_target_length=16 dataset_type=synthetic steps=10 async_checkpointing=false scan_layers=false model_name=gemma-2b attention=dot_product prompt="I love to" autoregressive_decode_assert=" travel and I love to write about it"

# We can also run decoding (albeit in a bit unoptimized way) by using the scanned converted checkpoint located at `CONVERTED_CHECKPOINT`. Note again that this checkpoint only has parameters and no optimizer state. So, we use it by specifying`load_parameters_path=${CONVERTED_CHECKPOINT}`
python MaxText/decode.py MaxText/configs/base.yml tokenizer_path=assets/tokenizer.gemma load_parameters_path=${CONVERTED_CHECKPOINT} per_device_batch_size=1 run_name=runner_$(date +%Y-%m-%d-%H-%M) max_prefill_predict_length=8 max_target_length=16 dataset_type=synthetic steps=10 async_checkpointing=false model_name=gemma-2b attention=dot_product prompt="I love to" autoregressive_decode_assert=" cook and bake. I love to eat"

# Alternatively, we skip to running finetuning by using the scanned converted checkpoint located at `CONVERTED_CHECKPOINT`. Again, we use it by specifying`load_parameters_path=${CONVERTED_CHECKPOINT}`. Note that scanned checkpoint helps with efficient finetuning
export FINETUNE_RUN_NAME=runner_finetune_${idx}
python MaxText/train.py MaxText/configs/base.yml base_output_directory=${BASE_OUTPUT_DIRECTORY} dataset_path=${DATASET_PATH} tokenizer_path=assets/tokenizer.gemma load_parameters_path=${CONVERTED_CHECKPOINT} per_device_batch_size=1 run_name=${FINETUNE_RUN_NAME} max_target_length=8192 steps=10 async_checkpointing=false model_name=gemma-2b checkpoint_period=5

# We also run pre-training, this is similar to the finetuning command except we don't pass any checkpoint directory to load parameters from
python MaxText/train.py MaxText/configs/base.yml base_output_directory=${BASE_OUTPUT_DIRECTORY} dataset_path=${DATASET_PATH} tokenizer_path=assets/tokenizer.gemma per_device_batch_size=1 run_name=runner_pretrain_${idx} max_target_length=8192 steps=5 enable_checkpointing=false model_name=gemma-2b

# Note that the finetune run checkpoint generates the `full state` which has both parameters and optimizer state. For decoding, we only need to use the parameters. 
# So, we can use the `MaxText/generate_param_only_checkpoint.py` to convert the full state checkpoint into a parameter only checkpoint for more efficient memory use. Note that the path provided to the flag `load_full_state_path` is the path to the checkpoint subdirectory inside the `BASE_OUTPUT_DIRECTORY` from our previous finetuning run.
# `force_unroll=true` is converting the output parameter only checkpoint into an unscanned format for efficient decoding
export PARAM_RUN_NAME=param_chkpt_${idx}
python MaxText/generate_param_only_checkpoint.py MaxText/configs/base.yml base_output_directory=${BASE_OUTPUT_DIRECTORY} load_full_state_path=${BASE_OUTPUT_DIRECTORY}/${FINETUNE_RUN_NAME}/checkpoints/5/items run_name=${PARAM_RUN_NAME} model_name='gemma-2b' force_unroll=true

# Now, run decoding on the checkpoint generated from our finetune run.
python MaxText/decode.py MaxText/configs/base.yml tokenizer_path=assets/tokenizer.gemma load_parameters_path=${BASE_OUTPUT_DIRECTORY}/${PARAM_RUN_NAME}/checkpoints/0/items per_device_batch_size=1 run_name=runner_$(date +%Y-%m-%d-%H-%M) max_prefill_predict_length=8 max_target_length=16 dataset_type=synthetic steps=10 async_checkpointing=false scan_layers=false model_name=gemma-2b attention=dot_product prompt="I love to"

# We recommend training/finetuning Gemma on v5e-256 using the following sharding strategy to achieve optimal performance.
# This below command does Ahead Of Time Cross Compilation (https://github.com/google/maxtext?tab=readme-ov-file#ahead-of-time-compilation-aot) for our recommended v5e-256 configuration for Gemma 2B.
# To actually run it on real v5e-256's simple replace the train_compile.py with a train.py and get rid of compile_topology args.
python MaxText/train_compile.py MaxText/configs/base.yml model_name=gemma-2b ici_fsdp_transpose_parallelism=16 per_device_batch_size=2 compile_topology=v5e-256 compile_topology_num_slices=1
