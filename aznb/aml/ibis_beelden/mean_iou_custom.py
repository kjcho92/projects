import tensorflow as tf
from tensorflow.python.ops import init_ops  # pylint: disable=unresolved-import
from tensorflow.python.framework import dtypes  # pylint: disable=unresolved-import
from tensorflow.python.ops import math_ops  # pylint: disable=unresolved-import
from tensorflow.python.ops import array_ops  # pylint: disable=unresolved-import
from tensorflow.python.ops import check_ops  # pylint: disable=unresolved-import
from tensorflow.python.ops import confusion_matrix  # pylint: disable=unresolved-import
import numpy as np


class MeanIoUCustom(tf.keras.metrics.MeanIoU):
    """Computes the mean Intersection-Over-Union metric.
  Mean Intersection-Over-Union is a common evaluation metric for semantic image
  segmentation, which first computes the IOU for each semantic class and then
  computes the average over classes. IOU is defined as follows:
    IOU = true_positive / (true_positive + false_positive + false_negative).
  The predictions are accumulated in a confusion matrix, weighted by
  `sample_weight` and the metric is then calculated from it.
  If `sample_weight` is `None`, weights default to 1.
  Use `sample_weight` of 0 to mask values.
  Usage:
  ```python
  m = tf.keras.metrics.MeanIoU(num_classes=2)
  m.update_state([0, 0, 1, 1], [0, 1, 0, 1])
    # cm = [[1, 1],
            [1, 1]]
    # sum_row = [2, 2], sum_col = [2, 2], true_positives = [1, 1]
    # iou = true_positives / (sum_row + sum_col - true_positives))
    # result = (1 / (2 + 2 - 1) + 1 / (2 + 2 - 1)) / 2 = 0.33
  print('Final result: ', m.result().numpy())  # Final result: 0.33
  ```
  Usage with tf.keras API:
  ```python
  model = tf.keras.Model(inputs, outputs)
  model.compile(
    'sgd',
    loss='mse',
    metrics=[tf.keras.metrics.MeanIoU(num_classes=2)])
  ```
  """

    def __init__(
        self, num_classes, ignore_label, crop_size_h, crop_size_w, name=None, dtype=None
    ):
        """Creates a `MeanIoU` instance.
    Args:
      num_classes: The possible number of labels the prediction task can have.
        This value must be provided, since a confusion matrix of dimension =
        [num_classes, num_classes] will be allocated.
      name: (Optional) string name of the metric instance.
      dtype: (Optional) data type of the metric result.
    """
        super(MeanIoUCustom, self).__init__(
            name=name, num_classes=num_classes, dtype=dtype
        )
        self.num_classes = num_classes
        self.ignore_label = ignore_label
        self.crop_size_h = crop_size_h
        self.crop_size_w = crop_size_w

        # Variable to accumulate the predictions in the confusion matrix. Setting
        # the type to be `float64` as required by confusion_matrix_ops.
        self.total_cm = self.add_weight(
            "total_confusion_matrix",
            shape=(self.num_classes, self.num_classes),
            initializer=init_ops.zeros_initializer,
            dtype=dtypes.int32,
        )

    @tf.function
    def update_state(self, y_true, y_pred, sample_weight=None):
        """Accumulates the confusion matrix statistics.
    Args:
      y_true: The ground truth values.
      y_pred: The predicted values.
      sample_weight: Optional weighting of each example. Defaults to 1. Can be a
        `Tensor` whose rank is either 0, or the same rank as `y_true`, and must
        be broadcastable to `y_true`.
    Returns:
      Update op.
    """
        # print("Label shape: ", y_true.shape)
        # print(y_true)
        # print("Prediction shape: ", y_pred.shape)
        # print(y_pred)
        logits = tf.image.resize(y_pred, (self.crop_size_h, self.crop_size_w))
        predictions_with_shape = tf.math.argmax(
            logits, axis=len(logits.shape) - 1, output_type=tf.int32
        )
        # print("Predictions shape (after prep): ", predictions_with_shape.shape)
        predictions = tf.reshape(
            predictions_with_shape, shape=(-1, self.crop_size_h, self.crop_size_w, 1)
        )
        # print("Predictions shape (after reshape): ", predictions.shape)
        # print(predictions)
        labels_with_shape = tf.cast(
            y_true, tf.int32
        )  # tf.math.argmax(y_true, axis=3, output_type=tf.int32)
        # print("Predictions shape (after reshape): ", labels_with_shape.shape)
        labels = tf.reshape(
            labels_with_shape, shape=(-1, self.crop_size_h, self.crop_size_w, 1)
        )
        sample_weight = tf.cast(
            tf.math.not_equal(labels, self.ignore_label), dtype=tf.float32
        )

        # Set ignore_label regions to label 0, because metrics.mean_iou requires
        # range of labels = [0, dataset.num_classes). Note the ignore_lable regions
        # are not evaluated since the corresponding regions contain weights = 0.
        labels = tf.where(
            tf.math.equal(labels, self.ignore_label), tf.zeros_like(labels), labels
        )
        # new = tf.compat.v1.metrics.mean_iou(
        #     predictions, labels, num_classes, weights=weights
        # )
        # print("Final Label shape: ", labels.shape)
        # print("Final Prediction shape: ", predictions.shape)

        y_true = labels
        y_pred = predictions
        y_true = math_ops.cast(y_true, self._dtype)
        y_pred = math_ops.cast(y_pred, self._dtype)

        # Flatten the input if its rank > 1.
        if y_pred.shape.ndims > 1:
            y_pred = array_ops.reshape(y_pred, [-1])

        if y_true.shape.ndims > 1:
            y_true = array_ops.reshape(y_true, [-1])

        if sample_weight is not None and sample_weight.shape.ndims > 1:
            sample_weight = array_ops.reshape(sample_weight, [-1])

        # print("Label shape: ", y_true.shape)
        # print(y_true)
        # print("Prediction shape: ", y_pred.shape)
        # print(y_pred)

        # Accumulate the prediction to current confusion matrix.
        current_cm = confusion_matrix.confusion_matrix(
            y_true, y_pred, self.num_classes, weights=sample_weight, dtype=dtypes.int32
        )
        return self.total_cm.assign_add(current_cm)
