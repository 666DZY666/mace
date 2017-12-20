#!/bin/bash
# Must run at root dir of mace project.
set +x
Usage() {
  echo 'Usage: bash tools/validate_gcn.sh tf_model_path image_size [tuning]'
}

if [ $# -lt 2 ];then
  Usage
  exit -1
fi

TF_MODEL_FILE_PATH=$1
MODEL_DIR=$(dirname ${TF_MODEL_FILE_PATH})
MACE_SOURCE_DIR=`/bin/pwd`
MACE_MODEL_NAME='mace_model.pb'
INPUT_FILE_NAME='model_input'
OUTPUT_FILE_NAME='gcn.out'
OUTPUT_LIST_FILE='gcn.list'
PHONE_DATA_DIR="/data/local/tmp/${MACE_MODEL_NAME}"
KERNEL_DIR="${PHONE_DATA_DIR}/cl/"
IMAGE_SIZE=$2
MODEL_TAG=GCN${IMAGE_SIZE}
CODEGEN_DIR=${MACE_SOURCE_DIR}/mace/codegen
MODEL_CODEGEN_DIR=${CODEGEN_DIR}/models/gcn-$IMAGE_SIZE
CL_CODEGEN_DIR=${CODEGEN_DIR}/opencl
CL_BIN_DIR=${CODEGEN_DIR}/opencl_bin
TUNING_CODEGEN_DIR=${CODEGEN_DIR}/tuning
TUNING_OR_NOT=${3:-0}

build_and_run()
{
  EMBED_OPENCL_BINARY=$1
  if [ "$EMBED_OPENCL_BINARY" = true ]; then
    EMBED_OPENCL_BINARY_BUILD_FLAGS="--define embed_binary_program=true"
  fi

  bazel build -c opt --strip always mace/examples:mace_run \
    --crosstool_top=//external:android/crosstool \
    --host_crosstool_top=@bazel_tools//tools/cpp:toolchain \
    --cpu=arm64-v8a \
    $EMBED_OPENCL_BINARY_BUILD_FLAGS \
    --copt=-DMACE_MODEL_FUNCTION=Create${MODEL_TAG}

  adb shell "mkdir -p ${PHONE_DATA_DIR}"
  if [ "$EMBED_OPENCL_BINARY" = false ]; then
    adb shell "rm -rf ${KERNEL_DIR}"
    adb shell "mkdir -p ${KERNEL_DIR}"
    adb push mace/kernels/opencl/cl/. ${KERNEL_DIR}
  fi
  adb push ${MODEL_DIR}/${INPUT_FILE_NAME} ${PHONE_DATA_DIR}
  adb push bazel-bin/mace/examples/mace_run ${PHONE_DATA_DIR}

  num_threads=${1:-4}
  if [[ "${TUNING_OR_NOT}" != "0" && "$EMBED_OPENCL_BINARY" != true ]];then
    tuning_flag=1
  else
    tuning_flag=0
  fi

  adb </dev/null shell MACE_TUNING=${tuning_flag} \
    MACE_CPP_MIN_VLOG_LEVEL=0 \
    MACE_RUN_PARAMETER_PATH=${PHONE_DATA_DIR}/mace_run.config \
    MACE_KERNEL_PATH=$KERNEL_DIR \
    OMP_NUM_THREADS=$num_threads \
    ${PHONE_DATA_DIR}/mace_run \
    --model=${PHONE_DATA_DIR}/${MACE_MODEL_NAME} \
    --input=mace_input_node \
    --output=mace_output_node \
    --input_shape="1,${IMAGE_SIZE},${IMAGE_SIZE},3"\
    --input_file=${PHONE_DATA_DIR}/${INPUT_FILE_NAME} \
    --output_file=${PHONE_DATA_DIR}/${OUTPUT_FILE_NAME} \
    --device=OPENCL   \
    --round=1
}

echo "Step 1: Generate input data"
python tools/validate.py --generate_data true --random_seed 1 \
 --input_file=${MODEL_DIR}/${INPUT_FILE_NAME} \
 --input_shape="${IMAGE_SIZE},${IMAGE_SIZE},3"

echo "Step 2: Convert tf model to mace model and optimize memory"
bazel build //mace/python/tools:tf_converter
rm -rf ${CODEGEN_DIR}/models
mkdir -p ${MODEL_CODEGEN_DIR}
bazel-bin/mace/python/tools/tf_converter --input=${TF_MODEL_FILE_PATH} \
                                         --output=${MODEL_CODEGEN_DIR}/mace_gcn${IMAGE_SIZE}.cc \
                                         --input_node=input \
                                         --output_node=GCN/br_result_2/fcn_br \
                                         --data_type=DT_HALF \
                                         --runtime=gpu \
                                         --output_type=source \
                                         --template=${MACE_SOURCE_DIR}/mace/python/tools/model.template \
                                         --model_tag=${MODEL_TAG} \
                                         --confuse=True

echo "Step 3: Run model on the phone with files"
build_and_run false

echo "Step 4: Generate OpenCL binary program and config code"
rm -rf ${CL_BIN_DIR}
adb pull ${KERNEL_DIR} ${CL_BIN_DIR}
rm -rf ${CL_CODEGEN_DIR}
mkdir -p ${CL_CODEGEN_DIR}
python mace/python/tools/opencl_codegen.py \
  --cl_binary_dir=${CL_BIN_DIR} --output_path=${CL_CODEGEN_DIR}/opencl_compiled_program.cc

echo "Step 5: Generate tuning source file"
adb pull ${PHONE_DATA_DIR}/mace_run.config ${CL_BIN_DIR}
mkdir -p ${TUNING_CODEGEN_DIR}
python mace/python/tools/binary_codegen.py \
  --binary_file=${CL_BIN_DIR}/mace_run.config --output_path=${TUNING_CODEGEN_DIR}/tuning_params.cc

echo "Step 6: Run model on the phone using binary"
build_and_run true

echo "Step 7: Pull the mace run result."
rm -rf ${MODEL_DIR}/${OUTPUT_FILE_NAME}
adb </dev/null pull ${PHONE_DATA_DIR}/${OUTPUT_FILE_NAME} ${MODEL_DIR}

echo "Step 8: Validate the result"
python tools/validate.py --model_file ${TF_MODEL_FILE_PATH} \
    --input_file ${MODEL_DIR}/${INPUT_FILE_NAME} \
    --mace_out_file ${MODEL_DIR}/${OUTPUT_FILE_NAME} \
    --input_node input \
    --output_node GCN/br_result_2/fcn_br\
    --input_shape "${IMAGE_SIZE},${IMAGE_SIZE},3" \
    --output_shape "1,${IMAGE_SIZE},${IMAGE_SIZE},2"