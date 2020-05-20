# import numpy as np
# import glob
# import math
# import matplotlib.pyplot as plt
import argparse
import os
import sys
import glob
import math
import shutil
import logging
import tensorflow as tf
from tensorflow.keras.applications import Xception, InceptionV3, ResNet50
from tensorflow.keras.applications.xception import preprocess_input
from tensorflow.keras.layers import Dense, GlobalAveragePooling2D, Reshape
from tensorflow.keras.utils import multi_gpu_model
from tensorflow.keras import Sequential
from tensorflow.keras import Input
from tensorflow.keras.optimizers import SGD
from tensorflow.keras.optimizers.schedules import PolynomialDecay, ExponentialDecay
from tensorflow.keras.losses import (
    CategoricalCrossentropy,
    SparseCategoricalCrossentropy,
)
from tensorflow.keras import regularizers
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from tensorflow.keras.callbacks import ModelCheckpoint, TensorBoard
from azureml.core import Run
import utils  # pylint: disable=unresolved-import

# from deeplab import DeeplabV3Plus
from deeplabv3plus.model import Deeplabv3
from mean_iou_custom import MeanIoUCustom  # pylint: disable=unresolved-import

tf.config.optimizer.set_jit(True)
tf.debugging.set_log_device_placement(False)

# from tf.keras.applications.xception import preprocess_input
# from tf.keras.preprocessing import image
# from keras.utils import to_categorical
# from keras.callbacks import ModelCheckpoint

# fmt: off
parser = argparse.ArgumentParser()
parser.add_argument("--data-folder", type=str, dest="data_folder", default="data/", help="data folder mounting point")
parser.add_argument("--log-dir", type=str, dest="log_dir", default="logs/", help="log folder mounting point for TensorBoard")
parser.add_argument("--batch-size", type=int, dest="batch_size", default=52, help="mini batch size for training")
parser.add_argument("--run-environment", type=str, choices=["local", "azure"], dest="run_environment", default="local")
parser.add_argument("--skip-train", dest="skip_train", default=False, type=lambda x: (str(x).lower() == 'true'), help="use --skip-train: true to not run training, do nothing to train")
parser.add_argument("--skip-validate", dest="skip_validate", default=False, type=lambda x: (str(x).lower() == 'true'), help="use --skip-validate: true to not run validation, do nothing to validate")
parser.add_argument("--test", dest="test", default=False, type=lambda x: (str(x).lower() == 'true'), help="use --test: True to run against the test set, do nothing to skip")
parser.add_argument("--skip-save-model", dest="skip_save_model", default=False, type=lambda x: (str(x).lower() == 'true'), help="use --skip-save-model: true to not save the model, do nothing to save")
parser.add_argument("--seed", type=int, dest="seed", default=1)
parser.add_argument("--num-epochs", type=int, dest="num_epochs", default=2)
parser.add_argument("--train-split", type=str, dest="train_split", default="train")
parser.add_argument("--eval-split", type=str, dest="eval_split", default="val")
parser.add_argument("--test-split", type=str, dest="test_split", default="test")
parser.add_argument("--model-variant", type=str, dest="model_variant", default="ResNet50", choices=["xception", "InceptionV3", "ResNet50"])
parser.add_argument("--train-application", dest="train_application", default=False, type=lambda x: (str(x).lower() == 'true'), help="use --train-application to also train the Keras application, do nothing to keep it stable")
parser.add_argument("--crop-size-h", type=int, dest="crop_size_h", default=71) # 71 is the minimum image size for Xception
parser.add_argument("--crop-size-w", type=int, dest="crop_size_w", default=71)
parser.add_argument("--min-resize-value", type=int, dest="min_resize_value", default=None)
parser.add_argument("--max-resize-value", type=int, dest="max_resize_value", default=None)
parser.add_argument("--min-scale-factor", type=int, dest="min_scale_factor", default=0.5)
parser.add_argument("--max-scale-value", type=int, dest="max_scale_factor", default=2)
parser.add_argument("--scale-factor-step-size", type=int, dest="scale_factor_step_size", default=0.25)
parser.add_argument("--learning-policy", type=str, dest="learning_policy", choices=["poly", "step"], default="poly")
parser.add_argument("--learning-rate", type=float, dest="learning_rate", default=0.01)
parser.add_argument("--momentum", type=float, dest="momentum", default=0.9)
parser.add_argument("--learning-power", type=float, dest="learning_power", default=0.87)
parser.add_argument("--learning-rate-decay", type=float, dest="learning_rate_decay", default=0.97)
parser.add_argument("--output-stride", type=int, dest="output_stride", default=8)
parser.add_argument('--resume-from', type=str, default=None, 
                    help='location of the model or checkpoint files from where to resume the training')
# TODO: implement this
# parser.add_argument( "--model-options", type=str, dest="model_options", default="--atrous_rates=12 --atrous_rates=24 --atrous_rates=36 --output_stride=8 --decoder_output_stride=4")
# TODO: to be implemented
# parser.add_argument("--fine-tune-batch-norm", type=bool, dest="fine_tune_batch_norm", default=True)
# parser.add_argument("--add-image-level-feature",type=bool,dest="add_image_level_feature",default=False)
# TODO: to be implemented if necessary, might be GCP specific
# parser.add_argument("--num-shards", type=int, dest="num_shards", default=8)
# parser.add_argument("--iterations", type=int, dest="iterations", default=50)
# other old parameters, might need to be implemented
# parser.add_argument("--slow-learning-steps", type=int, dest="slow_learning_steps", default=500 )
# parser.add_argument("--slow-learning-rate", type=float, dest="slow_learning_rate", default=0.002)
# parser.add_argument("--log-step-count-steps", type=int, dest="log_step_count_steps", default=50)
args = parser.parse_args()
# fmt: on

_LOGGER = logging.getLogger("train")
run = Run.get_context()
local_run = True if args.run_environment == "local" else False
# setup
if local_run:
    _LOGGER.setLevel(10)  # debug
    # run eagerly for local debugging
#     tf.config.experimental_run_functions_eagerly(run_eagerly=False)
else:
    _LOGGER.setLevel(20)  # info
    gpus = tf.config.experimental.list_physical_devices("GPU")
    for gpu in gpus:
        tf.config.experimental.set_memory_growth(gpu, True)
_LOGGER.info(f"Doing a {args.run_environment} run ({local_run}).")
_LOGGER.info(f"TensorFlow version: {tf.__version__}")
num_gpus = len(tf.config.experimental.list_physical_devices("GPU"))
_LOGGER.info(f"Num GPUs Available: {num_gpus}")

# create the folder to use to store the model
output_path = "outputs/"
logs_dir = os.path.join(
    args.log_dir
)  # logs dir does not have to be created for AML runs
model_folder = os.path.join(output_path, "model/")
check_point_subfolder = "checkpoints/"
checkpoint_prefix = os.path.join(output_path, check_point_subfolder)
_LOGGER.debug(f"Checkpoint folder: {checkpoint_prefix}")
# os.makedirs(output_path, exist_ok=True)
os.makedirs(model_folder, exist_ok=True)
os.makedirs(checkpoint_prefix, exist_ok=True)

# load data
# previous_model_location = args.resume_from
# if previous_model_location:
#     _LOGGER.info(f"Previous model location: {previous_model_location}")
#     _LOGGER.info(glob.glob(previous_model_location))
#     _LOGGER.info(glob.glob(os.path.join(previous_model_location, check_point_subfolder)))
#     previous_model_location2 = os.path.expandvars(os.getenv("AZUREML_DATAREFERENCE_MODEL_LOCATION", None))
#     _LOGGER.info(f"Previous model location: {previous_model_location2}")
#     _LOGGER.info(glob.glob(os.path.join(previous_model_location2)))
#     _LOGGER.info(glob.glob(os.path.join(previous_model_location2, check_point_subfolder)))
seed = args.seed
skip_train = args.skip_train
skip_validate = args.skip_validate
test = args.test
model_variant = args.model_variant
output_stride = args.output_stride
train_application = args.train_application
skip_save_model = args.skip_save_model
cs_h = args.crop_size_h
cs_w = args.crop_size_w
if (
    cs_w != cs_h
):  # to be used by AML when doing hyperparameter tuning with crop sizes, this makes sure the images stay square
    cs_w = cs_h
train_split = args.train_split
eval_split = args.eval_split
test_split = args.test_split
data_folder = args.data_folder
min_resize_value = args.min_resize_value
max_resize_value = args.max_resize_value
min_scale_factor = args.min_scale_factor
max_scale_factor = args.max_scale_factor
scale_factor_step_size = args.scale_factor_step_size
learning_policy = args.learning_policy
learning_rate = args.learning_rate
learning_power = args.learning_power
learning_rate_decay = args.learning_rate_decay
momentum = args.momentum
num_classes = utils.BRINK_INFORMATION.num_classes
ignore_label = utils.BRINK_INFORMATION.ignore_label
label_mapping = utils.BRINK_INFORMATION.label_mapping

if local_run and data_folder == "data/":
    train_dataset_size = 268
    eval_dataset_size = 34
    test_dataset_size = 34
else:
    # TODO: use a external file with splits and numbers of records from the other process.
    # TODO: change the mapping of classes to a external file as well
    train_dataset_size = utils.BRINK_INFORMATION.splits_to_sizes[train_split]
    eval_dataset_size = utils.BRINK_INFORMATION.splits_to_sizes[eval_split]
    test_dataset_size = utils.BRINK_INFORMATION.splits_to_sizes[test_split]
# _LOGGER.debug("train_dataset_size: %s", train_dataset_size)
# _LOGGER.debug("eval_dataset_size: %s", eval_dataset_size)
# _LOGGER.debug("test_dataset_size: %s", test_dataset_size)

if not skip_train:
    #     _LOGGER.debug("Loading training data.")
    train_dataset = utils.get_dataset_for_generator(data_folder, train_split)
#     _LOGGER.debug("Shape of the train dataset: %s", train_dataset.element_spec)
if not skip_validate or not skip_train:
    #     _LOGGER.debug("Loading evaluation data.")
    eval_dataset = utils.get_dataset_for_generator(data_folder, eval_split)
#     _LOGGER.debug("Shape of the eval dataset: %s", eval_dataset.element_spec)
if test:
    #     _LOGGER.debug("Loading test data.")
    test_dataset = utils.get_dataset_for_generator(data_folder, test_split)
#     _LOGGER.debug("Shape of the test dataset: %s", test_dataset.element_spec)

# define training parameters
n_epochs = args.num_epochs
batch_size = args.batch_size
steps_per_epoch = train_dataset_size / batch_size
eval_steps = eval_dataset_size / (2 * batch_size)
test_steps = test_dataset_size / (2 * batch_size)

# define inputs and outputs
n_inputs = (cs_h, cs_w, 3)  # image size
n_outputs = (cs_h, cs_w, num_classes)  # one hot encoded predictions size
n_outputs_flat = (
    n_outputs[0] * n_outputs[1] * n_outputs[2]
)  # flattened one hot encoded predictions size

# +
# create Xception base model
# _LOGGER.info(f"Devices: {tf.config.experimental.list_physical_devices()}")
# strategy = tf.distribute.MirroredStrategy()
# strategy = tf.distribute.experimental.CentralStorageStrategy(
#     parameter_device="CPU" #compute_devices="GPU",
# )
# _LOGGER.info(f"Parameter device: {strategy.extended.parameter_devices}")
# _LOGGER.info(f"Compute devices: {strategy.extended.worker_devices}")
# tf.distribute.MirroredStrategy()
# with strategy.scope():
model = Deeplabv3(
    input_shape=n_inputs, classes=num_classes, backbone=model_variant, OS=16
)
# if previous_model_location:
# #     checkpoint_file_path = tf.train.latest_checkpoint(os.path.join(previous_model_location, check_point_subfolder))
#     checkpoint_file_path = tf.train.latest_checkpoint(previous_model_location)
# #     saver.restore(sess, checkpoint_file_path)
# #     checkpoint_filename = os.path.basename(checkpoint_file_path)
#     model.load_weights(checkpoint_file_path, by_name=True)
# #         saver.restore(sess, checkpoint_file_path)
# #     checkpoint_filename = os.path.basename(checkpoint_file_path)
# #     num_found = re.search(r'\d+', checkpoint_filename)
# #     if num_found:
# #         start_epoch = int(num_found.group(0))
# #         _LOGGER.info(f"Resuming from epoch {start_epoch}")
# else:
model.save_weights(checkpoint_prefix, overwrite=True, save_format="tf")

# _LOGGER.debug("Model summary: %s", model.summary())
# -

# configure training and compile model
# create learning_rate function
if learning_policy == "poly":
    learning_rate_fn = PolynomialDecay(
        initial_learning_rate=learning_rate,
        decay_steps=steps_per_epoch * n_epochs,
        end_learning_rate=0,
        power=learning_power,
    )
elif learning_policy == "step":
    learning_rate_fn = ExponentialDecay(
        initial_learning_rate=learning_rate,
        decay_steps=steps_per_epoch,
        decay_rate=learning_rate_decay,
        staircase=True,
    )

# create custom metric
metric = MeanIoUCustom(
    num_classes=num_classes,
    ignore_label=ignore_label,
    crop_size_h=cs_h,
    crop_size_w=cs_w,
)

# compile model
model.compile(
    optimizer=SGD(learning_rate=learning_rate_fn, momentum=momentum, nesterov=True),
    loss=SparseCategoricalCrossentropy(from_logits=False),
    metrics=[metric],
)

# batch_size = 1
# steps_per_epoch = 1
# eval_steps = 1
batch_size = batch_size  # * mirrored_strategy.num_replicas_in_sync
# _LOGGER.debug(f"Batch size: {batch_size}")
# _LOGGER.debug(f"Training data size: {train_dataset_size}")
# _LOGGER.debug(f"Eval data size: {eval_dataset_size}")
# _LOGGER.debug(f"Number of epochs to run: {n_epochs}")


@tf.function
def convert(image, label):
    image = tf.image.convert_image_dtype(
        image, tf.float32
    )  # Cast and normalize the image to [0,1]
    return image, label


@tf.function
def resize(image, label):
    image, label = convert(image, label)
    image = tf.image.resize(image, size=[cs_h, cs_w])
    label = tf.image.resize(label, size=[cs_h, cs_w])
    return image, label


@tf.function
def augment(image, label):
    image, label = convert(image, label)
    image = tf.image.resize_with_crop_or_pad(
        image, math.ceil(cs_h * 1.25), math.ceil(cs_w * 1.25)
    )
    label = tf.image.resize_with_crop_or_pad(
        label, math.ceil(cs_h * 1.25), math.ceil(cs_w * 1.25)
    )
    image = tf.image.random_crop(image, size=[cs_h, cs_w, 3], seed=seed)
    label = tf.image.random_crop(label, size=[cs_h, cs_w, 1], seed=seed)
    image = tf.image.random_brightness(image, max_delta=0.5)  # Random brightness
    return image, label


# training
if not skip_train:
    augmented_train_batches = (
        train_dataset.cache()
        .shuffle(train_dataset_size // 4)
        # The augmentation is added here.
        .map(augment, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .repeat()
        .batch(batch_size)
        .prefetch(tf.data.experimental.AUTOTUNE)
    )
    #     _LOGGER.debug("Shape of the augmented train dataset: %s", augmented_train_batches.element_spec)
    validation_batches = (
        eval_dataset.cache()  # .map(convert, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .map(resize, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .repeat()
        .batch(2 * batch_size)
        .prefetch(tf.data.experimental.AUTOTUNE)
    )
    #     _LOGGER.debug("Shape of the augmented validation dataset: %s", validation_batches.element_spec)
    tensorboard_callback = TensorBoard(
        log_dir=logs_dir, histogram_freq=1, profile_batch=100000000
    )
    # create checkpoint callback
    cp_callback = ModelCheckpoint(checkpoint_prefix, save_weights_only=True, verbose=1)

    history = model.fit(
        augmented_train_batches,
        epochs=n_epochs,
        steps_per_epoch=steps_per_epoch,
        validation_steps=eval_steps,
        validation_data=validation_batches,
        callbacks=[cp_callback, tensorboard_callback],
        # verbose=0
    )
    for key, value in history.history.items():
        try:
            pass
            run.log_list(f"training_{key}", value)
        except:
            _LOGGER.warning(
                f"{key} was too large (3000b is the max): {sys.getsizeof(value)}"
            )


# use print for this, logger doesn't work because of newlines
utils.print_cm(metric.total_cm.numpy(), [v for k, v in label_mapping.items()])


# for image, label in train_dataset_fit.take(1):
#     print("Image:")
#     print(image)

#     print("Labels:")
#     print(tf.reshape(label, (batch_size, cs_w, cs_h)))
#     # print(tf.math.argmax(
#     #         label, axis=len(label.shape) - 1, output_type=tf.int32
#     #     ))
#     prediction = model.predict(image)
#     # print("Prediction raw:")
#     # print(prediction)
#     print("Prediction parsed:")
#     print(tf.math.argmax(
#             prediction, axis=len(prediction.shape) - 1, output_type=tf.int32
#         ))
#     # print(model.evaluate(image))

# log the cm
aml_cm = {
    "schema_type": "confusion_matrix",
    "schema_version": "v1",
    "data": {
        "class_labels": [v for k, v in label_mapping.items()],
        "matrix": metric.total_cm.numpy().tolist(),
    },
}
try:
    run.log_confusion_matrix("total_confusion_matrix", aml_cm)
except:
    _LOGGER.warning(
        "aml_cm was too large (3000b is the max): %s", sys.getsizeof(aml_cm)
    )

# validation
if not skip_validate:
    validation_batches = (
        eval_dataset.map(convert, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .map(resize, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .repeat()
        .batch(2 * batch_size)
    )
    val_metrics = model.evaluate(validation_batches, steps=eval_steps)
    val_metrics_dict = dict(zip(model.metrics_names, val_metrics))
    for key, value in val_metrics_dict.items():
        run.log(f"final_validation_{key}", value)

# test
if test:
    test_batches = (
        test_dataset.map(convert, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .map(resize, num_parallel_calls=tf.data.experimental.AUTOTUNE)
        .repeat()
        .batch(2 * batch_size)
    )
    test_metrics = model.evaluate(test_batches, steps=test_steps)
    test_metrics_dict = dict(zip(model.metrics_names, test_metrics))
    for key, value in test_metrics_dict.items():
        run.log(f"test_{key}", value)

# save
if (not skip_save_model) and (not skip_train):
    model.save(model_folder)
#     checkpoint = tf.train.Checkpoint(model=model)
#     checkpoint.save(file_prefix=checkpoint_prefix)
