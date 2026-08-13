#!./.venv/bin/python
import os
import time
import cv2
import numpy as np
from rknnlite.api import RKNNLite
from common import (sigmoid, load_labels, letterbox, nms,
                    decode_outputs, postprocess, draw_on_letterbox)
DEBUG_IMG = True
MODEL_PATH = "model/rock-i8-yolox_tiny-rk3566-v2.3.2-2.rknn"
#MODEL_PATH = "model/rock-i8-yolox_nano-rk3566-v2.3.2-2.rknn"
LABEL_PATH = "model/label.txt"
IMG_SIZE = 416
CONF_THRESH = 0.45 # 置信度筛选
NMS_THRESH = 0.45

def process_file(rknn, labels, img_path):
    img_orig = cv2.imread(img_path)
    if img_orig is None:
        print(f"[WARN] cannot read {img_path}")
        return
    img_rgb = cv2.cvtColor(img_orig, cv2.COLOR_BGR2RGB)

    img_input, r, dw, dh = letterbox(img_rgb, IMG_SIZE)
    input_tensor = np.expand_dims(img_input, 0)

    outputs = rknn.inference([input_tensor])

    decoded = decode_outputs(outputs)
    results = postprocess(decoded, labels, CONF_THRESH, NMS_THRESH)

    vis_orig = img_orig.copy()
    for label, score, box in results:
#        if label != "person":
#            continue
        x1,y1,x2,y2 = box
        x1 = int((x1 - dw) / r)
        y1 = int((y1 - dh) / r)
        x2 = int((x2 - dw) / r)
        y2 = int((y2 - dh) / r)
        cv2.rectangle(vis_orig, (x1,y1), (x2,y2), (0,255,0), 2)
        cv2.putText(vis_orig, f"{label} {score:.2f}", (x1,y1-5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,255,0), 1)
    base_name = os.path.basename(os.path.splitext(img_path)[0])
    cv2.imwrite(f"{base_name}_original.jpg", vis_orig)
    print(f"[INFO] processed {img_path}")
    if DEBUG_IMG :
        vis_letterbox = draw_on_letterbox(img_input, results, r, dw, dh, labels)
        cv2.imwrite(f"{base_name}_letterbox.jpg", vis_letterbox)

# ---------------- main ----------------
def main(imgs):
    labels = load_labels(LABEL_PATH)
    # --------- Load model once ---------
    rknn = RKNNLite()
    rknn.load_rknn(MODEL_PATH)
    rknn.init_runtime()
    print("[INFO] Model loaded, waiting for new files...")

    for _, arg in enumerate(imgs):
        process_file(rknn, labels, arg)

    rknn.release()
    print("[INFO] RKNN released")

if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print(f"No Image File Path,use \"./env/bin/python {sys.argv[0]} <img_path> [<other_img_path> [<more_img_path>]]\"")
    else:
        main(sys.argv[1:])
